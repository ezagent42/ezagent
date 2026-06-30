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
  with their role's content + recipe: the kanban board-scoping seed
  (`EzagentPluginKanban.PmCoordinatorSeed.materialize/4`, with a
  `cap_instance_overrides`) for pm, and the generic `materialize_by_role/4`
  (recipe via `RecipeRegistry`) for dev-together. The role data + boot template-seed
  for both live in `Ezagent.Agent.DefaultRecipes` / `DefaultRecipeSeed`.

  ## T7c = MECHANISM only

  The LIVE `claude` brain reply (a real sidecar answering chat) is the T7b
  agent-browser proof — NOT this slice. This module materializes the per-session
  agent + lands caps; whether the brain then behaves is proven separately.
  """

  alias Ezagent.Agent.{DefaultAgentSeed, RecipeRegistry}
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
           spawn_session_agent(
             template_content,
             agent_uri,
             owner_uri,
             workspace_uri,
             template_uri
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
  materializing the `dev-together` role, whose data lives in
  `Ezagent.Agent.DefaultRecipes` and is boot-seeded by `DefaultRecipeSeed`). It
  composes the same `materialize/1` spec, but resolves the two pieces at RUNTIME:

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
    with {:ok, spec} <- by_role_spec(role, session_uri, workspace_uri, owner_uri) do
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
    case RecipeRegistry.lookup(role) do
      {:ok, recipe} ->
        {:ok,
         %{
           role: role,
           session_uri: session_uri,
           workspace_uri: workspace_uri,
           owner_uri: owner_uri,
           template_content:
             DefaultAgentSeed.template_content(
               role,
               @by_role_description,
               recipe_project_cwd(recipe, role)
             ),
           recipe: recipe,
           telemetry_prefix: [:ezagent, :agent, :materialize_by_role]
         }}

      :error ->
        {:error, {:role_not_registered, role}}
    end
  end

  @doc """
  The session/workspace-scoped per-session agent URI for `role`
  (`entity://<workspace>/agent/<role>-<session-disc>`).

  Mirrors `Ezagent.Entity.Session.Orchestrator.planned_orchestrator_uri/2`'s
  shape (`cc_orchestrator-<session-disc>`), generalized over `role`. The
  discriminator is the session URI's `name` segment, so two kanban-flow sessions
  in the same workspace get distinct per-session agents.
  """
  @spec planned_agent_uri(String.t(), URI.t(), URI.t()) :: URI.t()
  def planned_agent_uri(role, %URI{} = session_uri, %URI{} = workspace_uri)
      when is_binary(role) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    Ezagent.URI.agent(workspace_name, "#{role}-#{session_discriminator(session_uri)}")
  end

  # The per-agent `project_cwd` a by-role recipe DECLARES, else the generic
  # sandbox default. A recipe's `config` is opaque layer-2 business data (the
  # owning Behavior reads its own keys, atom/string-key tolerant) — `project_cwd`
  # is one such declared key (T7e: the CLI-reachability config seam, e.g. the
  # umbrella root so the agent's `mix ezagent` resolves). Read atom-then-string
  # (the persisted-content JSON round-trip范式, mirroring `Recipe`'s field reader +
  # kanban `Shared.config_atom`); a non-string / absent value falls back to the
  # UNCHANGED sandbox default. NOTE the pm board-scoping seed carries its own
  # `*_cwd` Application-config override (via `DefaultRecipes`) on the
  # `materialize/1` path; this generic by-role path reads the value DECLARED in
  # the registered recipe (`config[:project_cwd]`) instead.
  defp recipe_project_cwd(recipe, role) do
    case config_get(Map.get(recipe, :config) || %{}, :project_cwd) do
      cwd when is_binary(cwd) -> cwd
      _ -> DefaultAgentSeed.default_project_cwd(role)
    end
  end

  # Read a recipe-config field by atom key, falling back to its string key
  # (persisted JSON/snapshot content). Mirrors `Ezagent.Agent.Recipe`'s reader.
  defp config_get(config, key) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  defp config_get(_config, _key), do: nil

  # spawn_from_template_content/5 with the EXACT orchestrator credential-supply
  # opts: the session owner is `spawned_by_uri` (the cascade's `owner_uri`) AND
  # `caller` + `caps`, with `source_template_uri` so the default credential
  # cascade can resolve the owner's `claude` creds into the per-agent config_dir.
  defp spawn_session_agent(
         content,
         %URI{} = agent_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri,
         %URI{} = template_uri
       ) do
    opts = [
      caller: owner_uri,
      caps: Ezagent.Identity.list_caps_for(owner_uri),
      source_template_uri: template_uri
    ]

    case Ezagent.Entity.Agent.spawn_from_template_content(
           content,
           agent_uri,
           owner_uri,
           workspace_uri,
           opts
         ) do
      {:ok, %{fresh?: true}} -> {:ok, :created}
      {:ok, %{fresh?: false}} -> {:ok, :already_present}
      {:ok, %{}} -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  defp session_discriminator(%URI{} = session_uri) do
    case Ezagent.URI.name(session_uri) do
      {:ok, name} -> name
      :error -> session_uri.host || "session"
    end
  end
end
