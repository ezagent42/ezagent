defmodule EzagentCore.Architecture.AgentSessionRoleGateTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Gate B (socialware role-slot P2): an agent must NOT carry a global session
  role. A materialized agent is role-agnostic — its `role_name` lives ONLY on
  the (entity × session) membership edge (`Members` meta facet), so the SAME
  agent can be `advisor` in session A and `reviewer` in session B. Routing
  `{:role, name}` resolves against the session's current edges, never against a
  value baked onto the agent (URI segment / attribute / sandbox slice).

  ## What this forbids (the agent-level SESSION-role bake)

  A source-line scan over the agent-materialization + role-read modules for the
  role-named agent-level constructs that P2 retires:

    * `planned_agent_uri` baking `<role>-<disc>` into the agent URI,
    * an `Ezagent.AgentRoleAttributes` store keyed agent-URI → role,
    * an `Ezagent.AgentRoleResolver` agent→role read model,
    * a `:role` sandbox-slice field written at create,
    * `Recipe.Compose` emitting `role:` onto materialized content,
    * a `RoleStep` durable `:role` marker,
    * a `:role` UriQuery resolver.

  ## Carveout — recipe/build provenance is ALLOWED (spec §4.4 / O-1)

  Recording WHICH RECIPE an agent was built from (build provenance) is a
  legitimate stored attribute, mirroring flavor-as-stored-attribute. In this
  codebase "role" and "recipe name" were conflated; the P2 migration
  DISAMBIGUATES them: the provenance value stays on the agent under a `recipe`
  name (`Ezagent.AgentRecipeAttributes`, sandbox slice `:recipe`,
  `AgentRecipeResolver.list_by_recipe/2`, `:recipe` UriQuery), and only the
  varying SESSION role moves to the edge. So this gate flags the `role`-NAMED
  agent-level symbols; the fix is to rename provenance to `recipe` and let the
  session role live edge-only. It does NOT flag the `role_name` membership facet
  (that IS the sanctioned edge home) nor the `{:role, name}` routing receiver
  (which resolves against edges).

  Scope: a static source gate. Like Gate A it starts RED (it enumerates today's
  agent-level role bakes) and is driven to GREEN (`@allowlist` empty) as each
  consumer is repointed to the edge or renamed to recipe-provenance.
  """

  @repo_root Path.expand("../../../..", __DIR__)

  @scanned_files [
    "apps/ezagent_domain_agent/lib/ezagent/agent/session_agent_materialize.ex",
    "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex",
    "apps/ezagent_domain_agent/lib/ezagent/agent_recipe_attributes.ex",
    "apps/ezagent_domain_agent/lib/ezagent/agent_recipe_resolver.ex",
    "apps/ezagent_core/lib/ezagent/behavior/sandbox.ex",
    "apps/ezagent_core/lib/ezagent/agent/recipe/compose.ex",
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex",
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/uri_query_resolvers.ex",
    "apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/shared.ex",
    "apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex"
  ]

  # The agent-level SESSION-role bake patterns. Each is a durable write or read
  # of a role NAME onto/off an AGENT (not the session edge). Driven to empty by
  # the P2 migration (rename provenance → recipe; session role → edge).
  @forbidden_source_patterns [
    # 1. role baked into the agent URI (planned_agent_uri role-disc segment)
    {:role_baked_agent_uri, ~r/"#\{role\}-#\{session_discriminator/},
    # 2. the agent-URI → role attribute store (module + writes + reads)
    {:agent_role_attributes_module, ~r/defmodule\s+Ezagent\.AgentRoleAttributes/},
    {:agent_role_attributes_use, ~r/Ezagent\.AgentRoleAttributes\.(put|fetch)\b/},
    # 3. the agent → role read model (module + entrypoints)
    {:agent_role_resolver_module, ~r/defmodule\s+Ezagent\.AgentRoleResolver/},
    {:agent_role_resolver_list_by_role, ~r/AgentRoleResolver\.list_by_role\b/},
    {:agent_role_resolver_snapshot, ~r/AgentRoleResolver\.role_from_durable_snapshot\b/},
    # 4. the `:role` sandbox-slice field written at create
    {:sandbox_role_slice, ~r/role:\s*validate_role\(/},
    {:sandbox_validate_role_def, ~r/defp\s+validate_role\(/},
    # 5. Recipe.Compose emitting `role:` onto materialized content
    {:compose_emits_role, ~r/role:\s*role\.name/},
    # 6. RoleStep durable `:role` marker
    {:role_step_marker_fn, ~r/def\s+grant_role_marker/},
    {:role_step_marker_put, ~r/maybe_put\(:role,/},
    # 7. `:role` UriQuery resolver (per-agent role query)
    {:role_uri_query_register, ~r/register\(:role,/},
    {:role_uri_query_resolver, ~r/def\s+resolve_role\(/}
  ]

  # Allowlist of (file, reason) pairs still permitted — DRIVEN TO EMPTY. Any
  # entry here is a known-remaining agent-level role bake awaiting migration.
  @allowlist []

  test "no agent-level session-role bake outside the membership edge" do
    offenders =
      @scanned_files
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {rel, _line, reason} -> {rel, reason} in @allowlist end)

    assert offenders == [],
           """
           Agent-level SESSION-role bake still present. P2 requires role_name to
           live ONLY on the (entity × session) membership edge; recipe/build
           provenance may stay on the agent but under a `recipe` name (see the
           moduledoc carveout). Rename the provenance readers to recipe and move
           any session role to the edge.

           Offenders:
           #{format(offenders)}
           """
  end

  test "scanner has teeth: a re-introduced agent-level role bake trips it" do
    planted = """
    defmodule Ezagent.AgentRoleAttributes do
      def put(agent_uri, role_name), do: :ets.insert(:agent_role, {agent_uri, role_name})
    end

    defp build_uri(role, session, ws) do
      Ezagent.URI.agent(ws, "\#{role}-\#{session_discriminator(session)}")
    end

    defp slice(args), do: %{role: validate_role(Map.get(args, :role))}

    def register do
      Ezagent.UriQuery.register(:role, &resolve_role/1)
    end
    """

    hits =
      @forbidden_source_patterns
      |> Enum.filter(fn {_reason, pattern} -> planted =~ pattern end)
      |> Enum.map(fn {reason, _pattern} -> reason end)

    assert :agent_role_attributes_module in hits
    assert :role_baked_agent_uri in hits
    assert :sandbox_role_slice in hits
    assert :role_uri_query_register in hits
  end

  defp scan_file(rel) do
    source =
      @repo_root
      |> Path.join(rel)
      |> File.read!()

    @forbidden_source_patterns
    |> Enum.flat_map(fn {reason, pattern} ->
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_no} -> line =~ pattern end)
      |> Enum.map(fn {_line, line_no} -> {rel, line_no, reason} end)
    end)
  end

  defp format([]), do: "  (none)"

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, line, reason} -> "  #{rel}:#{line} #{reason}" end)
    |> Enum.join("\n")
  end
end
