defmodule Mix.Tasks.Ezagent.Agent.GrantRecipeCaps do
  @shortdoc "Issue and self-store a role recipe's least-priv caps"
  @moduledoc """
  Phase 3 ③ T7a/T7b — the SANCTIONED operator entry point that issues a role
  recipe's `requested_caps` under admin authority, then hands the artifacts to
  a materialized agent for its own non-blocking `absorb_cap` storage.

  ## Why this is a mix task (p7)

  The grant ENGINE used to live inside `Ezagent.Agent.DefaultAgentSeed`, called
  from each plugin's `after_boot/0`. That made `Identity.grant_cap/3` fire from a
  **boot-time, non-deliberate** entry — exactly what the
  `cap_check_only_at_chokepoint` p7 probe forbids ("grant only from Identity
  Behavior / admin LV / **mix tasks**"). The operation is now deliberate:
  `DefaultAgentSeed.seed/1` only writes the template at boot, and this mix task
  performs ISSUE → self-STORE once a target agent exists.

  Socialware definition materialization does not call this task: its self-scoped
  recipe caps are issued into the durable recipe binding before spawn and
  self-stored by `create/1`. This task remains the explicit operator/delegated
  hand-off surface, including `instance_overrides`.

  It does NOT prejudge the default-agent identity model (system-singleton vs
  per-session — see `surface-notes-for-user.md` §零): the grant target URI is
  passed in (`--agent-uri`, defaulting to the T7a system-singleton
  `entity://system/agent/<role>`), so a future materialize decision supplies the
  real instance URI without touching this engine.

  ## Usage

      mix ezagent.agent.grant_recipe_caps <role> [--agent-uri <entity-uri>]

      # issue + self-store the pm-coordinator recipe on the default agent
      mix ezagent.agent.grant_recipe_caps pm-coordinator

      # issue + self-store on a specific materialized instance URI (T7b)
      mix ezagent.agent.grant_recipe_caps dev-together \\
          --agent-uri entity://workspace-a/agent/dev-together-1

  ## Guarantees

  - **fail-closed, no partial** — every requested cap's behavior (an atom OR a
    recipe STRING name) resolves to a LOADED module FIRST; if ANY is unloaded the
    task fails LOUD (`{:error, {:behavior_not_loaded, _}}` + telemetry), storing
    nothing — never a silently-dead cap.
  - **issue-all before store** — complete authorization succeeds for every
    proposal before the first absorb hand-off, preventing partial authorization.
  - **least-priv** — every artifact records the admin issuer in `granted_by` and
    is scoped to the agent's own instance + workspace unless explicitly
    overridden.
  """
  use Mix.Task

  require Logger

  alias Ezagent.Agent.{DefaultAgentSeed, RecipeRegistry}

  @operator_telemetry_prefix [:ezagent, :agent, :grant_recipe_caps]
  @operator_store_timeout_ms 5_000

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
         {:ok, issued_caps} <-
           issue_and_absorb_recipe_caps(
             agent_uri,
             recipe,
             @operator_telemetry_prefix,
             %{}
           ),
         :ok <-
           Ezagent.Identity.CapAbsorbAwait.await_exact(
             agent_uri,
             issued_caps,
             @operator_store_timeout_ms
           ) do
      Mix.shell().info("✓ issued and stored #{role} recipe caps on #{to_string(agent_uri)}")
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
  Issue `recipe`'s `requested_caps` under admin authority and hand the resulting
  artifacts to `agent_uri` for self-storage, emitting telemetry under
  `telemetry_prefix`. Resolves each cap's
  behavior (atom OR a recipe STRING name, e.g. github) to a LOADED module FIRST —
  an unloaded behavior fails LOUD (`telemetry_prefix ++ [:behavior_not_loaded]` +
  `{:error, {:behavior_not_loaded, _}}`), never a silently-dead grant — then
  authorization fail-closed (`{:error, {:grant_failed, cap, reason}}` on the
  first failure). Resolution and ISSUE are both all-or-nothing: every proposal
  is authorized before the first non-blocking absorb hand-off.

  This programmatic helper returns once every cast is accepted or buffered. The
  standalone `run/1` entry additionally waits until the exact issued artifacts
  are observable in the target slice, so its short-lived BEAM never reports
  success while the only copy still lives in an in-memory delivery buffer.

  This is the SANCTIONED explicit operator/delegated hand-off entry (p7 mix-task
  category). Socialware definition agents use the durable binding + `create/1`
  self-store lane instead; callers that own a cross-instance target may supply
  `instance_overrides` here.

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
    case issue_and_absorb_recipe_caps(
           agent_uri,
           recipe,
           telemetry_prefix,
           instance_overrides
         ) do
      {:ok, _issued_caps} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp issue_and_absorb_recipe_caps(agent_uri, recipe, telemetry_prefix, instance_overrides) do
    with {:ok, proposed_caps} <-
           propose_recipe_caps(agent_uri, recipe, telemetry_prefix, instance_overrides),
         {:ok, issued_caps} <- issue_all(agent_uri, proposed_caps),
         stored_caps = canonicalize_issued_caps(issued_caps),
         :ok <- absorb_all(agent_uri, stored_caps) do
      {:ok, stored_caps}
    end
  end

  @doc """
  Resolve every requested recipe-cap template and return concrete proposal
  artifacts without issuing or persisting them.

  Proposal caps are scoped to the canonical agent instance + workspace by
  default. A behavior present in `instance_overrides` is instead scoped to that
  target's canonical instance + workspace. The returned caps intentionally keep
  `Capability.cap/5`'s declarative sentinel provenance; the caller must issue
  them through `Ezagent.Cap.issue/3` before persisting or handing them off.

  Resolution is all-or-nothing: an unresolvable behavior or action returns a
  loud error and no proposal list. Behavior failures retain the legacy
  `:behavior_not_loaded` telemetry event.
  """
  @spec propose_recipe_caps(URI.t(), map(), [atom()], %{optional(module()) => URI.t()}) ::
          {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def propose_recipe_caps(
        %URI{} = agent_uri,
        recipe,
        telemetry_prefix,
        instance_overrides \\ %{}
      )
      when is_map(recipe) and is_list(telemetry_prefix) and is_map(instance_overrides) do
    requested = Map.get(recipe, :requested_caps) || Map.get(recipe, "requested_caps") || []

    with :ok <- validate_instance_overrides(instance_overrides),
         {:ok, resolved} <- resolve_caps(requested, telemetry_prefix) do
      {:ok, Enum.map(resolved, &proposal_cap(agent_uri, &1, instance_overrides))}
    end
  end

  # Resolve every requested cap-template's behavior to a loaded module BEFORE any
  # grant (fail-closed, no partial). Each requested cap is a `%{behavior:, action:}`
  # map (`behavior` an atom OR a string name).
  defp resolve_caps(requested, prefix) when is_list(requested) do
    Enum.reduce_while(requested, {:ok, []}, fn cap_tmpl, {:ok, acc} ->
      behavior = Map.get(cap_tmpl, :behavior) || Map.get(cap_tmpl, "behavior")
      action = Map.get(cap_tmpl, :action) || Map.get(cap_tmpl, "action")

      case resolve_cap_template(behavior, action, prefix) do
        {:ok, resolved} ->
          {:cont, {:ok, [resolved | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = err -> err
    end
  end

  defp resolve_cap_template(behavior, action, prefix) do
    with {:ok, module} <- resolve_behavior(behavior, prefix),
         {:ok, action} <- resolve_action(action) do
      {:ok, {module, action}}
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

  defp resolve_action(action) when is_atom(action) and action not in [nil, true, false],
    do: {:ok, action}

  defp resolve_action(name) when is_binary(name) do
    case String.to_existing_atom(name) do
      action when action not in [nil, true, false] -> {:ok, action}
      _action -> {:error, {:invalid_cap_action, name}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_cap_action, name}}
  end

  defp resolve_action(other), do: {:error, {:invalid_cap_action, other}}

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

  defp proposal_cap(%URI{} = agent_uri, {behavior, action}, instance_overrides) do
    # Presence is the Phase-3 self-scoped-vs-delegated signal. Do not infer it
    # by comparing the resolved URI with the agent: an explicit override may
    # deliberately point at the same canonical instance.
    scope_uri =
      if Map.has_key?(instance_overrides, behavior) do
        Map.fetch!(instance_overrides, behavior)
      else
        agent_uri
      end

    instance = Ezagent.URI.instance(scope_uri)
    workspace = Ezagent.Capability.workspace_of(scope_uri)

    Ezagent.Capability.cap(:agent, behavior, action, instance, workspace)
  end

  defp validate_instance_overrides(instance_overrides) do
    Enum.reduce_while(instance_overrides, :ok, fn
      {_behavior, %URI{}}, :ok ->
        {:cont, :ok}

      {behavior, target}, :ok ->
        {:halt, {:error, {:invalid_instance_override, behavior, target}}}
    end)
  end

  # Two distinct passes are load-bearing: complete every authorization before
  # any grantee receives an artifact. Interleaving issue + absorb would recreate
  # the legacy partial-grant failure mode when a later proposal is denied.
  defp issue_all(%URI{} = agent_uri, proposed_caps) do
    issuer = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.instance(agent_uri)

    proposed_caps
    |> Enum.reduce_while({:ok, []}, fn proposed_cap, {:ok, issued} ->
      case Ezagent.Cap.issue({:admin, issuer}, target, proposed_cap) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | issued]}}
        {:error, reason} -> {:halt, {:error, {:grant_failed, proposed_cap, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _reason} = error -> error
    end
  end

  defp absorb_all(%URI{} = agent_uri, issued_caps) do
    Enum.reduce_while(issued_caps, :ok, fn artifact, :ok ->
      case Ezagent.Identity.absorb_cap(agent_uri, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_failed, artifact, reason}}}
      end
    end)
  end

  # Recipe input may repeat a logical cap. ISSUE still authorizes every
  # proposal, then STORE follows the identity-key semantics of the Identity
  # slice: the last issued artifact for an identity wins. Canonicalizing before
  # absorb avoids redundant audit events and lets the CLI await the exact final
  # structs instead of waiting forever for metadata variants that cannot coexist.
  defp canonicalize_issued_caps(issued_caps) do
    issued_caps
    |> Enum.reverse()
    |> Enum.uniq_by(&Ezagent.Capability.identity_key/1)
    |> Enum.reverse()
  end

end
