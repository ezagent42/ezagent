defmodule EzagentPluginKanban.E2E.RoleNativeCreateTest do
  @moduledoc """
  K3 acceptance — create a `kanban-manager` agent (role × native) via the RF-5a
  role-create path, and prove the three properties the as-role kanban must hold:

    1. the recipe's kanban actions dispatch via
       `entity://<ws>/agent/<id>?action=kanban.<a>` carrying the CALLER's caps
       (K1 proves the recipe carries all 20; K2 proves RF-1 resolves them on
       the Entity.Agent host — here we exercise add_node/get_tree/claim/rename);
       the board persists on the Entity.Agent `:kanban` snapshot slice
       (`get_tree` reads it back).
    2. **passive isolation** (RF-6): the kanban-manager carries the durable
       `passive` marker, and the three gates that read it reject it —
         (a) `:join`  → `{:error, {:passive_actor_cannot_join, uri}}`,
         (b) the routing resolver's universal final-output gate drops it from
             recipients (mention / chat-receive), using the REAL passive
             predicate (reads the create-stored marker), with a no-gate control.
    3. **per-node owner** authz: `claim` sets `owner = caller`; a non-owner
       non-admin caller that HOLDS the kanban member cap (so the denial is the
       handler's `owner_or_admin?` gate, `{:error, :forbidden}`, NOT a cap miss)
       is denied `rename_node`. A positive control (the same caller successfully
       claims a DIFFERENT node) pins the denial to ownership, not authz.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, AgentPassiveAttributes, Agent.RecipeRegistry, UriQuery}
  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.{Matcher, Resolver}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "k3-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "k3-#{System.unique_integer([:positive])}"
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
  test "create kanban-manager (role × native): board persists + passive + per-node owner",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kanban-mgr-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
                 admin_ctx
               )

      assert agent_uri == Ezagent.URI.agent(ws_name, name)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

      # --- (1) board dispatches via entity://agent + persists -----------------
      assert {:ok, %{id: "n1"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      assert {:ok, %{id: "n2"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "n1", title: "功能点"}, admin_ctx)

      assert {:ok, %{tree: %{nodes: nodes}}} = dispatch(agent_uri, :get_tree, %{}, admin_ctx)
      assert map_size(nodes) == 2

      # Persisted on the Entity.Agent :kanban snapshot slice (not transient).
      assert {:ok, %{tree: %{nodes: slice_nodes}}} = Ezagent.Kind.get_slice(agent_uri, :kanban)
      assert map_size(slice_nodes) == 2

      # --- (2) passive isolation (RF-6) ---------------------------------------
      # Durable marker — the single fact all three gates read.
      assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)
      assert {:ok, true} = AgentPassiveAttributes.fetch(agent_uri)

      # (2a) :join gate — the kanban-manager cannot become a session member.
      join_ctx = %{
        self_uri: URI.new!("session://#{ws_name}/default/main"),
        kind_module: Ezagent.Entity.Session,
        caller: agent_uri
      }

      assert {:error, {:passive_actor_cannot_join, ^agent_uri}} =
               Ezagent.ActionSet.Session.handle_join(%{member: agent_uri}, join_ctx)

      # (2b) routing resolver universal final-output gate — drops the passive
      # kanban-manager from recipients, using the REAL passive predicate.
      passive_pred = fn uri -> match?({:ok, true}, UriQuery.resolve(:passive, uri)) end
      session = URI.new!("session://#{ws_name}/default/main")
      table = :"k3_resolver_#{System.unique_integer([:positive])}"
      :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)
      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [table])
      on_exit(fn -> restore_routing_tables(original) end)

      :ok = RoutingRegistry.put(table, Matcher.always(), [URI.to_string(agent_uri)])

      msg =
        Message.new(User.admin_uri(), %{text: "hello", attachments: []}, mentions: [])

      assert [] = Resolver.resolve(msg, session, [], passive?: passive_pred),
             "the passive kanban-manager must be dropped from recipients (RF-6 final-output gate)"

      # Control: WITHOUT the gate (never-passive default) the same rule routes to it.
      assert [^agent_uri] = Resolver.resolve(msg, session, [])

      # --- (3) per-node owner authz -------------------------------------------
      # Two distinct non-admin users, each holding the kanban member cap on the
      # :agent kind axis (the host is Entity.Agent → required-cap kind resolves
      # to :agent; a :kanban-kind cap would NOT match → false-pass trap).
      member_cap = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Kanban, :any)

      alice = %{
        caller: URI.new!("entity://#{ws_name}/user/alice"),
        caps: MapSet.new([member_cap])
      }

      bob = %{caller: URI.new!("entity://#{ws_name}/user/bob"), caps: MapSet.new([member_cap])}

      # 新协作模型：加节点自动认领（n1/n2 现由 admin 认领）。为验 per-node owner authz，
      # admin（board_admin）先退领成未认领（节点空 → H3 允许），再让 alice/bob 认领。
      assert {:ok, %{}} = dispatch(agent_uri, :unclaim_node, %{id: "n1"}, admin_ctx)
      assert {:ok, %{}} = dispatch(agent_uri, :unclaim_node, %{id: "n2"}, admin_ctx)

      # alice claims n2 → owner = alice.
      assert {:ok, %{}} = dispatch(agent_uri, :claim_node, %{id: "n2"}, alice)

      assert {:ok, %{tree: %{nodes: after_claim}}} =
               dispatch(agent_uri, :get_tree, %{}, admin_ctx)

      assert after_claim["n2"].owner == URI.to_string(alice.caller)

      # bob holds the cap (authz passes) but is NOT the owner → the HANDLER's
      # owner_or_admin? gate denies with a bare :forbidden (not a cap rejection).
      assert {:error, :forbidden} =
               dispatch(agent_uri, :rename_node, %{id: "n2", title: "X"}, bob),
             "a non-owner non-admin holding the cap must be denied by the per-node owner gate"

      # Positive control: bob CAN claim a different unclaimed node — proves bob's
      # cap authorizes kanban actions, so the rename denial is OWNERSHIP, not authz.
      assert {:ok, %{}} = dispatch(agent_uri, :claim_node, %{id: "n1"}, bob)
    end)
  end

  # Re-homed from the deleted K5 `roundtrip_test.exs` (was a `resource://` Kanban
  # Kind e2e): the markmap export/import ACTION roundtrip via DISPATCH on the
  # kanban-manager `Entity.Agent` host. `markmap_test` covers the pure Markmap
  # render/parse; `behavior/kanban_test` covers `handle_import_markmap` authz;
  # neither covers the full export-edit-import-get_tree loop through dispatch —
  # so it lives here on the as-role path (parity audit: enumerate FROM the thing
  # being retired). Proves ezagent (the agent's `:kanban` slice) is the source of
  # truth and the markmap file is a bidirectional projection.
  @tag :integration
  test "markmap roundtrip via dispatch on the kanban-manager agent: export → edit → import → get_tree reflects",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kanban-mgr-mm-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
                 admin_ctx
               )

      assert agent_uri == Ezagent.URI.agent(ws_name, name)

      # build the tree on the agent's :kanban slice (source of truth)
      assert {:ok, %{id: "n1"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      assert {:ok, %{id: "n2"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "n1", title: "子1"}, admin_ctx)

      assert {:ok, %{id: "n3"}} =
               dispatch(agent_uri, :add_node, %{parent_id: "n1", title: "子2"}, admin_ctx)

      # export → markmap markdown
      assert {:ok, %{markdown: md}} = dispatch(agent_uri, :export_markmap, %{}, admin_ctx)
      assert md == "# 根\n## 子1\n## 子2\n"

      # simulate a human editing the file: add a node, overwrite
      edited = md <> "## 子3\n"

      # import the edited markdown back (admin-gated; admin dispatches)
      assert {:ok, %{count: 4}} =
               dispatch(agent_uri, :import_markmap, %{markdown: edited}, admin_ctx)

      # the agent's tree reflects the human's edit (bidirectional)
      assert {:ok, %{tree: %{nodes: nodes}}} = dispatch(agent_uri, :get_tree, %{}, admin_ctx)
      titles = nodes |> Map.values() |> Enum.map(& &1.title)
      assert "子3" in titles
      assert map_size(nodes) == 4
    end)
  end

  defp dispatch(agent_uri, action, args, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.with_action(agent_uri, :kanban, action)
    caps = signed_dispatch_caps(target, caller, caps)

    cmd =
      Ezagent.Cmd.new(
        target,
        action,
        args,
        %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
      )

    Ezagent.Router.dispatch(cmd)
  end

  defp signed_dispatch_caps(target, caller, caps) do
    if Ezagent.Identity.admin?(caller) do
      MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller)])
    else
      caps
      |> Enum.map(&Ezagent.Test.CapHelper.signed_cap!(target, caller, &1))
      |> MapSet.new()
    end
  end

  defp restore_routing_tables(nil), do: Application.delete_env(:ezagent_core, :routing_tables)

  defp restore_routing_tables(original),
    do: Application.put_env(:ezagent_core, :routing_tables, original)

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
