defmodule EzagentPluginKanban.E2E.BoardProvisionGrantTest do
  @moduledoc """
  T4a acceptance —— 运行时"建板"入口 `Ezagent.Socialware.BoardProvision.create_board/5`:
  会话内建出一块 kanban board(kanban-manager × native agent),归属 = 触发建板的 owner,
  并当场用 `CompositionCaps.mint_cap/4` 给**本 session 的 kanban-assistant** 发一把指向
  这块新板的 Kanban 操作钥匙(全 20 动作)。

  证三件事:
    (a) 新板存在(kanban-manager agent 活着 + 挂 Kanban)、board owner = 建板的 owner
        (`data_owner_of(Kanban, board)` == owner —— 正是 mint 的 granter #154);
    (b) 本 session 的 kanban-assistant 持指向该新板的**实例精确** Kanban 操作 cap
        (`Identity.list_caps_for(assistant)` 含 `instance == board`);
    (c) assistant **自身份** dispatch `kanban.add_node` 到新板**成功**(minted 钥匙过 CBAC
        step 5.5),而到无关板被 CBAC 拒(`:missing_cap`)—— 钥匙实例精确、越权拒。
        (root=admin 门是正交的 per-node 业务闸:admin 播根 → assistant 认领根 → assistant
        在自己认领的节点下加子 = 一次真正成功的 add_node,走的就是 minted 钥匙。)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.BoardProvision
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "t4a-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "t4a-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx =
      Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

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
  test "chat 建板: 建出 board(owner=触发者) + 当场给本 session 的 kanban-assistant 发操作钥匙",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      # --- owner = 常规用户(会话 owner / 建板触发者),持 create_agent 权 ----------
      owner_uri =
        URI.new!("entity://#{ws_name}/user/board-owner-#{System.unique_integer([:positive])}")

      create_cap =
        Ezagent.Capability.cap(
          :workspace,
          Ezagent.ActionSet.Workspace,
          :create_agent,
          workspace_uri,
          workspace_uri
        )

      create_cap =
        Ezagent.Test.CapHelper.signed_cap!(workspace_uri, owner_uri, create_cap)

      assert {:ok, _row} =
               Ezagent.Users.create(owner_uri, "test-password", [create_cap])

      assert :ok = Ezagent.Entity.spawn_principal(owner_uri)
      on_exit(fn -> Ezagent.Kind.terminate(owner_uri) end)

      owner_ctx = %{
        caller: owner_uri,
        authenticated_principal: owner_uri,
        caps: Ezagent.Identity.list_caps_for(owner_uri)
      }

      # --- 本 session 的 kanban-assistant(脑),是个活 agent 成员 ------------------
      assistant_uri =
        live_agent(ws_name, "kanban-assistant-#{System.unique_integer([:positive])}")

      session_uri =
        URI.new!("session://#{ws_name}/default/t4a-#{System.unique_integer([:positive])}")

      {:ok, _sess_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors(),
          owner_uri: owner_uri
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)

      :ok = join_member(session_uri, assistant_uri, "kanban-assistant", admin_ctx)

      # --- T4a 入口:建板 + 发钥匙 ----------------------------------------------
      board_name = "board-#{System.unique_integer([:positive])}"

      assert {:ok, %{board_uri: board_uri, assistant_uri: minted_to, minted: minted}} =
               BoardProvision.create_board(
                 workspace_uri,
                 session_uri,
                 %{
                   name: board_name,
                   board_role: "kanban-manager",
                   flavor: @flavor,
                   assistant_role: "kanban-assistant"
                 },
                 Ezagent.ActionSet.Kanban,
                 owner_ctx
               )

      # (a) 新板存在 + owner = 建板触发者(mint 的 granter)
      assert board_uri == Ezagent.URI.agent(ws_name, board_name)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(board_uri)
      assert URI.to_string(minted_to) == URI.to_string(assistant_uri)

      assert URI.to_string(
               Ezagent.CapabilityRegistry.data_owner_of(
                 Ezagent.ActionSet.Kanban,
                 Ezagent.URI.instance(board_uri)
               )
             ) == URI.to_string(owner_uri)

      # 铸了全 20 个 kanban 动作,granted_by 全 = owner(板主人)
      assert length(minted) == length(Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban))
      assert Enum.all?(minted, &(URI.to_string(&1.granted_by) == URI.to_string(owner_uri)))

      # 挂载落表:本 session 有指向新板的 operate 挂载行(建板 = operate)
      board_mount = MountRow.get(session_uri, board_uri, assistant_uri, Ezagent.ActionSet.Kanban)
      assert board_mount != nil
      assert board_mount.access == "operate"
      assert Enum.any?(MountRow.list_for_session(session_uri), &(&1.id == board_mount.id))

      # (b) assistant 持指向该新板的实例精确 add_node cap
      assert eventually(fn -> holds_board_cap?(assistant_uri, board_uri, :add_node) end)

      minted_add = Enum.find(minted, &(&1.action == :add_node))
      assert minted_add.behavior == Ezagent.ActionSet.Kanban
      assert minted_add.instance == Ezagent.URI.instance(board_uri)
      refute minted_add.instance == :any

      # (c) assistant 自身份 dispatch kanban.add_node 到新板成功(经 minted 钥匙)。
      # canonical admin 经 board K.grant 播根 → assistant 认领根 → assistant 在自己认领的
      # 节点下 add_node 子 = 真正成功。
      assert {:ok, %{id: "n1"}} =
               dispatch(board_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      assert {:ok, %{}} = dispatch_as(assistant_uri, board_uri, :claim_node, %{id: "n1"})

      assert {:ok, %{id: child_id}} =
               dispatch_as(assistant_uri, board_uri, :add_node, %{parent_id: "n1", title: "子"})

      assert is_binary(child_id)

      # 无关板:assistant 没这块板的钥匙 → CBAC 拒(实例精确越权拒)。
      unrelated =
        create_board_as_admin(
          workspace_uri,
          "unrelated-#{System.unique_integer([:positive])}",
          admin_ctx
        )

      assert {:error, :missing_cap} =
               dispatch_as(assistant_uri, unrelated, :add_node, %{parent_id: "", title: "x"})
    end)
  end

  # --- helpers -------------------------------------------------------------

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

  defp create_board_as_admin(workspace_uri, name, admin_ctx) do
    assert {:ok, %{agent_uri: uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
               admin_ctx
             )

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
           ctx: %{
             caller: caller,
             authenticated_principal: caller,
             caps: caps,
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
             held = Ezagent.IdentityCaps.load_persisted(member_uri)
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
    target = Ezagent.URI.with_action(board_uri, :kanban, action)

    caps =
      if caller == User.admin_uri() do
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller)])
      else
        caps
      end

    Ezagent.Router.dispatch(
      Ezagent.Cmd.new(
        target,
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
