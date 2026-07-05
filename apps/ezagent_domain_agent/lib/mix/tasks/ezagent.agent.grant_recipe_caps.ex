defmodule Mix.Tasks.Ezagent.Agent.GrantRecipeCaps do
  @shortdoc "Grant a role recipe's least-priv caps to a (materialized) default agent"
  @moduledoc """
  Phase 3 ③ T7a/T7b — the SANCTIONED operator/materialize entry point that grants
  a role recipe's `requested_caps` to a default-agent entity URI under admin
  authority (least-priv).

  ## Why this is a mix task (p7)

  The grant ENGINE used to live inside `Ezagent.Agent.DefaultAgentSeed`, called
  from each plugin's `after_boot/0`. That made `Identity.grant_cap/3` fire from a
  **boot-time, non-deliberate** entry — exactly what the
  `cap_check_only_at_chokepoint` p7 probe forbids ("grant only from Identity
  Behavior / admin LV / **mix tasks**"). The grant is now a deliberate
  operator/materialize action: `DefaultAgentSeed.seed/1` only writes the template
  at boot, and this mix task lands the caps once a target agent exists (T7b live
  materialize, or an operator running it directly).

  It does NOT prejudge the default-agent identity model (system-singleton vs
  per-session — see `surface-notes-for-user.md` §零): the grant target URI is
  passed in (`--agent-uri`, defaulting to the T7a system-singleton
  `entity://system/agent/<role>`), so a future materialize decision supplies the
  real instance URI without touching this engine.

  ## Usage

      mix ezagent.agent.grant_recipe_caps <role> [--agent-uri <entity-uri>]

      # grant the pm-coordinator recipe to the system-singleton default agent
      mix ezagent.agent.grant_recipe_caps pm-coordinator

      # grant to a specific materialized instance URI (T7b)
      mix ezagent.agent.grant_recipe_caps dev-together \\
          --agent-uri entity://workspace-a/agent/dev-together-1

  ## Guarantees (unchanged from the relocated engine)

  - **fail-closed, no partial** — every requested cap's behavior (an atom OR a
    recipe STRING name) resolves to a LOADED module FIRST; if ANY is unloaded the
    task fails LOUD (`{:error, {:behavior_not_loaded, _}}` + telemetry), granting
    nothing — never a silently-dead cap.
  - **least-priv** — every cap is granted under the genesis admin entity
    (`granted_by: admin`), scoped to the agent's own instance + workspace.
  """
  use Mix.Task

  require Logger

  alias Ezagent.Agent.{DefaultAgentSeed, RecipeRegistry}

  @operator_telemetry_prefix [:ezagent, :agent, :grant_recipe_caps]

  # Role-owning plugins booted best-effort so their `roles/0` recipes register
  # into `RecipeRegistry` for the lookup below. Atom-only — a no-op if a plugin
  # is absent from this build (same pattern as `Mix.Tasks.Ezagent.Agent.Create`).
  #
  # A role resolves here IFF some booted plugin registered it via `roles/0`. This
  # list is a RUNTIME atom set (no compile dep) — kanban owns `kanban-manager` (and
  # the `pm-coordinator` product recipe) via its own `roles/0`, and loads
  # `Ezagent.ActionSet.Kanban` for the cap-resolve loaded-check. Any role NOT
  # registered by a booted plugin fails closed at `lookup_recipe/1`
  # (`{:role_not_registered, role}`) — this task never seeds a role itself.
  @role_plugins [:ezagent_plugin_kanban]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    for plugin <- @role_plugins, do: _ = Application.ensure_all_started(plugin)

    {opts, positional, _} =
      OptionParser.parse(args, strict: [agent_uri: :string])

    case positional do
      [role] when is_binary(role) ->
        do_grant(role, opts)

      _ ->
        Mix.raise("usage: mix ezagent.agent.grant_recipe_caps <role> [--agent-uri <entity-uri>]")
    end
  end

  defp do_grant(role, opts) do
    with {:ok, recipe} <- lookup_recipe(role),
         {:ok, agent_uri} <- target_uri(role, Keyword.get(opts, :agent_uri)),
         :ok <- grant_recipe_caps(agent_uri, recipe, @operator_telemetry_prefix) do
      Mix.shell().info("✓ granted #{role} recipe caps to #{to_string(agent_uri)}")
    else
      :error -> Mix.raise("no role recipe registered for #{inspect(role)}")
      {:error, reason} -> Mix.raise("grant failed: #{inspect(reason)}")
    end
  end

  defp lookup_recipe(role), do: RecipeRegistry.lookup(role)

  defp target_uri(role, nil), do: {:ok, DefaultAgentSeed.agent_uri(role)}

  defp target_uri(_role, uri_str) when is_binary(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    e in ArgumentError -> {:error, {:bad_agent_uri, Exception.message(e)}}
  end

  @doc """
  Grant `recipe`'s `requested_caps` to `agent_uri` under admin authority
  (least-priv), emitting telemetry under `telemetry_prefix`. Resolves each cap's
  behavior (atom OR a recipe STRING name, e.g. github) to a LOADED module FIRST —
  an unloaded behavior fails LOUD (`telemetry_prefix ++ [:behavior_not_loaded]` +
  `{:error, {:behavior_not_loaded, _}}`), never a silently-dead grant — then
  grants fail-closed (`{:error, {:grant_failed, cap, reason}}` on the first
  failure). No partial: if ANY behavior is unresolvable, NOTHING is granted.

  This is the SANCTIONED grant entry (p7 mix-task category); the socialware
  definition-agent materialize (`SessionCreator`'s `definition_agents`) + the
  kanban board-scoping seed (`EzagentPluginKanban.PmCoordinatorSeed`) delegate
  to it.

  ## Cap-instance scoping (Phase 3 ③ T7g Part A)

  By default EVERY granted cap is scoped to `agent_uri`'s OWN instance — the
  least-priv self-scope. But some recipe caps must authorize a dispatch to a
  DIFFERENT instance: pm-coordinator's kanban caps gate the BOARD agent
  (`entity://…/agent/<board>`), not pm itself, so a self-scoped cap is denied at
  the dispatch chokepoint (act3 ★core gap★). The optional `instance_overrides`
  map — `%{behavior_module => target_uri}` — scopes the caps whose RESOLVED
  behavior is a key in the map to that target's instance + workspace (the exact
  shape dispatch step 5.5 derives via `Ezagent.URI.instance/1` +
  `Capability.workspace_of/1`), keeping every other cap self-scoped. This stays
  GENERIC: `domain_agent` knows nothing about kanban — the caller that owns the
  cross-instance target (the kanban seed, which knows both `Behavior.Kanban` and
  the board URI) supplies the map. A board-scoped cap is a CONCRETE-instance
  least-priv grant (NOT a wildcard), so it does not relax the `no_wildcard…` /
  `no_unowned…` invariants AND a dispatch to an UNRELATED board is denied (the
  instance axis no longer matches) — the least-priv 越权 guarantee `instance:
  :any` would forfeit.
  """
  @spec grant_recipe_caps(URI.t(), map(), [atom()], %{optional(module()) => URI.t()}) ::
          :ok | {:error, term()}
  def grant_recipe_caps(%URI{} = agent_uri, recipe, telemetry_prefix, instance_overrides \\ %{})
      when is_map(recipe) and is_list(telemetry_prefix) and is_map(instance_overrides) do
    requested = Map.get(recipe, :requested_caps) || Map.get(recipe, "requested_caps") || []

    with {:ok, resolved} <- resolve_caps(requested, telemetry_prefix) do
      grant_all(agent_uri, resolved, instance_overrides)
    end
  end

  # Resolve every requested cap-template's behavior to a loaded module BEFORE any
  # grant (fail-closed, no partial). Each requested cap is a `%{behavior:, action:}`
  # map (`behavior` an atom OR a string name).
  defp resolve_caps(requested, prefix) when is_list(requested) do
    Enum.reduce_while(requested, {:ok, []}, fn cap_tmpl, {:ok, acc} ->
      case resolve_behavior(Map.get(cap_tmpl, :behavior) || Map.get(cap_tmpl, "behavior"), prefix) do
        {:ok, module} ->
          action = Map.get(cap_tmpl, :action) || Map.get(cap_tmpl, "action")
          {:cont, {:ok, [{module, action} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = err -> err
    end
  end

  defp resolve_behavior(module, prefix) when is_atom(module) and module not in [nil, :any] do
    ensure_behavior_loaded(module, prefix)
  end

  # A recipe STRING name (`"Ezagent.ActionSet.Github"`/…) — resolve to the existing
  # module atom, then LOUD-check it is loaded. A name that resolves to no existing
  # atom (plugin not built) fails loud, NOT a silent drop.
  defp resolve_behavior(name, prefix) when is_binary(name) do
    elixir_name = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name

    try do
      ensure_behavior_loaded(String.to_existing_atom(elixir_name), prefix)
    rescue
      ArgumentError -> behavior_not_loaded(name, prefix)
    end
  end

  defp resolve_behavior(other, _prefix), do: {:error, {:invalid_cap_behavior, other}}

  defp ensure_behavior_loaded(module, prefix) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      behavior_not_loaded(module, prefix)
    end
  end

  # LOUD: the behavior module is not loaded (e.g. the github plugin is absent).
  # Emit telemetry + return an error so the caller fails loud — NEVER grant a cap
  # whose behavior can't resolve (it would silently deny at dispatch).
  defp behavior_not_loaded(behavior, prefix) do
    Logger.error(
      "default-agent grant: recipe cap behavior #{inspect(behavior)} is NOT loaded — " <>
        "refusing to grant a silently-dead cap (a gateway plugin is likely not " <>
        "built into this release)"
    )

    :telemetry.execute(prefix ++ [:behavior_not_loaded], %{count: 1}, %{behavior: behavior})
    {:error, {:behavior_not_loaded, behavior}}
  end

  defp grant_all(%URI{} = agent_uri, resolved, instance_overrides) do
    granter = Ezagent.Entity.User.admin_uri()

    Enum.reduce_while(resolved, :ok, fn {behavior, action}, :ok ->
      # Self-scope by default; a behavior listed in `instance_overrides` is scoped
      # to its cross-instance target instead (T7g Part A). Both axes derive from the
      # SAME helpers dispatch step 5.5 uses (`URI.instance/1` + `workspace_of/1`), so
      # a board-scoped cap matches a board-targeted invocation and ONLY that board.
      scope_uri = Map.get(instance_overrides, behavior, agent_uri)
      instance = Ezagent.URI.instance(scope_uri)
      workspace = Ezagent.Capability.workspace_of(scope_uri)

      cap =
        %Ezagent.Capability{
          Ezagent.Capability.cap(:agent, behavior, action, instance, workspace)
          | granted_by: granter,
            granted_at: DateTime.utc_now()
        }

      case Ezagent.Identity.grant_cap(agent_uri, cap, granter) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_failed, cap, reason}}}
      end
    end)
  end
end
