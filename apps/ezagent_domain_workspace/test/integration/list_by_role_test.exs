defmodule Ezagent.Integration.ListByRoleTest do
  @moduledoc """
  RF-7 acceptance — list-by-role read model (`Ezagent.AgentRecipeResolver`).

  Proves the two RF-7 requirements:

    1. **list-by-role returns exactly the role-R agents** — create N agents with
       role R (+ agents with a DIFFERENT role + an agent with NO role) →
       `list_by_recipe(R)` returns exactly the N role-R URIs, none of the others;

    2. **PERSISTED / cold-restart enumeration** — a role agent STILL appears in
       `list_by_recipe(R)` after the volatile ETS fast path is cleared AND the live
       Kind is terminated (kanban-spec §8: a DORMANT passive role agent — e.g.
       the kanban-manager — must survive a BEAM restart, else the board
       vanishes). The list is sourced from the persisted `:sandbox` snapshot
       slice, NOT the live `KindRegistry`.

  Built on RF-5a's create-time role-tagging path (role × native direct-spawn).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Workspace.RoleTestBehavior

  alias Ezagent.{
    AgentFlavorRegistry,
    AgentRecipeAttributes,
    AgentRecipeResolver,
    Agent.RecipeRegistry,
    UriQuery
  }

  @flavor "rf7-native"
  @role_a "rf7-role-a"
  @role_b "rf7-role-b"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "rf7-#{System.unique_integer([:positive])}"
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

    # role A is passive (kanban-manager class — proves a DORMANT passive role
    # still enumerates); role B is a plain principal role.
    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: @role_a,
        passive: true,
        behaviors: [RoleTestBehavior],
        requested_caps: [%{behavior: RoleTestBehavior, action: :ping}]
      })

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: @role_b,
        passive: false,
        behaviors: [RoleTestBehavior],
        requested_caps: [%{behavior: RoleTestBehavior, action: :ping}]
      })

    RecipeRegistry.flush_cache()

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

  defp create_role_agent(ws_name, workspace_uri, admin_ctx, role) do
    name = "rf7-agent-#{System.unique_integer([:positive])}"
    expected_uri = Ezagent.URI.agent(ws_name, name)

    args = %{flavor: @flavor, name: name, cwd: "", with_pty: false}
    args = if role, do: Map.put(args, :role, role), else: args

    {:ok, %{agent_uri: agent_uri}} = Workspace.create_agent(workspace_uri, args, admin_ctx)
    assert agent_uri == expected_uri
    agent_uri
  end

  @tag :integration
  test "list_by_recipe(R) returns EXACTLY the role-R agents (not other-role / roleless)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      # 3 with role A, 2 with role B, 1 with NO role.
      a1 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_a)
      a2 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_a)
      a3 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_a)
      b1 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_b)
      b2 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_b)
      _none = create_role_agent(ws_name, workspace_uri, admin_ctx, nil)

      # The per-URI `:role` resolver agrees (ETS fast path).
      assert {:ok, @role_a} = UriQuery.resolve(:recipe, a1)
      assert {:ok, @role_b} = UriQuery.resolve(:recipe, b1)

      role_a = AgentRecipeResolver.list_by_recipe(@role_a, workspace_uri) |> uri_set()
      role_b = AgentRecipeResolver.list_by_recipe(@role_b, workspace_uri) |> uri_set()

      assert role_a == uri_set([a1, a2, a3]),
             "list_by_recipe(role_a) must be EXACTLY the 3 role-A agents; got #{inspect(MapSet.to_list(role_a))}"

      assert role_b == uri_set([b1, b2]),
             "list_by_recipe(role_b) must be EXACTLY the 2 role-B agents"

      # The roleless agent is in NEITHER list.
      assert AgentRecipeResolver.list_by_recipe("no-such-role", workspace_uri) == []
    end)
  end

  @tag :integration
  test "list_by_recipe is WORKSPACE-SCOPED — never leaks another tenant's role agents (K4)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      # A role-A agent in workspace 1.
      a_ws1 = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_a)

      # A SECOND workspace with its OWN role-A agent + the SAME flavor/role
      # registry (registries are global; the agents are per-workspace).
      ws2_name = "rf7b-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws2_name, %{})
      ws2_uri = URI.new!("workspace://#{ws2_name}")
      a_ws2 = create_role_agent(ws2_name, ws2_uri, admin_ctx, @role_a)

      ws1_list = AgentRecipeResolver.list_by_recipe(@role_a, workspace_uri)
      ws2_list = AgentRecipeResolver.list_by_recipe(@role_a, ws2_uri)

      # K4's board for ws1 must see ws1's manager and NOT ws2's (cross-tenant
      # leak + unbounded scan) — and vice versa.
      assert a_ws1 in ws1_list
      refute a_ws2 in ws1_list, "list_by_recipe leaked a DIFFERENT workspace's role agent"

      assert a_ws2 in ws2_list
      refute a_ws1 in ws2_list, "list_by_recipe leaked a DIFFERENT workspace's role agent"
    end)
  end

  @tag :integration
  test "PERSISTED / cold restart — a role agent STILL enumerates after ETS cleared + Kind terminated",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      agent_uri = create_role_agent(ws_name, workspace_uri, admin_ctx, @role_a)

      assert agent_uri in AgentRecipeResolver.list_by_recipe(@role_a, workspace_uri)
      assert {:ok, @role_a} = UriQuery.resolve(:recipe, agent_uri)

      # Simulate a COLD restart: clear the volatile ETS fast path AND terminate
      # the live Kind. The ONLY surviving record of the role is now the persisted
      # `:sandbox` snapshot slice.
      :ok = AgentRecipeAttributes.delete(agent_uri)
      assert :none = AgentRecipeAttributes.fetch(agent_uri)

      _ = Ezagent.Kind.terminate(agent_uri)

      assert wait_until_deregistered(agent_uri),
             "Kind did not deregister after terminate — cannot prove SNAPSHOT-only enumeration"

      # THE RF-7 INVARIANT: with ETS empty and the Kind not spawned, the agent
      # MUST still enumerate by role — recovered from the durable snapshot. A
      # KindRegistry-sourced list returns [] here (the board vanishes).
      listed = AgentRecipeResolver.list_by_recipe(@role_a, workspace_uri)

      assert agent_uri in listed,
             "DORMANT role agent did NOT enumerate after cold restart — list_by_recipe " <>
               "is not snapshot-sourced (the kanban board would vanish on BEAM restart)"

      # The per-URI `:role` resolver also survives (ETS → snapshot fallback).
      assert {:ok, @role_a} = UriQuery.resolve(:recipe, agent_uri),
             "the :role resolver failed open across a cold restart (no snapshot fallback)"
    end)
  end

  defp uri_set(uris), do: uris |> Enum.map(&URI.to_string/1) |> MapSet.new()

  defp wait_until_deregistered(uri, attempts \\ 50)
  defp wait_until_deregistered(_uri, 0), do: false

  defp wait_until_deregistered(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        true

      {:ok, _pid} ->
        Process.sleep(10)
        wait_until_deregistered(uri, attempts - 1)
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
