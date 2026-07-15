defmodule Ezagent.ActionSet.Session.Teardown do
  @moduledoc false
  #
  # F7 PR-B — the shared participant-resource teardown for the session
  # participant lifecycle (SPEC §3.2 teardown hook + §4 delete cascade).
  #
  # ## The cap-model lever (SPEC §2.2)
  #
  # A managed worker is spawned by the orchestrator and the orchestrator is
  # spawned by the session OWNER, so the durable lineage chain is
  # `worker → orchestrator → owner`. `AgentLineage.spawned_in_lineage?`
  # walks that chain transitively, so the OWNER's
  # `cap(:agent, Sandbox, :destroy, {:spawned_by, owner_uri})` teardown cap
  # (granted at create — `Materializer.grant_owner_participant_teardown_cap/2`)
  # ALREADY authorizes `sandbox.destroy` on every worker spawned into any of
  # the owner's sessions — WITHOUT the orchestrator's cap #2 and WITHOUT
  # re-parenting the lineage graph. Because the lineage walk reads the durable
  # SQLite-backed table (not live processes), the reap works even when the
  # orchestrator Kind has crashed (the F7 headline bug). #154-clean: the cap is
  # `granted_by: owner_uri` (the owner IS the lineage root).
  #
  # ## Two callers, two failure modes
  #
  #   * `remove_participant` (the operator/self/orchestrator path) reaps a
  #     single worker in `:strict` mode — a missing owner teardown cap FAILS
  #     CLOSED (`{:error, _}`), the load-bearing authorization (SPEC §7
  #     "Self-leave privilege" / "Destroying a non-spawned participant").
  #   * `cascade_teardown` (the delete-session path, ridden by `Session.destroy/2`
  #     so EVERY delete path cascades — SPEC §4.1) reaps every participant +
  #     the orchestrator in `:best_effort` mode: a reap whose owner cap is
  #     somehow ABSENT (junk/ownerless/legacy session) falls back to the
  #     VM-internal `Ezagent.Lifecycle.destroy/2` primitive — the SAME primitive
  #     create-rollback uses (`SessionCreator.Rollback`). That is a legitimate
  #     system-internal teardown, NOT a forged cap (SPEC §2.4 documented
  #     fallback).

  require Logger

  alias Ezagent.ActionSet.Session.RoutingPrune
  alias Ezagent.Invocation

  @typedoc "Reap mode: strict fails closed; best_effort falls back to the VM primitive."
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
        :ok -> {:ok, :worker}
        {:error, _} = err -> err
      end
    else
      {:ok, :membership_only}
    end
  end

  @doc """
  Reap a single spawned worker: dispatch `?action=sandbox.destroy` on the
  worker under the OWNER's `{:spawned_by, owner_uri}` teardown cap (SPEC §2.2),
  which GCs the worker's `config_dir` (`Sandbox.handle_destroy`) + schedules
  Kind termination, THEN `AgentLineage.forget/1` (lineage parity with rollback).

  In `:best_effort` mode, a reap whose owner cap is ABSENT (or any reap error)
  falls back to the VM-internal `Ezagent.Lifecycle.destroy/2` primitive (whose
  `Sandbox.destroy/2` lifecycle hook ALSO GCs the config_dir) — the legitimate
  dead-orchestrator / junk-session safety net (SPEC §2.4 / §4.2). In `:strict`
  mode a reap error is surfaced (fail-closed authorization).

  Already-gone workers are idempotent `:ok`.
  """
  @spec reap_spawned_worker(URI.t(), URI.t() | nil, mode()) :: :ok | {:error, term()}
  def reap_spawned_worker(%URI{} = worker_uri, owner_uri, mode) do
    case owner_destroy_dispatch(worker_uri, owner_uri) do
      :ok ->
        _ = Ezagent.AgentLineage.forget(worker_uri)
        :ok

      {:error, reason} ->
        handle_reap_error(worker_uri, owner_uri, reason, mode)
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

  # Dispatch `sandbox.destroy` on the worker AS the OWNER. The dispatch authz
  # chokepoint (`Kind.Runtime` step 5.5 `granted_via_holds_cap?`) resolves the
  # owner's SLICE caps itself — including the `{:spawned_by, owner_uri}` teardown
  # cap — so this domain module does NOT read caps (cap-check only at the
  # chokepoint; `feedback`/CapCheckOnlyAtChokepoint p6). An owner without the
  # teardown cap → step 5.5 denies → `{:error, :unauthorized}` (strict fails
  # closed; best-effort falls back). Mirrors the result handling of the
  # orchestrator's `Tools.terminate_worker/3` (already-gone is idempotent `:ok`).
  # A `%URI{}`-less owner (ownerless junk session) → `{:error, :no_owner}`.
  defp owner_destroy_dispatch(%URI{} = worker_uri, %URI{} = owner_uri) do
    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(worker_uri, :sandbox, :destroy),
        mode: :call,
        args: %{},
        ctx: %{
          caller: owner_uri,
          caps: MapSet.new(),
          reply: {:caller_inbox, self()}
        }
      })

    interpret_destroy_result(result)
  end

  defp owner_destroy_dispatch(_worker_uri, _owner_uri), do: {:error, :no_owner}

  defp interpret_destroy_result({:ok, %{destroyed: true, cleanup: :ok}}), do: :ok

  # `destroyed: true` means the worker PROCESS is IRREVERSIBLY terminating
  # (Sandbox always schedules termination), even when the plugin config_dir FS
  # cleanup FAILED. The worker is gone, so the membership teardown MUST still
  # proceed — returning an error here would abort the leave and leave a zombie
  # member referencing a dead worker with no {:member_left} (codex Q4 follow-up /
  # SPEC §7 'Silent orphan'). The FS leak is logged by Sandbox (slice preserved
  # for retry) + here for out-of-band cleanup; it does NOT block membership drop.
  defp interpret_destroy_result({:ok, %{destroyed: true, cleanup: {:error, reason}}}) do
    Logger.warning(
      "Session.Teardown: worker reaped (process terminating) but its config_dir " <>
        "cleanup FAILED (#{inspect(reason)}) — FS dir leaked, slice preserved for " <>
        "out-of-band retry; membership teardown proceeds (no zombie)."
    )

    :ok
  end

  defp interpret_destroy_result({:ok, %{destroyed: true}}), do: :ok
  defp interpret_destroy_result({:ok, {:ok, :terminated}}), do: :ok
  defp interpret_destroy_result({:ok, :terminated}), do: :ok
  defp interpret_destroy_result({:error, :no_such_actor}), do: :ok
  defp interpret_destroy_result({:error, :not_ready}), do: :ok
  defp interpret_destroy_result({:error, _} = err), do: err
  defp interpret_destroy_result(other), do: {:error, {:unexpected_terminate_result, other}}

  # SPEC §2.4 documented fallback: an absent/insufficient owner cap on the
  # best-effort cascade falls back to the VM-internal `Lifecycle.destroy/2`
  # primitive (its `Sandbox.destroy/2` lifecycle hook GCs the config_dir too).
  # Strict reaps surface the error (fail-closed authorization).
  defp handle_reap_error(%URI{} = worker_uri, owner_uri, reason, :best_effort) do
    Logger.warning(
      "Session.Teardown.cascade: owner-authority reap of #{inspect(worker_uri)} failed " <>
        "(#{inspect(reason)}) — falling back to VM-internal Lifecycle.destroy (junk/" <>
        "ownerless/dead-orchestrator safety net, SPEC §2.4)."
    )

    _ =
      Ezagent.Domain.Agent.retire_spawned(worker_uri, owner_uri, :session_delete,
        allow_unverified_fallback: true
      )

    :ok
  end

  defp handle_reap_error(_worker_uri, _owner_uri, reason, :strict),
    do: {:error, {:worker_teardown_failed, reason}}

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
