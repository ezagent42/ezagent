defmodule EzagentPluginKanban.E2E.BoardProvisionGrantTest do
  @moduledoc """
  T4a acceptance —— 运行时"建板"入口 `EzagentPluginKanban.BoardProvision.create_board/5`:
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
  alias EzagentPluginKanban.BoardProvision
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
      # --- owner = 常规用户(会话 owner / 建板触发者)。⑥ 后**不再预授 create_agent**:
      # 建板授权由 create_board 内的一次性 provision authority(#1457 后经
      # `{:admin, admin_uri}` 具名签发;成员守卫 + passive flavor 白名单),本测试即证明
      # 「普通成员零 create_agent cap 也能建板」这条产品路。
      owner_uri =
        URI.new!("entity://#{ws_name}/user/board-owner-#{System.unique_integer([:positive])}")

      {:ok, _owner_pid} =
        Ezagent.Kind.spawn(User, %{uri: owner_uri, initial_caps: MapSet.new()})

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

      # ⑥ 成员守卫:建板人必须是本 session 成员(collab 模型「编辑 session 成员可建板」)。
      :ok = join_member(session_uri, owner_uri, "member", admin_ctx)

      # --- T4a 入口:建板 + 发钥匙 ----------------------------------------------
      board_name = "board-#{System.unique_integer([:positive])}"

      assert {:ok,
              %{
                board_uri: board_uri,
                assistant_uri: minted_to,
                minted: minted,
                creator_minted: creator_minted
              }} =
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

      # 发钥匙不落挂载表:assistant 的 durable caps(`Ezagent.EntityCaps.load/1`)里
      # 含指向新板的 Kanban behavior cap,operate = 持写动作(:add_node)
      assert eventually(fn -> holds_durable_board_cap?(assistant_uri, board_uri, :add_node) end)

      # (b) assistant 持指向该新板的实例精确 add_node cap
      assert eventually(fn -> holds_board_cap?(assistant_uri, board_uri, :add_node) end)

      minted_add = Enum.find(minted, &(&1.action == :add_node))
      assert minted_add.behavior == Ezagent.ActionSet.Kanban
      assert minted_add.instance == Ezagent.URI.instance(board_uri)
      refute minted_add.instance == :any

      # --- 分层债 ⑧:建板人(creator human)也当场拿到指向新板的 operate 钥匙 -------
      # 之前只给 assistant 发钥匙,建板的人类只持 Manage cap(管 agent 生命周期),
      # 读写自己的板全 unauthorized。修复后 create_board 给 creator 也 mount 一把
      # 全动作 operate cap(granter = 板主人自己,{:held_by, creator} 自路径)。
      assert length(creator_minted) ==
               length(Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban))

      assert Enum.all?(
               creator_minted,
               &(URI.to_string(&1.granted_by) == URI.to_string(owner_uri))
             )

      # creator 持实例精确 operate cap,且 durable(EntityCaps.load 可见,不查挂载表):
      # operate = 持写动作(:add_node),read 面 = 持 :get_tree
      assert eventually(fn -> holds_board_cap?(owner_uri, board_uri, :add_node) end)
      assert eventually(fn -> holds_durable_board_cap?(owner_uri, board_uri, :add_node) end)
      assert eventually(fn -> holds_durable_board_cap?(owner_uri, board_uri, :get_tree) end)

      # creator 自身份 dispatch 读/写自己的板成功(⑧ 的直接验收:owner 不再 unauthorized)
      assert {:ok, _tree} = dispatch_as(owner_uri, board_uri, :get_tree, %{})

      # (c) assistant 自身份 dispatch kanban.add_node 到新板成功(经 minted 钥匙)。
      # 新协作模型：加节点自动认领 —— assistant 自身份加根(自动认领)再在自己节点下加子 = 真正成功。
      assert {:ok, %{id: "n1"}} =
               dispatch_as(assistant_uri, board_uri, :add_node, %{parent_id: "", title: "根"})

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

  @tag :integration
  test "⑳ 无 assistant 会话建板成功: assistant 钥匙降级为增强,建板人钥匙照发",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      owner_uri =
        URI.new!("entity://#{ws_name}/user/no-assist-#{System.unique_integer([:positive])}")

      {:ok, _owner_pid} =
        Ezagent.Kind.spawn(User, %{uri: owner_uri, initial_caps: MapSet.new()})

      owner_ctx = %{caller: owner_uri, caps: Ezagent.Identity.list_caps_for(owner_uri)}

      # session 里**没有** kanban-assistant 成员(只有建板人自己)。
      session_uri =
        URI.new!("session://#{ws_name}/default/t4a-na-#{System.unique_integer([:positive])}")

      {:ok, _sess_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors(),
          owner_uri: owner_uri
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)
      :ok = join_member(session_uri, owner_uri, "member", admin_ctx)

      board_name = "board-na-#{System.unique_integer([:positive])}"

      # ⑳:resolve_assistant 失败不再整体 fail —— assistant 钥匙跳过(nil / []),
      # 主链(建宿主 + 建板人钥匙)照走。
      assert {:ok,
              %{
                board_uri: board_uri,
                assistant_uri: nil,
                minted: [],
                creator_minted: creator_minted
              }} =
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

      # 板存在 + 归属建板人
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(board_uri)

      assert URI.to_string(
               Ezagent.CapabilityRegistry.data_owner_of(
                 Ezagent.ActionSet.Kanban,
                 Ezagent.URI.instance(board_uri)
               )
             ) == URI.to_string(owner_uri)

      # 建板人钥匙照发(plugin 基线):全动作 + durable cap(EntityCaps.load)+ 真 dispatch 通
      assert length(creator_minted) ==
               length(Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban))

      assert eventually(fn -> holds_durable_board_cap?(owner_uri, board_uri, :add_node) end)
      assert eventually(fn -> holds_durable_board_cap?(owner_uri, board_uri, :get_tree) end)

      assert eventually(fn -> holds_board_cap?(owner_uri, board_uri, :add_node) end)
      assert {:ok, _tree} = dispatch_as(owner_uri, board_uri, :get_tree, %{})
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

  # durable 面:钥匙 absorb 进 grantee 的 identity slice(重启不丢),
  # 读 `Ezagent.EntityCaps.load/1` 反查是否持指向该板的 Kanban behavior cap。
  # read = 含 :get_tree;operate = 含写动作(如 :add_node)。
  defp holds_durable_board_cap?(grantee, board_uri, action) do
    Enum.any?(Ezagent.EntityCaps.load(grantee), fn cap ->
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
