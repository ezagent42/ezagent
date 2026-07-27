defmodule EzagentWeb.Socialware.KanbanShare2Test do
  @moduledoc """
  分享二期 acceptance —— ㉙ `kanban.share_to_session` + 规则8
  `kanban.request_edit` / `kanban.approve_edit`(`EzagentPluginKanban.WorldActions`
  的公开业务函数;socket 用 @endpoint 真签 token,照 kanban_share_controller_test)。

  证四件事:
    (a) ㉙ share_to_session:板主人 → 分享消息物化进目标会话(可见,`hops: 0`
        存完即止,文本带接收链接);无 access 的路人 → `:no_access`;
    (b) 规则8 request_edit:已持 person read 钥匙的申请人 → 申请消息物化进当前
        会话(带 request-edit 标记);板主人自己申请 → `:already_owner`;
    (c) 规则8 approve_edit:板主人批准 → person 行 read→operate 原地升级
        (仍 1 行)+ 申请人持写钥匙(add_node dispatch 成);
    (d) 授权反例:非板主人批准 → `:not_board_owner`;跨 ws 申请人 →
        `:cross_workspace_denied`(D4 不变量 3:升级点复查同 ws);无 read 挂载 →
        `:no_read_mount`。
  """

  use EzagentWeb.ConnCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.{ShareReceive, WorldActions}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "share2-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "s2-#{u()}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "㉙+规则8 全链:分享消息物化 → 申请编辑 → 批准升级 read→operate;授权反例全拒",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      owner_ctx = user_with_create_cap(ws_name, workspace_uri, "owner")
      %{caller: owner} = owner_ctx
      board_uri = create_board_owned_by(workspace_uri, "b-#{u()}", owner_ctx)

      requester = spawn_user(ws_name, "requester")
      session_uri = spawn_session(ws_name, workspace_uri)
      :ok = join_member(session_uri, owner, "owner", admin_ctx)
      :ok = join_member(session_uri, requester, "requester", admin_ctx)

      owner_socket = socket_for(owner, workspace_uri, session_uri)

      # (a) ㉙ share_to_session:分享消息物化(可见、带接收链接、hops 存完即止)。
      assert {:ok, ^session_uri} =
               WorldActions.share_to_session_result(owner_socket, s(board_uri), nil)

      assert eventually(fn ->
               Enum.any?(recent_texts(session_uri), fn t ->
                 t =~ "【看板分享】" and t =~ "/socialware/kanban/receive?token="
               end)
             end)

      # 无 access 的路人 → :no_access(且不物化)。
      stranger = spawn_user(ws_name, "stranger")
      stranger_socket = socket_for(stranger, workspace_uri, session_uri)

      assert {:error, :no_access} =
               WorldActions.share_to_session_result(stranger_socket, s(board_uri), nil)

      # (b) 规则8 request_edit:申请人先经 ㊵ 人本位接收拿 person read 钥匙。
      payload = %{"board" => s(board_uri), "behavior" => "Ezagent.ActionSet.Kanban"}
      assert {:ok, _} = ShareReceive.receive_shared_board(payload, requester)

      assert %{access: "read"} =
               MountRow.get_person(board_uri, requester, Ezagent.ActionSet.Kanban)

      requester_socket = socket_for(requester, workspace_uri, session_uri)

      assert {:ok, ^session_uri} =
               WorldActions.request_edit_result(requester_socket, s(board_uri))

      assert eventually(fn ->
               Enum.any?(recent_texts(session_uri), fn t ->
                 t =~ "【申请编辑】" and t =~ "/plugins/kanban/request-edit?"
               end)
             end)

      # 板主人自己申请 → :already_owner。
      assert {:error, :already_owner} =
               WorldActions.request_edit_result(owner_socket, s(board_uri))

      # (d) 反例:非板主人批准 → :not_board_owner。
      assert {:error, :not_board_owner} =
               WorldActions.approve_edit_result(requester_socket, s(board_uri), s(requester))

      # 反例:无 read 挂载的人 → :no_read_mount。
      assert {:error, :no_read_mount} =
               WorldActions.approve_edit_result(owner_socket, s(board_uri), s(stranger))

      # 反例:跨 ws 申请人(先跨 ws 拿 read 钥匙——D4 read 放开)→ 升级点复查
      # 同 ws,:cross_workspace_denied(operate 钥匙永不跨 ws)。
      other_ws = "s2x-#{u()}"
      {:ok, _} = Workspace.create(other_ws, %{})
      outsider = spawn_user(other_ws, "outsider")
      assert {:ok, _} = ShareReceive.receive_shared_board(payload, outsider)

      assert {:error, :cross_workspace_denied} =
               WorldActions.approve_edit_result(owner_socket, s(board_uri), s(outsider))

      # (c) 板主人批准同 ws 申请人 → person 行原地升级 operate(仍 1 行)+ 写钥匙。
      assert {:ok, ^requester} =
               WorldActions.approve_edit_result(owner_socket, s(board_uri), s(requester))

      row = MountRow.get_person(board_uri, requester, Ezagent.ActionSet.Kanban)
      assert row.access == "operate"

      assert MountRow.list_person_mounts_for_grantee(requester)
             |> Enum.count(&(&1.target_uri == s(board_uri))) == 1

      assert eventually(fn -> holds_board_cap?(requester, board_uri, :add_node) end)

      assert {:ok, %{id: _}} =
               dispatch_as(requester, board_uri, :add_node, %{parent_id: "", title: "根"})
    end)
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])
  defp s(%URI{} = uri), do: URI.to_string(uri)

  # LiveView socket 形状(share_socket 同款)+ 当前会话 + 该会话 send 钥匙
  # (send_session_message 走 :session :send dispatch,ctx 用 socket caps)。
  defp socket_for(%URI{} = caller, workspace_uri, session_uri) do
    send_target = Ezagent.URI.with_action(session_uri, :session, :send)
    send_cap = Ezagent.Test.CapHelper.signed_action_cap!(send_target, caller)
    caps = MapSet.new([send_cap | Enum.to_list(Ezagent.Identity.list_caps_for(caller))])

    %Phoenix.LiveView.Socket{endpoint: @endpoint}
    |> Phoenix.Component.assign(:current_entity_uri, caller)
    |> Phoenix.Component.assign(:current_caps, caps)
    |> Phoenix.Component.assign(:presenter_caps, caps)
    |> Phoenix.Component.assign(:current_workspace_uri, workspace_uri)
    |> Phoenix.Component.assign(:current_session_uri, session_uri)
  end

  defp recent_texts(session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_visible_in_session(20)
    |> Enum.map(fn m -> get_in(m.body, [:text]) || get_in(m.body, ["text"]) || "" end)
  rescue
    _ -> []
  end

  defp user_with_create_cap(ws_name, workspace_uri, label) do
    user_uri = URI.new!("entity://#{ws_name}/user/#{label}-#{u()}")

    requested =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :create_agent,
        workspace_uri,
        workspace_uri
      )

    {:ok, create_cap} = Ezagent.Cap.issue({:admin, User.admin_uri()}, user_uri, requested)

    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: MapSet.new([create_cap])})

    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    %{caller: user_uri, caps: Ezagent.Identity.list_caps_for(user_uri)}
  end

  defp spawn_user(ws_name, label) do
    user_uri = URI.new!("entity://#{ws_name}/user/#{label}-#{u()}")
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: MapSet.new()})
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    user_uri
  end

  defp create_board_owned_by(workspace_uri, name, ctx) do
    assert {:ok, %{agent_uri: uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
               ctx
             )

    uri
  end

  defp spawn_session(ws_name, workspace_uri) do
    session_uri = URI.new!("session://#{ws_name}/default/s2-#{u()}")

    {:ok, _sess_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)
    session_uri
  end

  defp join_member(session_uri, member_uri, role_name, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    caps =
      MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller) | Enum.to_list(caps)])

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, role_name: role_name},
           ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> flunk("join failed: #{inspect(other)}")
    end
  end

  defp dispatch_as(caller_uri, board_uri, action, args) do
    Ezagent.Router.dispatch(
      Ezagent.Cmd.new(
        Ezagent.URI.with_action(board_uri, :kanban, action),
        action,
        args,
        %{
          mode: :call,
          caller: caller_uri,
          caps: MapSet.new(Ezagent.Identity.list_caps_for(caller_uri)),
          reply: {:caller_inbox, self()}
        }
      )
    )
  end

  defp holds_board_cap?(grantee, board_uri, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.kind == :agent and cap.behavior == Ezagent.ActionSet.Kanban and
        cap.action == action and cap.instance == Ezagent.URI.instance(board_uri)
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
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
