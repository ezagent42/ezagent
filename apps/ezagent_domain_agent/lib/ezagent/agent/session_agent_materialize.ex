defmodule Ezagent.Agent.SessionAgentMaterialize do
  @moduledoc """
  Phase 3 ③ T7c — the GENERIC mechanism for **materializing a default role-agent
  PER-SESSION**: turn a T7a-seeded `cc × <role>` system template into a LIVE,
  session/workspace-scoped `cc` agent, then LAND its recipe caps on that live
  per-session URI.

  This is the live counterpart to `Ezagent.Agent.DefaultAgentSeed` (which only
  WRITES the template at boot). It composes existing domain.agent primitives and
  introduces NO new mechanism — exactly the `Ezagent.Entity.Session.Orchestrator`
  play (`ensure_orchestrator/3`), generalized off the orchestrator's
  hardcoded `cc-orchestrator` role:

    1. **session/workspace-scoped URI** — `planned_agent_uri/3` builds
       `entity://<workspace>/agent/<role>-<session-disc>` (mirrors
       `Orchestrator.build_orchestrator_uri_for_create/2`'s
       `cc_orchestrator-<session-disc>` shape). Identity + lifecycle are
       per-session, NOT a system singleton (user decision 2026-06-29).
    2. **credentials reuse the orchestrator path** — `spawn_from_template_content/5`
       is called with the SESSION OWNER as `spawned_by_uri` + `opts[:caller]` +
       `opts[:caps]` (`Identity.list_caps_for(owner)`) + `opts[:source_template_uri]`,
       byte-for-byte the `Ezagent.Entity.Session.orchestrator_spawn_template_opts/2`
       shape. The credential cascade keys off `spawned_by_uri` as the owner
       (`TemplateSpawn.Cascade` `owner_uri: spawned_by_uri`), so the owner's
       default `claude` credentials are materialized into the per-agent
       `config_dir` the same way the orchestrator's are.
    3. **grant landing** — once the agent is live (the Kind is up +
       `ReadyGate`-ready inside `spawn_from_template_content/5`), the recipe's
       least-priv caps are granted onto the per-session URI via the SANCTIONED
       `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps.grant_recipe_caps/3` entry (p7:
       grant from the mix-task chokepoint — this engine NEVER mints a cap grant
       directly; it delegates to that sanctioned entry, which owns the actual
       `Identity` grant call). This is the "deferred grant LANDS once live" step the
       T7b surface-notes flagged (`:no_such_actor` was only because the target
       wasn't live yet).

  ## Tier / scope

  Lives in `ezagent_domain_agent` (NOT forked per-plugin) for the same FF-1
  anti-fork reason `DefaultAgentSeed` does: the pm (kanban) + dev-together seeds
  would otherwise byte-duplicate this composition. It touches NO `domain_session`
  / core spawn semantics — it only CALLS `Ezagent.Entity.Agent.spawn_from_template_content/5`
  (the existing primitive) + the existing grant mix-task. Callers fill the spec
  with their role's content + recipe. This engine is DELIBERATELY generic and
  carries NO product-recipe knowledge: a role-owning plugin's seed passes a
  `cap_instance_overrides` (e.g. a kanban board-scoping seed for pm-coordinator),
  and the generic `materialize_by_role/4` resolves the recipe BY NAME through
  `RecipeRegistry` (zero compile dependency on any plugin's recipe data). The
  role data itself is owned by whoever registers the role via `roles/0` (a
  role-owning plugin for product agents; user config for user-defined agents) —
  this module does not hardcode or reference any specific role catalog.

  ## T7c = MECHANISM only

  The LIVE `claude` brain reply (a real sidecar answering chat) is the T7b
  agent-browser proof — NOT this slice. This module materializes the per-session
  agent + lands caps; whether the brain then behaves is proven separately.
  """

  alias Ezagent.Agent.{RecipeMaterializer, RecipeRegistry}
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  # A generic placeholder description for a by-role materialize's AgentTemplate
  # content (cosmetic — `AgentTemplate` content `description`). The role-owning
  # plugin's seed carries a richer one; the by-role path is reached WITHOUT a
  # compile dep on that plugin (recipe via `RecipeRegistry`, cwd via
  # `DefaultAgentSeed.default_project_cwd/1`), so it supplies its own.
  @by_role_description "default role-agent materialized per-session via the generic by-role path"

  @typedoc """
  The per-session materialize spec (see the moduledoc).

  `cap_instance_overrides` (OPTIONAL, T7g Part A) is a
  `%{behavior_module => target_uri}` map scoping the listed behaviors' recipe caps
  to a cross-instance target (e.g. pm's kanban caps on the BOARD agent) instead of
  the grantee's own instance; absent ⇒ every cap self-scoped.
  """
  @type spec :: %{
          required(:role) => String.t(),
          required(:session_uri) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:owner_uri) => URI.t(),
          required(:template_content) => map(),
          required(:recipe) => map(),
          required(:telemetry_prefix) => [atom()],
          optional(:cap_instance_overrides) => %{optional(module()) => URI.t()}
        }

  @doc """
  Materialize the `role`'s per-session agent from `spec` and land its recipe caps.

  Returns `{:ok, agent_uri, :created | :already_present}` — `agent_uri` is the
  session/workspace-scoped URI the agent went live at, `:created` ⇔ this call
  freshly spawned it, `:already_present` ⇔ it was already live (idempotent
  re-materialize). Returns `{:error, reason}` if the spawn OR the grant landing
  fails (no half-state surfaced as success — the spawn primitive self-cleans a
  failed fresh spawn).

  The grant runs AFTER the spawn so it lands on a LIVE identity slice (the T7b
  `:no_such_actor` deferral is closed by materializing first).
  """
  @spec materialize(spec()) :: {:ok, URI.t(), :created | :already_present} | {:error, term()}
  def materialize(
        %{
          role: role,
          session_uri: %URI{} = session_uri,
          workspace_uri: %URI{} = workspace_uri,
          owner_uri: %URI{} = owner_uri,
          template_content: template_content,
          recipe: recipe,
          telemetry_prefix: telemetry_prefix
        } = spec
      )
      when is_binary(role) and is_map(template_content) and is_map(recipe) and
             is_list(telemetry_prefix) do
    agent_uri = planned_agent_uri(role, session_uri, workspace_uri)
    template_uri = Ezagent.URI.template(:system, :agent, role)

    # T7g Part A — optional cap-instance overrides (`%{behavior_module => target_uri}`)
    # so a role's cross-instance caps (e.g. pm's kanban caps on the BOARD agent) are
    # board-scoped, not self-scoped. Absent ⇒ `%{}` ⇒ every cap self-scoped (the
    # dev-together / generic by-role path keeps its prior behavior unchanged).
    cap_instance_overrides = Map.get(spec, :cap_instance_overrides, %{})

    with {:ok, outcome} <-
           RecipeMaterializer.spawn_from_template_content(
             template_content,
             agent_uri,
             owner_uri,
             workspace_uri,
             caller: owner_uri,
             caps: Ezagent.Identity.list_caps_for(owner_uri),
             source_template_uri: template_uri
           ),
         :ok <-
           GrantRecipeCaps.grant_recipe_caps(
             agent_uri,
             recipe,
             telemetry_prefix,
             cap_instance_overrides
           ) do
      {:ok, agent_uri, outcome}
    end
  end

  @doc """
  Materialize `role`'s per-session agent GENERICALLY — by role NAME, with NO
  compile dep on the role-owning plugin.

  This is the seam a plugin uses to materialize a default role-agent by NAME
  without a compile dep on its definition (e.g. kanban's `Connectors.bind_session`
  materializing a `dev-together` role, whose recipe data is registered at boot by
  whoever owns the role via `roles/0` — a role-owning plugin, or user config; this
  engine never references a specific role catalog). It composes the same
  `materialize/1` spec, but resolves the two pieces at RUNTIME:

    * `recipe` — `Ezagent.Agent.RecipeRegistry.lookup(role)` (a `%Recipe{}`,
      boot-seeded from the owning plugin's `roles/0`; its `requested_caps` feed
      `GrantRecipeCaps`). An ABSENT role (the owning plugin isn't in this build,
      or hasn't booted) returns `{:error, {:role_not_registered, role}}` —
      fail-closed, never a silent spawn of a cap-less agent.
    * `template_content` — `DefaultAgentSeed.template_content/3` whose `project_cwd`
      is taken from the recipe's `config["project_cwd"]`/`:project_cwd` (atom/string
      tolerant, the persisted-content round-trip范式 — see `recipe_project_cwd/2`),
      falling back to the generic `default_project_cwd/1` (the SAME `~/.ezagent/<role>`
      the owning plugin's seed defaults to). This closes the CLI-reachability config
      seam (T7e): a recipe can DECLARE its agent's `project_cwd` (e.g. the umbrella
      root, so the agent's `mix ezagent kanban.*` resolves) and the generic by-role
      path honors it WITHOUT a compile dep on the role-owning plugin. The default
      (sandbox `~/.ezagent/<role>`) is UNCHANGED — only made overridable.

  Returns the same `{:ok, agent_uri, :created | :already_present}` /
  `{:error, reason}` contract as `materialize/1`.
  """
  @spec materialize_by_role(String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, URI.t(), :created | :already_present} | {:error, term()}
  def materialize_by_role(role, %URI{} = session_uri, %URI{} = workspace_uri, %URI{} = owner_uri)
      when is_binary(role) do
    materialize_by_role(role, "cc", session_uri, workspace_uri, owner_uri)
  end

  @spec materialize_by_role(String.t(), String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, URI.t(), :created | :already_present} | {:error, term()}
  @doc """
  Materialize `role` with an explicit agent flavor.

  The legacy arity defaults to `"cc"`. Socialware manifests call this arity so
  `flavor` stays a manifest axis while the role recipe remains flavor-free.
  """
  def materialize_by_role(
        role,
        flavor,
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri
      )
      when is_binary(role) and is_binary(flavor) do
    with {:ok, spec} <- by_role_spec(role, flavor, session_uri, workspace_uri, owner_uri) do
      materialize(spec)
    end
  end

  @doc """
  Build the `materialize/1` spec for `role` GENERICALLY (recipe via
  `RecipeRegistry`, content via `DefaultAgentSeed`), WITHOUT spawning — the
  dispatch-free, registry-only half of `materialize_by_role/4`, exposed so the
  composition (recipe resolution + generic cwd + fail-closed on an unregistered
  role) is testable apart from the live `cc` spawn.

  `{:error, {:role_not_registered, role}}` when no recipe is registered (the
  owning plugin isn't built / hasn't booted) — fail-closed, never a cap-less spawn.
  """
  @spec by_role_spec(String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, spec()} | {:error, {:role_not_registered, String.t()}}
  def by_role_spec(role, %URI{} = session_uri, %URI{} = workspace_uri, %URI{} = owner_uri)
      when is_binary(role) do
    by_role_spec(role, "cc", session_uri, workspace_uri, owner_uri)
  end

  @spec by_role_spec(String.t(), String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, spec()} | {:error, term()}
  @doc """
  Build the by-role materialization spec with an explicit agent flavor.

  This is the dispatch-free half of flavor-aware materialization: it resolves
  the role recipe, asks `RecipeMaterializer` for the flavor-specific template
  content, and leaves spawning/grants to `materialize/1`.
  """
  def by_role_spec(
        role,
        flavor,
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri
      )
      when is_binary(role) and is_binary(flavor) do
    case RecipeRegistry.lookup(role) do
      {:ok, recipe} ->
        agent_uri = planned_agent_uri(role, session_uri, workspace_uri)

        with {:ok, content} <-
               RecipeMaterializer.template_content(recipe, %{
                 recipe_name: role,
                 role_name: role,
                 flavor: flavor,
                 agent_uri: agent_uri,
                 description: @by_role_description
               }) do
          {:ok,
           %{
             role: role,
             session_uri: session_uri,
             workspace_uri: workspace_uri,
             owner_uri: owner_uri,
             template_content: content,
             recipe: recipe,
             telemetry_prefix: [:ezagent, :agent, :materialize_by_role]
           }}
        end

      :error ->
        {:error, {:role_not_registered, role}}
    end
  end

  @doc """
  A fresh, ROLE-AGNOSTIC agent URI: `entity://<workspace>/agent/<uuid>` (P2).

  The materialized agent's identity carries NO role or session segment (Gate B):
  role_name lives only on the (entity × session) membership edge, and recipe
  provenance is a stored attribute — never in the URI. `role` and `session_uri`
  are retained in the signature only as the recipe-by-name + owning-context
  inputs for the caller; they do NOT shape the URI. Mirrors the live socialware
  materializer `DefinitionAgents.planned_agent_uri/1` (fresh UUID instance URI).
  """
  @spec planned_agent_uri(String.t(), URI.t(), URI.t()) :: URI.t()
  def planned_agent_uri(role, %URI{} = _session_uri, %URI{} = workspace_uri)
      when is_binary(role) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
  end
end
