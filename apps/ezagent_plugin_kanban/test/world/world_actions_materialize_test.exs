defmodule EzagentPluginKanban.WorldActionsMaterializeTest do
  @moduledoc """
  操作物化消息（2026-07-18 一等任务）acceptance：kanban 写操作成功后，以**操作者
  身份**往当前会话物化一条 `visibility: :internal, hops: 0` 消息（动作+节点摘要；
  attach 带附件引用）。证四件事：

    (a) add_node 成功 → 会话里多一条 internal / hops=0 / sender=操作者 的消息，
        文本含动作摘要（板名+节点名）；
    (b) 该消息**不出现在** chat 普通读面（`recent_visible_in_session` 过滤 internal）；
    (c) attach file 产物（attach_upload 路）→ 物化消息 `body.attachments` 带
        uploads resource URI（㊲ 救济半件的引用侧）；
    (d) 写动作失败（rename 不存在的节点）→ 不物化；无当前会话 → 不物化、不炸。
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, MessageStore}
  alias EzagentPluginKanban.WorldActions
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "mat-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "mat-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: fn _requested -> fn _needed -> true end end
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    # #1457 per-Kind signing:ambient genesis wildcard 不再过验签,ctx 走
    # signed_workspace_ctx!(canonical admin 经 workspace Kind 目标签名)。
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  @tag :integration
  test "写操作成功物化 internal/hops=0 消息;chat 读面不显示;attach 带附件引用;失败/无会话不物化",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      board_uri =
        create_board(workspace_uri, "mat-board-#{System.unique_integer([:positive])}", admin_ctx)

      session_uri = spawn_session(ws_name, workspace_uri)

      socket =
        socket_for(workspace_uri, with_op_caps(admin_ctx, board_uri, session_uri), session_uri)

      board_str = URI.to_string(board_uri)

      # (a) add_node 成功 → 物化一条 internal / hops=0 / sender=操作者。
      {:noreply, _} =
        WorldActions.handle_dispatch(socket, "kanban.add_node", %{
          "kanban_uri" => board_str,
          "parent_id" => "",
          "title" => "根任务"
        })

      msg = await_materialized(session_uri, "新增节点")
      assert msg.visibility == :internal
      assert msg.hops == 0
      assert URI.to_string(msg.sender) == URI.to_string(admin_ctx.caller)
      assert body_text(msg) =~ "根任务"
      assert body_text(msg) =~ "【看板·"

      # (b) chat 普通读面（visible-only）不显示 internal 物化消息。
      visible = MessageStore.recent_visible_in_session(session_uri, 50)
      refute Enum.any?(visible, fn m -> body_text(m) =~ "新增节点" end)

      # (c) attach file 产物 → 物化消息带 uploads resource URI 附件引用。
      upload_uri = "resource://#{ws_name}/uploads/#{Ecto.UUID.generate()}-spec.pdf"

      {:noreply, _} =
        WorldActions.handle_dispatch(socket, "kanban.attach_artifact", %{
          "kanban_uri" => board_str,
          "id" => "n1",
          "artifact" => %{
            "tool" => "upload",
            "kind" => "file",
            "ref" => "规格书",
            "url" => upload_uri
          }
        })

      attach_msg = await_materialized(session_uri, "规格书")

      # body 经 DB round-trip 成 string 键、URI 序列化为字符串（Jason encoder for URI）。
      assert [att] = body_attachments(attach_msg)
      assert to_string(att) == upload_uri

      # (d1) 写失败（节点不存在）→ 不物化新消息。
      before_count = length(MessageStore.recent_in_session(session_uri, 50))

      {:noreply, _} =
        WorldActions.handle_dispatch(socket, "kanban.rename_node", %{
          "kanban_uri" => board_str,
          "id" => "no-such",
          "title" => "x"
        })

      Process.sleep(200)
      assert length(MessageStore.recent_in_session(session_uri, 50)) == before_count

      # (d2) 无当前会话（/plugins/kanban 独立页）→ 不炸（无处可记，静默跳过）。
      no_session =
        socket_for(workspace_uri, with_op_caps(admin_ctx, board_uri, session_uri), nil)

      {:noreply, pushed} =
        WorldActions.handle_dispatch(no_session, "kanban.add_node", %{
          "kanban_uri" => board_str,
          "parent_id" => "n1",
          "title" => "子"
        })

      assert pushed.assigns.last_dispatch_status == "ok"
    end)
  end

  # --- helpers -------------------------------------------------------------

  # 持久化后的 body 是 string 键 map（Ecto :map round-trip）；send 前的内存态是 atom 键。
  defp body_text(msg), do: msg.body[:text] || msg.body["text"] || ""

  defp body_attachments(msg), do: msg.body[:attachments] || msg.body["attachments"] || []

  # session.send 是 :cast（异步持久化）——轮询等物化消息落 MessageStore。
  defp await_materialized(session_uri, needle, tries \\ 40) do
    msgs = MessageStore.recent_in_session(session_uri, 50)

    case Enum.find(msgs, fn m -> body_text(m) =~ needle end) do
      nil when tries > 0 ->
        Process.sleep(100)
        await_materialized(session_uri, needle, tries - 1)

      nil ->
        flunk("materialized message containing #{inspect(needle)} never arrived")

      msg ->
        msg
    end
  end

  defp socket_for(workspace_uri, %{caller: caller, caps: caps}, session_uri) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:current_entity_uri, caller)
    |> assign(:current_caps, caps)
    |> assign(:current_session_uri, session_uri)
    |> assign(:last_dispatch_status, "idle")
  end

  # #1457 per-Kind signing:workspace ctx 的 :any/:any cap 不再覆盖 agent-kind 的
  # kanban 动作 / session.send——按目标逐动作现签(经目标 Kind 的 grant verifier),
  # 并进 socket caps(kanban 全动作 + 物化用的 session.send)。
  defp with_op_caps(%{caller: caller, caps: caps} = ctx, board_uri, session_uri) do
    board_caps =
      for action <- Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban) do
        target = Ezagent.URI.with_action(board_uri, :kanban, action)
        Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
      end

    send_cap =
      Ezagent.Test.CapHelper.signed_action_cap!(
        Ezagent.URI.with_action(session_uri, :session, :send),
        caller
      )

    %{ctx | caps: MapSet.union(MapSet.new(caps), MapSet.new([send_cap | board_caps]))}
  end

  defp spawn_session(ws_name, workspace_uri) do
    session_uri =
      URI.new!("session://#{ws_name}/default/mat-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)
    session_uri
  end

  defp create_board(workspace_uri, name, admin_ctx) do
    {:ok, %{agent_uri: uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
        admin_ctx
      )

    uri
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
