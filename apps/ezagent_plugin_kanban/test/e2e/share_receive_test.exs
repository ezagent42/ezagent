defmodule EzagentPluginKanban.E2E.ShareReceiveTest do
  @moduledoc """
  ㊵ 人本位 receive acceptance —— 分享链接被点击时,钥匙发给**点击者这个人**
  (`CompositionCaps.mint_cap/4`,cap absorb 进点击者 identity slice,不落挂载表),
  不再解析落点 session、不再发给 kanban-assistant。

  证四件事:
    (a) 人本位钥匙:点击者本人的 durable caps(`Ezagent.EntityCaps.load/1`)含
        指向板的只读 cap(read=持 :get_tree,不持写动作 :add_node —— 读/写按
        点击者与板的关系在 dispatch chokepoint 如实判);
    (b) 幂等:同 token 重复接收,指向板的 :get_tree cap 仍只 1 张;
    (c) 跨 ws 板:D4 read 放开 —— 点击者与板不同 workspace 也能收只读钥匙
        (`ws_policy/3` 单守卫点,D4 拍板后只翻这一处);
    (d) 坏 board 字符串 → `:bad_board`;坏 payload → `:bad_token`。

  (tab 可见性:人本位下点击者钥匙即数据源 —— `WorldData.session_boards/2`
  的 ws∪cap 派生枚举,见 world_data_scope_test。)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Agent.RecipeRegistry
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
  test "receive_shared_board: 人本位只读挂载(person 行+幂等+跨ws read 放开);坏输入优雅报错",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      board_uri = create_board_as_admin(workspace_uri, "b-#{u()}", admin_ctx)
      payload = %{"board" => s(board_uri), "behavior" => "Ezagent.ActionSet.Kanban"}

      clicker = spawn_user(ws_name, "clicker")

      # (a) 人本位:钥匙发给点击者本人,absorb 进其 identity slice(不落挂载表)。
      assert {:ok, %{board_uri: ^board_uri, grantee: ^clicker}} =
               ShareReceive.receive_shared_board(payload, clicker)

      # read = 持指向板的 :get_tree cap;不持写动作(:add_node)cap。
      assert eventually(fn -> :get_tree in durable_board_actions(clicker, board_uri) end)
      refute :add_node in durable_board_actions(clicker, board_uri)

      # 读/写按点击者与板的关系判(gate check 在 dispatch chokepoint):
      # 点击者本人持只读钥匙 → get_tree 成;无写钥匙 → add_node 拒。
      assert eventually(fn -> holds_board_cap?(clicker, board_uri, :get_tree) end)
      refute holds_board_cap?(clicker, board_uri, :add_node)
      assert {:ok, %{tree: _}} = dispatch_as(clicker, board_uri, :get_tree, %{})

      # #1457 target verifier:无候选钥匙的拒绝 reason 收敛为 :missing_cap。
      assert {:error, :missing_cap} =
               dispatch_as(clicker, board_uri, :add_node, %{parent_id: "", title: "x"})

      # (b) 幂等:同 token 重复接收,指向板的 :get_tree cap 仍只 1 张。
      assert {:ok, _} = ShareReceive.receive_shared_board(payload, clicker)

      assert durable_board_actions(clicker, board_uri)
             |> Enum.count(&(&1 == :get_tree)) == 1

      # (c) 跨 ws:点击者在另一个 workspace —— D4 read 放开,同样收到只读钥匙。
      other_ws = "d3x-#{u()}"
      {:ok, _} = Workspace.create(other_ws, %{})
      outsider = spawn_user(other_ws, "outsider")

      assert {:ok, %{grantee: ^outsider}} =
               ShareReceive.receive_shared_board(payload, outsider)

      assert eventually(fn -> :get_tree in durable_board_actions(outsider, board_uri) end)
      assert eventually(fn -> holds_board_cap?(outsider, board_uri, :get_tree) end)

      # (d) 坏 board → :bad_board;坏 payload → :bad_token。
      assert {:error, :bad_board} =
               ShareReceive.receive_shared_board(
                 %{"board" => "not a uri", "behavior" => "Ezagent.ActionSet.Kanban"},
                 clicker
               )

      assert {:error, :bad_token} = ShareReceive.receive_shared_board(%{}, clicker)
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

  # 发钥匙断言的统一形态:某人 durable caps(EntityCaps.load/1)里指向该板的
  # Kanban behavior cap 的 action 列表(read=含 :get_tree,operate=含写动作)。
  defp durable_board_actions(grantee, board_uri) do
    instance = Ezagent.URI.instance(board_uri)

    Ezagent.EntityCaps.load(grantee)
    |> Enum.filter(&(&1.behavior == Ezagent.ActionSet.Kanban and &1.instance == instance))
    |> Enum.map(& &1.action)
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
