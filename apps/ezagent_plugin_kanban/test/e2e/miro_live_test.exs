defmodule EzagentPluginKanban.MiroLiveTest do
  @moduledoc """
  真实 Miro 往返 e2e（出站增量同步）。**默认排除**（:live_miro），需网络 + miro.yaml：

      mix test apps/ezagent_plugin_kanban/test/e2e/miro_live_test.exs --include live_miro

  验：① 复用同一块板（删旧建新，不新建板）；② ezagent 改名 → Miro 反映；
  ③ **布局**：节点位置不重叠。
  """
  use EzagentCore.DataCase, async: false
  @moduletag :live_miro

  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.Miro.Sync
  alias Ezagent.Workspace
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKanban.Application, as: KanbanApp

  # kanban-as-role：board = 一个 kanban-manager agent（K5 删了 resource Kanban Kind）。
  @flavor "miro-live-native"

  setup do
    {:ok, creds} = Miro.read_creds()
    board = creds.board_id || "uXjVHDS77F0="
    # 起点清空，保证断言确定
    :ok = Miro.delete_all_nodes(creds.token, board)

    # bootstrap the role × native machinery (mirror of K2/K3 setup) so the board
    # = a kanban-manager agent. Inlined (not a `test/support/*.ex` helper) because
    # `ezagent_plugin_check`'s registry-direct-call gate scans `elixirc_paths`
    # `.ex` files; `.exs` test files are exempt.
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "miro-live-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    admin_ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    %{
      board: board,
      token: creds.token,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    }
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

  # mint a fresh kanban-manager agent → its entity://agent URI is the board.
  defp new_board(%{workspace_uri: ws, admin_ctx: ctx}) do
    name = "kanban-mgr-#{System.unique_integer([:positive])}"

    {:ok, %{agent_uri: agent_uri}} =
      Workspace.create_agent(
        ws,
        %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
        ctx
      )

    agent_uri
  end

  defp contents(nodes), do: Enum.map(nodes, &get_in(&1, ["data", "nodeView", "data", "content"]))

  defp positions(nodes),
    do: Enum.map(nodes, &{get_in(&1, ["position", "x"]), get_in(&1, ["position", "y"])})

  test "出站增量同步：复用同板 + 改名反映 + 布局不重叠", %{board: board, token: token} do
    tree1 = %{
      root_id: "n1",
      nodes: %{
        "n1" => %{parent_id: nil, title: "产品根", order: 0},
        "n2" => %{parent_id: "n1", title: "功能A", order: 0},
        "n3" => %{parent_id: "n1", title: "功能B", order: 1},
        "n4" => %{parent_id: "n2", title: "子任务", order: 0}
      }
    }

    # 第一次同步
    assert {:ok, %{board_id: ^board, mapping: m1}} = Sync.sync_out(tree1, board)
    assert map_size(m1) == 4

    {:ok, nodes1} = Miro.get_nodes(token, board)
    assert length(nodes1) == 4
    c1 = contents(nodes1)
    assert Enum.any?(c1, &(&1 == "<p>功能A</p>"))
    assert Enum.any?(c1, &(&1 == "<p>子任务</p>"))

    # 布局：位置不能全重叠（kanban 自动布局或我们布局）
    pos = positions(nodes1)
    assert length(Enum.uniq(pos)) > 1, "节点位置重叠（布局失败）: #{inspect(pos)}"

    # 改名 + 复用同板（不新建板）
    tree2 = put_in(tree1, [:nodes, "n2", :title], "功能A改名了")
    assert {:ok, %{board_id: ^board}} = Sync.sync_out(tree2, board)

    {:ok, nodes2} = Miro.get_nodes(token, board)
    assert length(nodes2) == 4, "应复用同板仍 4 个节点"
    c2 = contents(nodes2)
    assert Enum.any?(c2, &(&1 == "<p>功能A改名了</p>")), "改名未反映: #{inspect(c2)}"
    refute Enum.any?(c2, &(&1 == "<p>功能A</p>")), "旧名应已删: #{inspect(c2)}"
  end

  test "入站非破坏性：人在 Miro 新加节点 → detect → dispatch 回 ezagent 树",
       %{board: board, token: token} = ctx do
    uri = new_board(ctx)

    admin =
      {Ezagent.URI.new!("entity://system/user/admin"),
       MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    # 1. ezagent 建树（真相源）
    assert {:ok, %{id: r}} = dispatch(uri, "add_node", %{parent_id: "", title: "入站根"}, admin)
    {:ok, %{tree: %{nodes: nodes, root_id: root}}} = dispatch(uri, "get_tree", %{}, admin)

    # 2. 出站 → 建立 ez_id↔miro_id 映射（入站回声基线）
    assert {:ok, %{mapping: mapping}} = Sync.sync_out(%{nodes: nodes, root_id: root}, board)
    root_miro = mapping[r]

    # 3. 模拟「人在 Miro 手加一个子节点」（不经 ezagent）
    assert {:ok, _} = Miro.create_node(token, board, "<p>人在Miro加的</p>", root_miro)

    # 4. 入站检测：找出人新增、parent 反查回 ez_id
    {:ok, miro_nodes} = Miro.get_nodes(token, board)

    assert [%{content: "人在Miro加的", parent_ez_id: ^r} = op] =
             Sync.detect_inbound(miro_nodes, mapping)

    # 5. 非破坏性回写：dispatch add_node（P14）
    assert {:ok, %{id: _}} =
             dispatch(
               uri,
               "add_node",
               %{parent_id: op.parent_ez_id || "", title: op.content},
               admin
             )

    # 6. ezagent 树确实多了这个人加的节点
    {:ok, %{tree: %{nodes: nodes2}}} = dispatch(uri, "get_tree", %{}, admin)
    titles = nodes2 |> Map.values() |> Enum.map(& &1.title)
    assert "人在Miro加的" in titles
  end

  test "富格式出站：真节点(认领+状态+指标) → Miro label 含 ◑/[stage]/@owner/📊",
       %{board: board, token: token} = ctx do
    uri = new_board(ctx)

    admin =
      {Ezagent.URI.new!("entity://system/user/admin"),
       MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    {:ok, %{id: r}} = dispatch(uri, "add_node", %{parent_id: "", title: "产品"}, admin)
    {:ok, %{id: c}} = dispatch(uri, "add_node", %{parent_id: r, title: "功能A"}, admin)
    {:ok, %{}} = dispatch(uri, "set_stage", %{id: c, stage: "dev"}, admin)
    {:ok, %{}} = dispatch(uri, "claim_node", %{id: c}, admin)
    {:ok, %{}} = dispatch(uri, "set_status", %{id: c, status: "doing"}, admin)

    {:ok, %{}} =
      dispatch(
        uri,
        "set_metric",
        %{id: c, metric: %{"name" => "周闭环", "target" => 2, "current" => 1}},
        admin
      )

    {:ok, %{tree: %{nodes: nodes, root_id: root}}} = dispatch(uri, "get_tree", %{}, admin)
    assert {:ok, _} = Sync.sync_out(%{nodes: nodes, root_id: root}, board)

    {:ok, miro} = Miro.get_nodes(token, board)
    rich = Enum.find(contents(miro), &(&1 =~ "功能A"))
    assert rich =~ "◑", "status 图标缺失: #{rich}"
    assert rich =~ "[dev]", "stage 标签缺失: #{rich}"
    assert rich =~ "@admin", "owner 缺失: #{rich}"
    assert rich =~ "📊周闭环:1/2", "metric 缺失: #{rich}"
  end

  describe "MiroSync 双向同步器 + 生命周期" do
    setup ctx do
      uri = new_board(ctx)

      %{
        uri: uri,
        admin:
          {Ezagent.URI.new!("entity://system/user/admin"),
           MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
      }
    end

    test "sync_now：一轮内 出站(ezagent→Miro) + 入站(人加→ezagent)", ctx do
      %{token: token, uri: uri, admin: admin} = ctx
      assert {:ok, %{id: _}} = dispatch(uri, "add_node", %{parent_id: "", title: "轮询根"}, admin)

      # V5 A1b：独占一块板（测试收尾 poller terminate/2 会联动删板，不能删共享板）。
      {:ok, board} = Miro.create_board(token, "sync-now-test")

      {:ok, _poller} = EzagentPluginKanban.MiroSync.start_link(uri: uri, board_id: board)

      # 第一轮：纯出站（无人加）。V5 A1b：sync_now 按 URI 经 resolver seam 解析。
      assert {:ok, %{inbound: 0}} = EzagentPluginKanban.MiroSync.sync_now(uri)
      {:ok, n1} = Miro.get_nodes(token, board)
      assert Enum.any?(contents(n1), &(&1 =~ "轮询根"))
      root_miro = Enum.find(n1, &get_in(&1, ["data", "isRoot"]))["id"]

      # 人在 Miro 手加 → 第二轮：入站 detect+回写 + 出站重建
      assert {:ok, _} = Miro.create_node(token, board, "<p>轮询入站</p>", root_miro)
      assert {:ok, %{inbound: 1}} = EzagentPluginKanban.MiroSync.sync_now(uri)
      {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, "get_tree", %{}, admin)
      assert "轮询入站" in (nodes |> Map.values() |> Enum.map(& &1.title))
    end

    test "board_gone 非破坏性：板被删 → :board_gone，ezagent 树不动", ctx do
      %{token: token, uri: uri, admin: admin} = ctx
      assert {:ok, %{id: _}} = dispatch(uri, "add_node", %{parent_id: "", title: "保留根"}, admin)
      # 造一块板再删掉 → 确定性 404
      {:ok, gone} = Miro.create_board(token, "gone-test")
      :ok = Miro.delete_board(token, gone)

      {:ok, _poller} = EzagentPluginKanban.MiroSync.start_link(uri: uri, board_id: gone)

      assert {:error, :board_gone} = EzagentPluginKanban.MiroSync.sync_now(uri)
      # ezagent 真相源未被破坏
      {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, "get_tree", %{}, admin)
      assert "保留根" in (nodes |> Map.values() |> Enum.map(& &1.title))
    end

    test "teardown：停 poller → terminate/2 联动删 Miro 板", ctx do
      %{token: token, uri: uri} = ctx
      {:ok, throwaway} = Miro.create_board(token, "teardown-test")

      {:ok, poller} = EzagentPluginKanban.MiroSync.start_link(uri: uri, board_id: throwaway)

      # V5 A1b：删板逻辑搬进 terminate/2（ANY stop 都触发），public teardown/unbind 已删。
      assert :ok = GenServer.stop(poller)
      refute Process.alive?(poller)
      # 板已删：GET → 404
      assert {:error, {:http_status, 404, _}} = Miro.get_nodes(token, throwaway)
    end

    test "bind/teardown：监督树下起同步进程 + sync_now(uri 经 seam) + terminate_child 删板停进程", ctx do
      %{token: token, uri: uri, admin: admin} = ctx
      {:ok, board} = Miro.create_board(token, "bind-test")
      assert {:ok, %{id: _}} = dispatch(uri, "add_node", %{parent_id: "", title: "bind根"}, admin)

      # bind：在 plugin 监督树下起同步进程（不手动 start_link）
      assert {:ok, poller} = EzagentPluginKanban.MiroSync.bind(uri, board)
      assert is_pid(poller)

      # 经 uri（resolver seam 解析）触发同步
      assert {:ok, %{inbound: 0}} = EzagentPluginKanban.MiroSync.sync_now(uri)
      {:ok, n} = Miro.get_nodes(token, board)
      assert Enum.any?(contents(n), &(&1 =~ "bind根"))

      # seam terminate_child：删板（terminate/2）+ 停进程（transient 不重生）
      assert :ok =
               Ezagent.Runtime.Resolver.terminate_child(
                 EzagentPluginKanban.MiroSync.resolver_key(uri),
                 EzagentPluginKanban.MiroSyncSupervisor
               )

      refute Process.alive?(poller)
      assert {:error, {:http_status, 404, _}} = Miro.get_nodes(token, board)
    end
  end

  defp dispatch(uri, action, args, {caller, caps}) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=kanban.#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end
end
