defmodule EzagentPluginKanban.WorldDataScopeTest do
  @moduledoc """
  Task 2 —— 看板"发现"按 CBAC 权属收敛。

  `KanbanData.list_instances/1` 从 fail-open（谁都看到全 workspace 的板）收敛成：

    * **普通用户只看到自己有权的板**：own（板的 `data_owner` 是 caller）或持有
      指向该板的 cap（instance = board URI）；
    * **workspace admin 看全部**（`Ezagent.Identity.AdminAuthority.admin?/2`）。

  board = kanban-manager agent（`entity://<ws>/agent/<id>`），造法照
  `Ezagent.World.KanbanDataTest`（同一 flavor / recipe / workspace setup）。
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginKanban.WorldData, as: KanbanData
  alias Ezagent.Workspace
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Capability}
  alias EzagentPluginKanban.Application, as: KanbanApp

  # 独立 flavor 名 —— AgentFlavorRegistry 是全局注册表（非 per-test sandbox），
  # 与 KanbanDataTest 的 "world-kanban-native" 撞名会 raise（不同 cap_policy 闭包）。
  @flavor "world-kanban-scope-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "wk-#{System.unique_integer([:positive])}"
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

    admin = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, admin).caps

    # alice/bob 是 LIVE User Kind —— 建板时才是合法的 creator-manage-cap 授予对象
    # （否则 grant dispatch 撞 `:no_such_actor`）。初始 genesis caps 让 create_agent
    # 授权通过；板的 data_owner 随 creator（alice/bob）定，own-branch 可测。可见性 ctx
    # 里换成空 caps，让 alice/bob 在 `admin?/2` 下按普通用户判（其 URI host≠system）。
    alice = URI.new!("entity://#{ws_name}/user/alice")
    bob = URI.new!("entity://#{ws_name}/user/bob")
    alice_caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, alice).caps
    bob_caps = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, bob).caps
    :ok = spawn_user(alice, alice_caps)
    :ok = spawn_user(bob, bob_caps)

    {:ok,
     ws_name: ws_name,
     workspace_uri: workspace_uri,
     admin: admin,
     admin_caps: admin_caps,
     alice_caps: alice_caps,
     bob_caps: bob_caps,
     alice: alice,
     bob: bob}
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
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

  # 以 `caller`（授权用 genesis caps）创建一张 board —— 板的 `data_owner`（经 lineage /
  # creator）随 caller 定，让 own-branch 可测。
  defp spawn_board_as(workspace_uri, caller, caps, name) do
    {:ok, %{agent_uri: agent_uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
        %{caller: caller, caps: caps}
      )

    agent_uri
  end

  # 指向某 board 的 kanban operate cap（instance = board URI）—— Task 3/4/5 发钥匙的形状。
  defp board_cap(board_uri, workspace_uri, grantee) do
    requested =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Kanban,
        :any,
        board_uri,
        workspace_uri
      )

    Ezagent.Test.CapHelper.signed_cap!(board_uri, grantee, requested)
  end

  defp uris(instances), do: Enum.map(instances, & &1["uri"])

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end

  test "非 admin 只看到自己 own 的板（own-branch）",
       %{workspace_uri: ws, alice_caps: alice_caps, bob_caps: bob_caps, alice: alice, bob: bob} do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")
      b = spawn_board_as(ws, bob, bob_caps, "board-b")

      ctx_a = %{caller_uri: alice, caller_caps: MapSet.new(), workspace_uri: ws}
      seen = uris(KanbanData.list_instances(ctx_a))

      assert URI.to_string(a) in seen, "alice 应看到自己 own 的 board-a"
      refute URI.to_string(b) in seen, "alice 不应看到 bob 的 board-b"
    end)
  end

  test "admin 看到全 workspace 的板（admin-branch）",
       %{
         workspace_uri: ws,
         alice_caps: alice_caps,
         bob_caps: bob_caps,
         admin_caps: admin_caps,
         admin: admin,
         alice: alice,
         bob: bob
       } do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")
      b = spawn_board_as(ws, bob, bob_caps, "board-b")

      ctx_admin = %{caller_uri: admin, caller_caps: admin_caps, workspace_uri: ws}
      seen = uris(KanbanData.list_instances(ctx_admin))

      assert URI.to_string(a) in seen and URI.to_string(b) in seen,
             "admin 应看到全 workspace 的板"
    end)
  end

  test "非 admin 持指向某板的 cap → 看到该板，无 cap 不看到（cap-branch）",
       %{ws_name: ws_name, workspace_uri: ws, alice_caps: alice_caps, alice: alice} do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")
      b = spawn_board_as(ws, alice, alice_caps, "board-b")

      carol = URI.new!("entity://#{ws_name}/user/carol")
      # carol 既非 admin，也不 own 任何板；只持一张指向 board-b 的 cap。
      ctx_c = %{
        caller_uri: carol,
        caller_caps: MapSet.new([board_cap(b, ws, carol)]),
        workspace_uri: ws
      }

      seen = uris(KanbanData.list_instances(ctx_c))

      assert URI.to_string(b) in seen, "carol 持 board-b 的 cap 应看到它"
      refute URI.to_string(a) in seen, "carol 无 board-a 的权，不应看到"
    end)
  end

  # Task 1 — `session_boards/2`：session-scoped board 读入口。从 session 解析出它的
  # workspace（`Ezagent.URI.workspace_of/1`，board 是 workspace 级 actor），
  # `list_by_recipe("kanban-manager", ws)` 枚举，再复用同一 `visible?` CBAC 收敛。
  # 与 `list_instances/1` 同形，只是 workspace 从 session URI 解析而非 ctx。
  test "session_boards/2：非 admin 只看到自己 own 的板（own-branch）",
       %{
         ws_name: ws_name,
         workspace_uri: ws,
         alice_caps: alice_caps,
         bob_caps: bob_caps,
         alice: alice,
         bob: bob
       } do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")
      b = spawn_board_as(ws, bob, bob_caps, "board-b")

      session = Ezagent.URI.session(ws_name, "default", "s1")
      ctx_a = %{caller_uri: alice, caller_caps: MapSet.new()}
      seen = uris(KanbanData.session_boards(session, ctx_a))

      assert URI.to_string(a) in seen, "alice 应看到自己 own 的 board-a"
      refute URI.to_string(b) in seen, "alice 不应看到 bob 的 board-b"
    end)
  end

  test "session_boards/2：admin 看到该 session workspace 的全部板（admin-branch）",
       %{
         ws_name: ws_name,
         workspace_uri: ws,
         admin_caps: admin_caps,
         alice_caps: alice_caps,
         bob_caps: bob_caps,
         admin: admin,
         alice: alice,
         bob: bob
       } do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")
      b = spawn_board_as(ws, bob, bob_caps, "board-b")

      session = Ezagent.URI.session(ws_name, "default", "s1")
      ctx_admin = %{caller_uri: admin, caller_caps: admin_caps}
      seen = uris(KanbanData.session_boards(session, ctx_admin))

      assert URI.to_string(a) in seen and URI.to_string(b) in seen,
             "admin 应看到该 workspace 全部板"
    end)
  end

  test "session_boards/2：无权 caller 看不到（no-perm-branch）",
       %{ws_name: ws_name, workspace_uri: ws, alice_caps: alice_caps, alice: alice} do
    skip_if_no_entity_spawn(fn ->
      a = spawn_board_as(ws, alice, alice_caps, "board-a")

      carol = URI.new!("entity://#{ws_name}/user/carol")
      session = Ezagent.URI.session(ws_name, "default", "s1")
      ctx_c = %{caller_uri: carol, caller_caps: MapSet.new()}

      seen = uris(KanbanData.session_boards(session, ctx_c))
      refute URI.to_string(a) in seen, "carol 无权，不应看到 alice 的 board-a"
    end)
  end
end
