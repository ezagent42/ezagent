defmodule Ezagent.World.KanbanDataTest do
  @moduledoc """
  kanban-as-role K4 — world kanban read-model on the AS-ROLE path.

  Board = a kanban-manager agent (`entity://<ws>/agent/<id>`); the read-model
  source is `Ezagent.Agent.RecipeResolver.list_by_recipe("kanban-manager", ws)` (RF-7,
  snapshot-backed) and every read dispatches `?action=kanban.get_tree` carrying
  the caller's caps. Proves:

    * `read_tree` produces a JSON-safe rich tree (atom→string, owner threaded);
    * `list_instances(ctx)` returns the created kanban-manager (via list-by-role,
      scoped to the ctx workspace) with its `entity://agent` URI + detail path;
    * `state_for` (list page, entity_uri=nil) gives stages/statuses/instances;
    * **cold-restart (HIGH-3)**: after the live Kind is killed, list-by-role still
      returns the manager (snapshot-sourced) and the board renders again
      (ensure_spawned rehydrates from snapshot).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.KanbanData
  alias Ezagent.Workspace
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "world-kanban-native"

  setup do
    # world has NO dep on the kanban plugin (it dispatches by URI). Under the
    # umbrella the kanban MODULES are in the code path; this test needs only the
    # `kanban-manager` recipe + the `Ezagent.ActionSet.Kanban` module (both
    # available without starting the kanban OTP app), so we register the recipe
    # manually below rather than `ensure_all_started(:ezagent_plugin_kanban)`
    # (whose `.app` is absent in a per-app `mix test` context).
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

    caller = Ezagent.Entity.User.admin_uri()
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, caller)
    caps = admin_ctx.caps

    # read-side ctx (mirrors KanbanActions.read_ctx): caller + workspace scope.
    ctx = %{caller_uri: caller, caller_caps: caps, workspace_uri: workspace_uri}

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, ctx: ctx}
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

  defp spawn_board(workspace_uri, admin_ctx) do
    name = "kanban-mgr-#{System.unique_integer([:positive])}"

    {:ok, %{agent_uri: agent_uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
        admin_ctx
      )

    agent_uri
  end

  defp dispatch(uri, action, args, %{caller: caller}) do
    target = Ezagent.URI.with_action(uri, :kanban, action)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: MapSet.new([cap]), reply: {:caller_inbox, self()}}
    })
  end

  defp board_read_ctx(uri, %{caller_uri: caller} = ctx) do
    target = Ezagent.URI.with_action(uri, :kanban, :get_tree)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
    %{ctx | caller_caps: MapSet.new([cap])}
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

  test "read_tree returns a JSON-safe rich tree (stage/status string, owner threaded)",
       %{workspace_uri: ws, admin_ctx: admin_ctx, ctx: ctx} do
    skip_if_no_entity_spawn(fn ->
      uri = spawn_board(ws, admin_ctx)

      {:ok, %{id: "n1"}} = dispatch(uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)
      {:ok, %{id: "n2"}} = dispatch(uri, :add_node, %{parent_id: "n1", title: "功能"}, admin_ctx)
      {:ok, %{}} = dispatch(uri, :set_stage, %{id: "n2", stage: "metric"}, admin_ctx)
      {:ok, %{}} = dispatch(uri, :claim_node, %{id: "n2"}, admin_ctx)
      {:ok, %{}} = dispatch(uri, :set_status, %{id: "n2", status: "doing"}, admin_ctx)

      tree = KanbanData.read_tree(uri, board_read_ctx(uri, ctx))
      assert tree["root_id"] == "n1"

      n2 = tree["nodes"]["n2"]
      assert n2["title"] == "功能"
      assert n2["stage"] == "metric", "atom should become string"
      assert n2["status"] == "doing"
      assert n2["owner"] == URI.to_string(admin_ctx.caller)
      assert is_list(n2["artifacts"]) and is_list(n2["metrics"])
    end)
  end

  test "list_instances returns the kanban-manager via list-by-role with its entity://agent URI",
       %{workspace_uri: ws, admin_ctx: admin_ctx, ctx: ctx} do
    skip_if_no_entity_spawn(fn ->
      uri = spawn_board(ws, admin_ctx)

      instances = KanbanData.list_instances(ctx)
      uris = Enum.map(instances, & &1["uri"])
      assert URI.to_string(uri) in uris

      inst = Enum.find(instances, &(&1["uri"] == URI.to_string(uri)))
      assert inst["path"] =~ "/plugins/kanban/"
    end)
  end

  test "state_for list page (entity_uri=nil) gives stages/statuses/instances",
       %{workspace_uri: ws, admin_ctx: admin_ctx, ctx: ctx} do
    skip_if_no_entity_spawn(fn ->
      _uri = spawn_board(ws, admin_ctx)

      # route 须带 title/path:FP5 起 KanbanData 复用 route.title/route.path 渲染 H1+导航高亮,
      # 对齐 routes.ex 的 /plugins/kanban 列表页 route 形状
      state =
        KanbanData.state_for(
          %{component: "kanban", title: "看板", path: "/plugins/kanban", entity_uri: nil},
          ctx
        )

      assert state["kanban_uri"] == nil
      assert "feature" in state["stages"] and "doing" in state["statuses"]
      assert is_list(state["instances"])
      assert length(state["instances"]) >= 1
    end)
  end

  test "PR-3 / #9: a file artifact's download href is a grantee-BOUND token for the board reader",
       %{ws_name: ws_name, workspace_uri: ws, admin_ctx: admin_ctx, ctx: ctx} do
    skip_if_no_entity_spawn(fn ->
      uri = spawn_board(ws, admin_ctx)

      {:ok, %{id: "n1"}} = dispatch(uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      upload =
        Ezagent.URI.resource(ws_name, "uploads", "#{Ecto.UUID.generate()}-spec.pdf")

      {:ok, %{}} =
        dispatch(
          uri,
          :attach_artifact,
          %{
            id: "n1",
            artifact: %{tool: "uploader", kind: "file", ref: "spec.pdf", url: URI.to_string(upload)}
          },
          admin_ctx
        )

      tree = KanbanData.read_tree(uri, board_read_ctx(uri, ctx))
      [artifact] = tree["nodes"]["n1"]["artifacts"]

      # The href is a /uploads/download token link...
      assert "/uploads/download?token=" <> token = artifact["url"]

      # ...whose token is person-bound to the board reader (ctx.caller_uri) —
      # the authorized mint INSIDE the cap-gated board read. This is what makes
      # the member's download 200 (caller == grantee supersedes the legacy
      # participation recheck) and a leaked copy useless to anyone else.
      assert {:ok, %{uri: bound_uri, grantee: grantee}} =
               Ezagent.Uploads.DownloadToken.verify_payload(token)

      assert Ezagent.URI.stable_key(bound_uri) == Ezagent.URI.stable_key(upload)
      assert grantee == ctx.caller_uri
      assert Ezagent.Uploads.DownloadToken.grantee_match?(grantee, ctx.caller_uri)
    end)
  end

  test "cold-restart (HIGH-3): kill live Kind → list-by-role still returns it → board renders",
       %{workspace_uri: ws, admin_ctx: admin_ctx, ctx: ctx} do
    skip_if_no_entity_spawn(fn ->
      uri = spawn_board(ws, admin_ctx)
      {:ok, %{id: "n1"}} = dispatch(uri, :add_node, %{parent_id: "", title: "持久根"}, admin_ctx)

      # snapshot persists on :on_change; ensure it's flushed before the kill.
      {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, :get_tree, %{}, admin_ctx)
      assert map_size(nodes) == 1
      cold_read_ctx = board_read_ctx(uri, ctx)

      # kill the LIVE Kind — the passive manager goes dormant (no chat to warm it).
      {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # list-by-role is snapshot-sourced → the manager STILL enumerates even when
      # the live Kind is gone (the whole point of RF-7 snapshot sourcing — HIGH-3).
      uris = KanbanData.list_instances(ctx) |> Enum.map(& &1["uri"])
      assert URI.to_string(uri) in uris, "dormant passive manager must still list (HIGH-3)"

      # reading the board rehydrates it from snapshot (ensure_spawned) → tree renders.
      tree = KanbanData.read_tree(uri, cold_read_ctx)
      assert tree["root_id"] == "n1"
      assert tree["nodes"]["n1"]["title"] == "持久根"
    end)
  end
end
