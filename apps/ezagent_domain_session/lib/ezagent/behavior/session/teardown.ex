defmodule Ezagent.ActionSet.Session.Teardown do
  @moduledoc false
  #
  # F7 PR-B — the shared participant-resource teardown for the session
  # participant lifecycle (SPEC §3.2 teardown hook + §4 delete cascade).
  #
  # ## The cap-model lever (SPEC §2.2)
  #
  # Each managed worker receives a target-signed concrete Sandbox destroy cap
  # for the session owner at materialization time. Durable lineage remains an
  # independent retirement-provenance gate, so a stolen concrete cap cannot be
  # used to retire a worker outside the owner's creation chain.
  #
  # ## Two callers, two failure modes
  #
  #   * `remove_participant` (the operator/self/orchestrator path) reaps a
  #     single worker in `:strict` mode — a missing owner teardown cap FAILS
  #     CLOSED (`{:error, _}`), the load-bearing authorization (SPEC §7
  #     "Self-leave privilege" / "Destroying a non-spawned participant").
  #   * `cascade_teardown` uses the same explicit authority and provenance
  #     contract. Missing authority leaves the Agent and its durable evidence
  #     intact; it never falls through to an unverified VM destroy.

  require Logger

  alias Ezagent.ActionSet.Session.RoutingPrune

  @typedoc "Call-site intent; both modes fail closed on missing authority."
  @type mode :: :strict | :best_effort

  @doc """
  The UNIFORM per-participant teardown hook (SPEC §3.2). Branches on
  PROVENANCE — NOT on user-vs-agent:

    * a worker SPAWNED INTO this session (carries a `:source_template_uri`
      facet AND `AgentLineage.spawned_in_lineage?(participant, owner)`) →
      reap the worker (config-dir GC + scheduled termination) under the
      owner teardown cap, then `AgentLineage.forget/1`. `{:ok, :worker}`.
    * everything else (invited agent, user, self) → no worker to reap.
      `{:ok, :membership_only}`. NEVER terminates an agent the session did
      not spawn; NEVER destroys a User entity.

  The lineage check (not just the facet) is the SECURITY gate: a member that
  carries a spawn facet but is NOT in the owner's lineage is `membership_only`,
  so a non-spawned participant can never be torn down (SPEC §7).
  """
  @spec teardown_participant_resources(URI.t(), map(), URI.t() | nil, mode()) ::
          {:ok, :worker | :membership_only} | {:error, term()}
  def teardown_participant_resources(%URI{} = participant_uri, participant_meta, owner_uri, mode)
      when is_map(participant_meta) do
    if spawned_worker?(participant_meta, participant_uri, owner_uri) do
      case reap_spawned_worker(participant_uri, owner_uri, mode) do
        {:ok, _report} -> {:ok, :worker}
        {:partial, report} -> {:partial, %{resource: :worker, retirement: report}}
        {:error, _} = err -> err
      end
    else
      {:ok, :membership_only}
    end
  end

  @doc """
  Reap a single spawned worker: dispatch `?action=sandbox.destroy` on the
  worker under the OWNER's target-signed concrete teardown cap,
  which GCs the worker's `config_dir` (`Sandbox.handle_destroy`) + schedules
  Kind termination, THEN `AgentLineage.forget/1` (lineage parity with rollback).

  In `:best_effort` mode, a reap whose owner cap is ABSENT (or any reap error)
  falls back to the VM-internal `Ezagent.Lifecycle.destroy/2` primitive (whose
  `Sandbox.destroy/2` lifecycle hook ALSO GCs the config_dir) — the legitimate
  dead-orchestrator / junk-session safety net (SPEC §2.4 / §4.2). In `:strict`
  mode a reap error is surfaced (fail-closed authorization).

  Already-gone workers are idempotent `:ok`.
  """
  @spec reap_spawned_worker(URI.t(), URI.t() | nil, mode()) ::
          {:ok, map()} | {:partial, map()} | {:error, term()}
  def reap_spawned_worker(%URI{} = worker_uri, owner_uri, mode) do
    context = retirement_context(worker_uri, owner_uri, mode)

    case Ezagent.Domain.Agent.retire_spawned(worker_uri, context) do
      {:ok, report} ->
        _ = Ezagent.AgentLineage.forget(worker_uri)
        {:ok, report}

      {:partial, %{obligation_id: _} = report} ->
        _ = Ezagent.AgentLineage.forget(worker_uri)
        {:partial, report}

      {:error, report} ->
        {:error, {:worker_teardown_failed, report}}
    end
  end

  @doc """
  Cascade teardown for a session being PERMANENTLY deleted (SPEC §4.1). Runs
  from `Session.destroy/2` (the `Ezagent.Lifecycle.destroy/2` hook) while the
  Session Kind is still LIVE so the members slice is readable, so EVERY delete
  path (operator, admin, test, bare `manage.delete`) cascades — never a UI-only
  cascade that orphans (codex PR-A finding).

  Ordered, best-effort + idempotent (`safe/1`-wrapped, log on failure):

    1. tear down every participant (spawned workers reaped via the owner
       durable-lineage cap — dead-orchestrator-safe + `Lifecycle.destroy`
       fallback; invited agents/users membership-only).
    2. reap the orchestrator agent itself (it is in the owner's own lineage,
       so the §2.2 cap reaches it; fallback safe for a dead/ownerless session).
    3. prune ALL session-created routing rows (force) + reload the registry
       (the `rollback.ex delete_session_rule_rows/1` primitive).
    4. stop the per-orchestrator `SessionManager` executor (the pre-PR-B
       `Session.destroy/2` behavior, preserved here).
  """
  @spec cascade_teardown(URI.t(), map()) :: :ok
  def cascade_teardown(%URI{} = session_uri, state) when is_map(state) do
    members = Map.get(state, :members, %{})
    owner_uri = Map.get(state, :owner_uri)
    wc = Ezagent.ActionSet.Session.ConfigActions.template_working_copy(state)

    orchestrator_uri =
      case Ezagent.Session.OrchestratorBinding.decode(Map.get(wc, :orchestrator_uri)) do
        {:ok, binding} -> binding.uri
        _ -> nil
      end

    # 1. tear down every member (skip the owner — never reap the owner).
    Enum.each(members, fn {member_uri, meta} ->
      if member_uri != owner_uri and is_map(meta) do
        safe(fn ->
          teardown_participant_resources(member_uri, meta, owner_uri, :best_effort)
        end)
      end
    end)

    # 2. reap the orchestrator agent + its config_dir (owner's lineage).
    if match?(%URI{}, orchestrator_uri) do
      safe(fn -> reap_spawned_worker(orchestrator_uri, owner_uri, :best_effort) end)
    end

    # 3. prune ALL session-created routing rows.
    safe(fn -> RoutingPrune.prune_all_for_session(session_uri) end)

    # 4. stop the SessionManager executor (preserved pre-PR-B behavior).
    if match?(%URI{}, orchestrator_uri) do
      safe(fn -> Ezagent.Session.SessionManager.stop(orchestrator_uri) end)
    end

    :ok
  end

  # ── provenance + reap internals ──────────────────────────────────────────

  # SPEC §3.2 / §7 provenance gate: a worker SPAWNED INTO this session carries
  # the `:source_template_uri` spawn facet AND is in the owner's durable spawn
  # lineage. BOTH are required — the facet alone (an invited agent that happens
  # to carry one) must NOT be reapable.
  defp spawned_worker?(participant_meta, %URI{} = participant_uri, %URI{} = owner_uri) do
    has_spawn_facet?(participant_meta) and
      Ezagent.AgentLineage.spawned_in_lineage?(participant_uri, owner_uri)
  end

  defp spawned_worker?(_meta, _participant, _owner), do: false

  defp has_spawn_facet?(participant_meta) when is_map(participant_meta) do
    case Map.get(participant_meta, :source_template_uri) do
      %URI{} -> true
      uri when is_binary(uri) and uri != "" -> true
      _ -> false
    end
  end

  defp has_spawn_facet?(_), do: false

  defp retirement_context(%URI{} = worker_uri, %URI{} = owner_uri, mode) do
    %{
      caller: owner_uri,
      authenticated_principal: owner_uri,
      caps: owner_caps(owner_uri),
      workspace_uri: Ezagent.URI.workspace_of(worker_uri),
      provenance_root: owner_uri,
      creation_attempt_id: creation_attempt_id(worker_uri),
      reason: {:session_teardown, mode}
    }
  end

  defp retirement_context(%URI{} = worker_uri, _owner_uri, mode) do
    %{
      caller: worker_uri,
      authenticated_principal: worker_uri,
      caps: MapSet.new(),
      workspace_uri: Ezagent.URI.workspace_of(worker_uri),
      provenance_root: worker_uri,
      creation_attempt_id: creation_attempt_id(worker_uri),
      reason: {:session_teardown, mode}
    }
  end

  defp owner_caps(owner_uri) do
    case Ezagent.Domain.Agent.read_caps(owner_uri, %{
           caller: owner_uri,
           authenticated_principal: owner_uri
         }) do
      {:ok, caps} -> MapSet.new(caps)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp creation_attempt_id(worker_uri) do
    case Ezagent.Agent.CreationInventory.find_attempt(
           worker_uri,
           Ezagent.URI.workspace_of(worker_uri)
         ) do
      {:ok, attempt_id} -> attempt_id
      {:error, _reason} -> "missing-creation-attempt"
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Session.Teardown.cascade_teardown step failed: #{inspect(e)}")
      :error
  catch
    kind, reason ->
      Logger.warning("Session.Teardown.cascade_teardown step crashed: #{inspect({kind, reason})}")
      :error
  end
end
