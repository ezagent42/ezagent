defmodule EzagentPluginKanban.E2E.ShareReceiveTest do
  @moduledoc """
  债③ acceptance —— 分享接收业务的 plugin 归宿
  `EzagentPluginKanban.ShareReceive.receive_shared_board/3`(从
  `EzagentWeb.Socialware.KanbanShareController` 搬入;web 全链回归见
  kanban_share_controller_test)。

  证三件事:
    (a) 显式 `target_session` 落点:只读挂载(`MountRow` `access="read"` 行 +
        assistant 持只读钥匙,get_tree 成/add_node 拒);
    (b) `target_session=nil` 沿用现口径(首个带 kanban-assistant 的 session);
    (c) 坏 board 字符串 → `:bad_board`;无 assistant 的显式落点 →
        `:no_assistant_in_session`。

  (点击者的 `kanban_render` view cap **不在**接收链发 —— 撞 I12 grant 点
  shrink-only 铁闸,归 join-补发/Allen D1/D3,见 ShareReceive moduledoc TODO。)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.Application, as: KanbanApp
  alias EzagentPluginKanban.ShareReceive

  @flavor "d3-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "d3-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    # #1457 per-Kind signing:ambient genesis wildcard 不再过验签,ctx 走
    # signed_workspace_ctx!(canonical admin 经 workspace Kind 目标签名)。
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
  test "receive_shared_board: 显式落点只读挂载;nil 落点沿现口径;坏输入优雅报错",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      board_uri = create_board_as_admin(workspace_uri, "b-#{u()}", admin_ctx)
      payload = %{"board" => s(board_uri), "behavior" => "Ezagent.ActionSet.Kanban"}

      clicker = spawn_user(ws_name, "clicker")

      {session_uri, assistant_uri} =
        session_with(ws_name, workspace_uri, [{clicker, "member"}], admin_ctx)

      # (a) 显式落点:只读挂载。
      assert {:ok, %{session_uri: ^session_uri, assistant_uri: ^assistant_uri}} =
               ShareReceive.receive_shared_board(payload, clicker, session_uri)

      row = MountRow.get(session_uri, board_uri, assistant_uri, Ezagent.ActionSet.Kanban)
      assert row != nil
      assert row.access == "read"

      assert eventually(fn -> holds_board_cap?(assistant_uri, board_uri, :get_tree) end)
      refute holds_board_cap?(assistant_uri, board_uri, :add_node)
      assert {:ok, %{tree: _}} = dispatch_as(assistant_uri, board_uri, :get_tree, %{})

      # #1457 target verifier:无候选钥匙的拒绝 reason 收敛为 :missing_cap(与
      # :unauthorized 区分——后者是有钥匙但验签/域不过)。
      assert {:error, :missing_cap} =
               dispatch_as(assistant_uri, board_uri, :add_node, %{parent_id: "", title: "x"})

      # (b) nil 落点:沿「首个带 kanban-assistant 的 session」现口径 —— clicker 是
      # session 成员,解析回同一落点。
      assert {:ok, %{session_uri: ^session_uri}} =
               ShareReceive.receive_shared_board(payload, clicker)

      # 幂等:同一自然键仍 1 行。
      assert MountRow.list_for_session(session_uri)
             |> Enum.count(&(&1.target_uri == s(board_uri))) == 1

      # (c) 坏 board → :bad_board;无 assistant 的显式落点 → :no_assistant_in_session。
      assert {:error, :bad_board} =
               ShareReceive.receive_shared_board(
                 %{"board" => "not a uri", "behavior" => "Ezagent.ActionSet.Kanban"},
                 clicker,
                 session_uri
               )

      {bare_session, nil} = bare_session(ws_name, workspace_uri, clicker, admin_ctx)

      assert {:error, :no_assistant_in_session} =
               ShareReceive.receive_shared_board(payload, clicker, bare_session)
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp u, do: System.unique_integer([:positive])
  defp s(%URI{} = uri), do: URI.to_string(uri)

  defp spawn_user(ws_name, label) do
    user_uri = URI.new!("entity://#{ws_name}/user/#{label}-#{u()}")
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: MapSet.new()})
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    user_uri
  end

  defp create_board_as_admin(workspace_uri, name, admin_ctx) do
    assert {:ok, %{agent_uri: uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
               admin_ctx
             )

    uri
  end

  # session:给定成员 + 一个 kanban-assistant 成员(收只读钥匙的「手」)。
  defp session_with(ws_name, workspace_uri, members, admin_ctx) do
    assistant_uri = live_agent(ws_name, "kanban-assistant-#{u()}")
    session_uri = spawn_session(ws_name, workspace_uri)

    for {member_uri, role} <- members,
        do: :ok = join_member(session_uri, member_uri, role, admin_ctx)

    :ok = join_member(session_uri, assistant_uri, "kanban-assistant", admin_ctx)

    {session_uri, assistant_uri}
  end

  # 无 assistant 的 bare session(clicker 是成员)。
  defp bare_session(ws_name, workspace_uri, clicker, admin_ctx) do
    session_uri = spawn_session(ws_name, workspace_uri)
    :ok = join_member(session_uri, clicker, "member", admin_ctx)
    {session_uri, nil}
  end

  defp spawn_session(ws_name, workspace_uri) do
    session_uri = URI.new!("session://#{ws_name}/default/d3-#{u()}")

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

  defp live_agent(ws_name, name) do
    uri = Ezagent.URI.agent(ws_name, name)
    owner = User.admin_uri()

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors(),
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, URI.new!("workspace://#{ws_name}"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
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
        cap.action == action and
        cap.instance == Ezagent.URI.instance(board_uri)
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
