defmodule EzagentPluginKanban.E2E.BoardForwardTest do
  @moduledoc """
  T5b acceptance —— 群成员"转发只读" `Ezagent.Socialware.BoardProvision.forward_board/5`:
  把一块**已存在**的板(owner=alice)从 from_session(alice 已把这板拉进来、其 assistant 有
  操作钥匙)转发给另一个 to_session → to_session 的 kanban-assistant 拿到指向这块板的**只读**
  钥匙(只 `[:get_tree, :export_markmap]`)→ 只能看不能改。

  转发 = 群里任何成员能做(不用是板主人),只要 caller 在 from_session 里、且 from_session
  对这块板有 access(= from_session 的 kanban-assistant 持指向这块板的 Kanban cap)。granter
  仍 = 板主人(mint_cap 内部用板主人权铸);转发成员只是"传递了他的 access"。

  证三件事:
    (a) bob(非板主人、但在有该板 access 的 from_session)`forward_board` → to_session 的
        assistant 持指向该板的**只读** cap、自身份 dispatch `kanban.get_tree` 到该板成功,但
        dispatch `kanban.add_node` 被拒(只读、没给写);
    (b) caller 不在 from_session / from_session 无该板 access → `{:error, :no_forward_access}`;
    (c) to_session 无 assistant → `{:error, :no_assistant_in_target}`。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.BoardProvision
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "t5b-native"
  @read_actions [:get_tree, :export_markmap]

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "t5b-#{System.unique_integer([:positive])}"
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
  test "转发只读: 群成员 bob 把板从 from_session 转发给 to_session → 只读能看不能改 + 越权拒 + 无 assistant 拒",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      alice_ctx = user_with_create_cap(ws_name, workspace_uri, "alice")

      # 一块已存在的板,owner = alice
      board_uri =
        create_board_owned_by(
          workspace_uri,
          "board-#{System.unique_integer([:positive])}",
          alice_ctx
        )

      # from_session:alice 已把这板拉进来(其 assistant 持操作钥匙)+ 成员 bob(非板主人)
      {from_session, _from_assistant} = session_with_assistant(ws_name, workspace_uri, admin_ctx)

      assert {:ok, _} =
               BoardProvision.pull_board(
                 board_uri,
                 from_session,
                 Ezagent.ActionSet.Kanban,
                 alice_ctx
               )

      bob_uri = URI.new!("entity://#{ws_name}/user/bob-#{System.unique_integer([:positive])}")
      spawn_user(bob_uri)
      :ok = join_member(from_session, bob_uri, "member", admin_ctx)

      bob_ctx = %{
        caller: bob_uri,
        authenticated_principal: bob_uri,
        caps: MapSet.new(Ezagent.Identity.list_caps_for(bob_uri))
      }

      # to_session:有一个 kanban-assistant 成员(收只读钥匙)
      {to_session, to_assistant} = session_with_assistant(ws_name, workspace_uri, admin_ctx)

      # --- (a) T5b 入口:bob(非板主人、在有该板 access 的 from_session)转发给 to_session ---
      assert {:ok, %{assistant_uri: minted_to, minted: minted}} =
               BoardProvision.forward_board(
                 board_uri,
                 from_session,
                 to_session,
                 Ezagent.ActionSet.Kanban,
                 bob_ctx
               )

      assert URI.to_string(minted_to) == URI.to_string(to_assistant)

      # 只铸只读动作(get_tree + export_markmap),granted_by 全 = alice(板主人)
      assert Enum.map(minted, & &1.action) |> Enum.sort() == Enum.sort(@read_actions)

      assert Enum.all?(
               minted,
               &(URI.to_string(&1.granted_by) == URI.to_string(alice_ctx.caller))
             )

      # to_assistant 持指向该板的实例精确 get_tree cap,但**没有** add_node(写)cap
      assert eventually(fn -> holds_board_cap?(to_assistant, board_uri, :get_tree) end)
      refute holds_board_cap?(to_assistant, board_uri, :add_node)

      minted_read = Enum.find(minted, &(&1.action == :get_tree))
      assert minted_read.behavior == Ezagent.ActionSet.Kanban
      assert minted_read.instance == Ezagent.URI.instance(board_uri)
      refute minted_read.instance == :any

      # 挂载落表:to_session 有指向该板的 read 挂载行(转发 = read)
      fwd_mount = MountRow.get(to_session, board_uri, to_assistant, Ezagent.ActionSet.Kanban)
      assert fwd_mount != nil
      assert fwd_mount.access == "read"
      assert Enum.any?(MountRow.list_for_session(to_session), &(&1.id == fwd_mount.id))

      # 先由板主人(admin)在板上建一个根节点,好让只读读到东西
      assert {:ok, %{id: "n1"}} =
               dispatch(board_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      # to_assistant 自身份跨 session dispatch kanban.get_tree 到该板成功(只读钥匙)
      # 数据回流(1):接收方读到的是**挂载之后**源板新增的 n1 —— 证明是活引用、非挂载时快照拷贝
      assert {:ok, %{tree: %{nodes: nodes_after_mount}}} =
               dispatch_as(to_assistant, board_uri, :get_tree, %{})

      assert Map.has_key?(nodes_after_mount, "n1"),
             "接收方应读到挂载后源板新增的 n1(数据回流:活引用)"

      # 数据回流(2):源板再改一次 → 接收方重读立即看到最新 —— 证明持续回流,非仅挂载时刻
      assert {:ok, %{id: "n2"}} =
               dispatch(board_uri, :add_node, %{parent_id: "n1", title: "回流验证节点"}, admin_ctx)

      assert {:ok, %{tree: %{nodes: nodes_after_change}}} =
               dispatch_as(to_assistant, board_uri, :get_tree, %{})

      assert Map.has_key?(nodes_after_change, "n2"),
             "接收方重读应看到源板最新新增的 n2(数据回流:每次读源板活数据)"

      # 只读:dispatch kanban.add_node(写)被拒(没给写钥匙)
      assert {:error, reason} =
               dispatch_as(to_assistant, board_uri, :add_node, %{parent_id: "n1", title: "子"})

      assert reason in [:missing_cap, :unauthorized]

      # --- (b1) caller 不在 from_session → 拒 -------------------------------
      carol_uri =
        URI.new!("entity://#{ws_name}/user/carol-#{System.unique_integer([:positive])}")

      spawn_user(carol_uri)
      carol_ctx = %{
        caller: carol_uri,
        authenticated_principal: carol_uri,
        caps: MapSet.new()
      }

      assert {:error, :no_forward_access} =
               BoardProvision.forward_board(
                 board_uri,
                 from_session,
                 to_session,
                 Ezagent.ActionSet.Kanban,
                 carol_ctx
               )

      # --- (b2) from_session 无该板 access → 拒 ------------------------------
      {no_access_session, _} = session_with_assistant(ws_name, workspace_uri, admin_ctx)
      :ok = join_member(no_access_session, bob_uri, "member", admin_ctx)

      assert {:error, :no_forward_access} =
               BoardProvision.forward_board(
                 board_uri,
                 no_access_session,
                 to_session,
                 Ezagent.ActionSet.Kanban,
                 bob_ctx
               )

      # --- (b3) 跨 workspace 接收在 mint/Mount 前拒绝 ----------------------
      foreign_ws_name = "t5b-foreign-#{System.unique_integer([:positive])}"
      {:ok, _foreign_ws_pid} = Workspace.create(foreign_ws_name, %{})
      foreign_workspace_uri = URI.new!("workspace://#{foreign_ws_name}")

      {foreign_session, foreign_assistant} =
        session_with_assistant(foreign_ws_name, foreign_workspace_uri, admin_ctx)

      assert {:error, :cross_workspace_denied} =
               BoardProvision.forward_board(
                 board_uri,
                 from_session,
                 foreign_session,
                 Ezagent.ActionSet.Kanban,
                 bob_ctx
               )

      assert MountRow.get(
               foreign_session,
               board_uri,
               foreign_assistant,
               Ezagent.ActionSet.Kanban
             ) == nil

      assert {:error, :missing_cap} =
               dispatch_as(foreign_assistant, board_uri, :get_tree, %{})

      # --- (c) to_session 无 assistant → 拒 ---------------------------------
      no_assistant_session =
        session_without_assistant(ws_name, workspace_uri, alice_ctx.caller)

      assert {:error, :no_assistant_in_target} =
               BoardProvision.forward_board(
                 board_uri,
                 from_session,
                 no_assistant_session,
                 Ezagent.ActionSet.Kanban,
                 bob_ctx
               )
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp user_with_create_cap(ws_name, workspace_uri, label) do
    user_uri =
      URI.new!("entity://#{ws_name}/user/#{label}-#{System.unique_integer([:positive])}")

    assert {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [])
    assert :ok = Ezagent.Entity.spawn_principal(user_uri)
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)

    Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, user_uri)
  end

  defp spawn_user(user_uri) do
    assert {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [])
    assert :ok = Ezagent.Entity.spawn_principal(user_uri)
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    :ok
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

  defp session_with_assistant(ws_name, workspace_uri, admin_ctx) do
    assistant_uri =
      live_agent(ws_name, "kanban-assistant-#{System.unique_integer([:positive])}")

    session_uri =
      URI.new!("session://#{ws_name}/default/t5b-#{System.unique_integer([:positive])}")

    {:ok, _sess_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)

    :ok = join_member(session_uri, assistant_uri, "kanban-assistant", admin_ctx)

    {session_uri, assistant_uri}
  end

  defp session_without_assistant(ws_name, workspace_uri, owner_uri) do
    session_uri =
      URI.new!("session://#{ws_name}/default/t5b-#{System.unique_integer([:positive])}")

    {:ok, _sess_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: owner_uri
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

  defp join_member(session_uri, member_uri, role_name, %{caller: caller}) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, role_name: role_name},
           ctx: %{
             caller: caller,
             authenticated_principal: caller,
             caps: MapSet.new([cap]),
             reply: {:caller_inbox, self()}
           }
         }) do
      :ok -> converge_member_projection(session_uri, member_uri, role_name)
      {:ok, _} -> converge_member_projection(session_uri, member_uri, role_name)
      other -> flunk("join failed: #{inspect(other)}")
    end
  end

  defp converge_member_projection(session_uri, member_uri, role_name) do
    assert eventually(fn ->
             held = Ezagent.EntityCaps.load_persisted(member_uri)
             Ezagent.Session.MemberReceive.holds_member_cap_over?(member_uri, held, session_uri)
           end)

    target = Ezagent.URI.with_action(session_uri, :session, :add_self)

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, facets: %{role_name: role_name}},
           ctx: %{
             caller: member_uri,
             authenticated_principal: member_uri,
             caps: MapSet.new(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{status: status}} when status in [:added, :already_member] -> :ok
      other -> flunk("member projection failed: #{inspect(other)}")
    end
  end

  defp dispatch(board_uri, action, args, %{caller: caller, caps: caps}) do
    caps =
      if caller == User.admin_uri() do
        target = Ezagent.URI.with_action(board_uri, :kanban, action)
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller)])
      else
        caps
      end

    Ezagent.Router.dispatch(
      Ezagent.Cmd.new(
        Ezagent.URI.with_action(board_uri, :kanban, action),
        action,
        args,
        %{
          mode: :call,
          caller: caller,
          authenticated_principal: caller,
          caps: caps,
          reply: {:caller_inbox, self()}
        }
      )
    )
  end

  defp dispatch_as(caller_uri, board_uri, action, args) do
    dispatch(board_uri, action, args, %{
      caller: caller_uri,
      caps: MapSet.new(Ezagent.Identity.list_caps_for(caller_uri))
    })
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
