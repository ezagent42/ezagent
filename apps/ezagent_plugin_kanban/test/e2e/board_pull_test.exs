defmodule EzagentPluginKanban.E2E.BoardPullTest do
  @moduledoc """
  T5a acceptance —— 跨房间"拉板"入口 `Ezagent.Socialware.BoardProvision.pull_board/4`:
  把一块**已存在**的板(owner=alice)拉进另一个 session B → B 的 kanban-assistant 拿到
  指向这块板的操作钥匙 → 能跨 session 操作它(数据跨 session 共享、板不进群、URI 寻址)。

  拉板 = 只有板主人能做。授权检查在 call-site:caller 必须是这块板的 data_owner(mint_cap
  内部用板主人权铸、不自检触发者,所以"只有主人能拉"必须这里做)。

  证三件事:
    (a) alice(板主人)`pull_board` → B 的 assistant 持指向该板的操作 cap、自身份 dispatch
        `kanban.add_node` 到该板成功;
    (b) bob(非板主人)`pull_board` 同一块板 → `{:error, :not_board_owner}`(拉别人的板拒);
    (c) 越权:未拉进 B 的板,B assistant 动不了(CBAC `:unauthorized`)。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.BoardProvision
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "t5a-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "t5a-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

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

  # 把 recipe requested_caps 全放行,让新板自持它声明的 kanban 动作(与 role_native 同款)。
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
  test "拉板: 板主人 alice 把已存在的板拉进 session B → B assistant 持操作钥匙、能跨 session 操作",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      # --- alice = 板主人(会话 owner / 建板触发者),持 create_agent 权 ----------
      alice_ctx = user_with_create_cap(ws_name, workspace_uri, "alice")

      # --- 一块已存在的板,owner = alice --------------------------------------
      board_uri =
        create_board_owned_by(
          workspace_uri,
          "board-#{System.unique_integer([:positive])}",
          alice_ctx
        )

      # --- session B:有一个 kanban-assistant(脑)成员 ------------------------
      {session_b, assistant_uri} = session_with_assistant(ws_name, workspace_uri, admin_ctx)

      # --- T5a 入口:alice(板主人)把板拉进 B ---------------------------------
      assert {:ok, %{assistant_uri: minted_to, minted: minted}} =
               BoardProvision.pull_board(
                 board_uri,
                 session_b,
                 Ezagent.ActionSet.Kanban,
                 alice_ctx
               )

      assert URI.to_string(minted_to) == URI.to_string(assistant_uri)

      # 铸了全部操作动作,granted_by 全 = alice(板主人)
      assert length(minted) == length(Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban))

      assert Enum.all?(
               minted,
               &(URI.to_string(&1.granted_by) == URI.to_string(alice_ctx.caller))
             )

      # 挂载落表:session B 有指向该板的 operate 挂载行(拉板 = operate)
      pull_mount = MountRow.get(session_b, board_uri, assistant_uri, Ezagent.ActionSet.Kanban)
      assert pull_mount != nil
      assert pull_mount.access == "operate"
      assert Enum.any?(MountRow.list_for_session(session_b), &(&1.id == pull_mount.id))

      # (a) assistant 持指向该板的实例精确 add_node cap
      assert eventually(fn -> holds_board_cap?(assistant_uri, board_uri, :add_node) end)

      minted_add = Enum.find(minted, &(&1.action == :add_node))
      assert minted_add.behavior == Ezagent.ActionSet.Kanban
      assert minted_add.instance == Ezagent.URI.instance(board_uri)
      refute minted_add.instance == :any

      # (a) assistant 自身份跨 session dispatch kanban.add_node 到该板成功(经 minted 钥匙)。
      # 新协作模型：加节点自动认领 —— assistant 自身份加根(自动认领)再在自己节点下加子。
      assert {:ok, %{id: "n1"}} =
               dispatch_as(assistant_uri, board_uri, :add_node, %{parent_id: "", title: "根"})

      assert {:ok, %{id: child_id}} =
               dispatch_as(assistant_uri, board_uri, :add_node, %{parent_id: "n1", title: "子"})

      assert is_binary(child_id)

      # (b) bob(非板主人)拉同一块板 → 拒。
      bob_ctx = %{
        caller: URI.new!("entity://#{ws_name}/user/bob-#{System.unique_integer([:positive])}"),
        caps: MapSet.new()
      }

      assert {:error, :not_board_owner} =
               BoardProvision.pull_board(
                 board_uri,
                 session_b,
                 Ezagent.ActionSet.Kanban,
                 bob_ctx
               )

      # (c) 越权:未拉进 B 的另一块板,B assistant 动不了。
      unrelated =
        create_board_owned_by(
          workspace_uri,
          "unrelated-#{System.unique_integer([:positive])}",
          alice_ctx
        )

      assert {:error, :unauthorized} =
               dispatch_as(assistant_uri, unrelated, :add_node, %{parent_id: "", title: "x"})
    end)
  end

  @tag :integration
  test "拉板: target session 没有 kanban-assistant 成员 → 优雅 {:error, :no_assistant_in_target}",
       %{ws_name: ws_name, workspace_uri: workspace_uri} do
    skip_if_no_entity_spawn(fn ->
      alice_ctx = user_with_create_cap(ws_name, workspace_uri, "alice")

      board_uri =
        create_board_owned_by(
          workspace_uri,
          "board-#{System.unique_integer([:positive])}",
          alice_ctx
        )

      # session 无 kanban-assistant 成员
      session_uri =
        URI.new!("session://#{ws_name}/default/t5a-#{System.unique_integer([:positive])}")

      {:ok, _sess_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors(),
          owner_uri: alice_ctx.caller
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)

      assert {:error, :no_assistant_in_target} =
               BoardProvision.pull_board(
                 board_uri,
                 session_uri,
                 Ezagent.ActionSet.Kanban,
                 alice_ctx
               )
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp user_with_create_cap(ws_name, workspace_uri, label) do
    user_uri =
      URI.new!("entity://#{ws_name}/user/#{label}-#{System.unique_integer([:positive])}")

    create_cap =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :create_agent,
        workspace_uri,
        workspace_uri
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{
        uri: user_uri,
        initial_caps:
          MapSet.new([
            %{create_cap | granted_by: User.admin_uri(), granted_at: DateTime.utc_now()}
          ])
      })

    %{caller: user_uri, caps: Ezagent.Identity.list_caps_for(user_uri)}
  end

  # 建一块板,owner = ctx.caller(create_agent 记 lineage → data_owner)。
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
      URI.new!("session://#{ws_name}/default/t5a-#{System.unique_integer([:positive])}")

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

    case Invocation.dispatch(%Invocation{
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

  defp dispatch(board_uri, action, args, %{caller: caller, caps: caps}) do
    Ezagent.Router.dispatch(
      Ezagent.Cmd.new(
        Ezagent.URI.with_action(board_uri, :kanban, action),
        action,
        args,
        %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
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
