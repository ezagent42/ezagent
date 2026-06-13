defmodule Ezagent.Entity.Session.Orchestrator do
  @moduledoc false

  require Logger

  @compile_env Mix.env()
  # 2026-05-31 orchestrator-startup-atomicity §5 — the LIVE-join readiness
  # gate timeout. After spawning the orchestrator PTY, the create flow polls
  # `Ezagent.Orchestrator.LiveJoinRegistry.joined?/1`, with an opportunistic
  # `{:orchestrator_ready, uri}` broadcast `receive` for instant wake.
  @orchestrator_readiness_timeout_ms 90_000
  @orchestrator_readiness_poll_ms 2_000

  # ensure_orchestrator — spawn / adopt the session's orchestrator agent
  # (2026-05-31 orchestrator-startup-atomicity §4 step 5; 2-way ownership)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Ensure an orchestrator agent exists for `session_uri` in `workspace_uri`
  owned by `owner_uri`. Returns one of three shapes:

    * `{:ok, orchestrator_uri, :created | :already_present}` — orchestrator
      is alive in `KindRegistry`, owned by `owner_uri`, bound to
      `workspace_uri`. `:created` ⇔ this call started the worker;
      `:already_present` ⇔ the worker pre-existed.
    * `{:partial, %{orchestrator_pending: candidate_uri}}` — the URI is
      reserved but ownership classification is incomplete (lineage and/or
      workspace registries haven't caught up). LV / CLI should render
      "pending" + invite a retry.
    * `{:error, reason}` — orchestrator spawn failed OR positive foreign
      evidence (lineage/workspace POSITIVELY mismatch) was detected.

  Made public 2026-05-26 (SPEC `2026-05-26-session-create-orchestrator-unified`
  Gap A) so `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can wire it in directly,
  giving the LV/CLI/bootstrap entry the same auto-spawn semantics the
  SessionTemplate.instantiate path always had. The internal logic is
  unchanged from when this was `defp` — only the visibility flipped.

  This call brings up the orchestrator's **Agent Kind GenServer** (the
  chat-domain identity for the orchestrator) AND its cc PTY +
  `claude` subprocess by calling `Agent.spawn_from_template_content/4`
  directly with the cc-orchestrator AgentTemplate's content slice. The
  orchestrator's "orchestrator" role — which causes the cc Template
  Class to load the `ezagent-session-orchestrator` skill into the
  per-agent config dir + append the CLAUDE.md hint + set
  `EZAGENT_AGENT_ROLE=orchestrator` in `cmd_env` — is carried on the
  cc-orchestrator AgentTemplate's content slice (seeded by
  `Ezagent.Orchestrator.CcOrchestratorSeed.seed/0`), threaded through
  `Ezagent.Entity.AgentTemplate.to_template_data/2`.

  ## codex PR #408 review CRIT — call spawn_from_template_content directly

  Pre-fix this branch called `Agent.spawn_fresh/4` directly, which goes
  through the spawn-registry detailed path → `Kind.spawn(Agent,
  ...)` and NEVER reaches `Template.instantiate`. The cc Template Class's
  `apply_orchestrator_role_bootstrap/2` therefore never ran on the
  auto-spawn path. Result: orchestrator agents created via
  `ensure_orchestrator` got no skill copy, no CLAUDE.md hint, and no
  `EZAGENT_AGENT_ROLE` env var — entire SPEC Gap B was dead.

  Post-fix this branch reads the cc-orchestrator AgentTemplate's content
  slice via `:sys.get_state` (the AgentTemplate Kind is the SOLE source
  of truth) and calls `Agent.spawn_from_template_content/4` — the same
  helper the `Behavior.Template :instantiate` action body calls, minus
  the dispatch-level CapBAC + the action-body's anti-cross-workspace
  workspace_uri check (`apps/ezagent_domain_instance_message/.../behavior/template.ex`
  line 435 `resolve_workspace_uri/3` — "cross-workspace instantiation is
  not a V1 feature"). The cc-orchestrator AgentTemplate is system-scoped
  (`template://agent/system/cc-orchestrator`) but each tenant workspace's
  orchestrator agent must land in THEIR OWN workspace. This is a
  legitimate cross-workspace spawn the dispatch path was never designed
  for — going around the action body but still through the in-process
  helper gives us the cc Template Class's role-bootstrap while
  preserving structural ownership semantics (lineage + workspace bind
  happen inside `spawn_from_template_content/4`).

  The `role_degraded` info that `cc_agent` surfaces in its meta map
  when skill-copy fails (codex PR #408 review HIGH-3) is propagated
  through to `EzagentDomainInstanceMessage.SessionCreator.create_session/3`'s meta so the caller
  can notify the owner per Invariant #9.
  """
  @spec ensure_orchestrator(URI.t(), URI.t(), URI.t()) ::
          {:ok, URI.t(), :created | :already_present}
          | {:ok, URI.t(), :created | :already_present, map()}
          | {:error, term()}
  def ensure_orchestrator(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri
      ) do
    # 2026-05-31 orchestrator-startup-atomicity §4 step 5 — ownership is
    # now 2-way (`:owned` / `:not_live` / `:foreign`). The
    # `:ownership_pending` retry loop (`retry_after_race`/`do_retry`/
    # `@retry_*`) is DELETED: with the dead Generator gone + adoption
    # removed, the atomic create commits lineage + workspace bind inside
    # the spawn before this classification runs, so there is no limbo
    # window for a freshly-spawned orchestrator. A live URI that does
    # NOT positively match us is `:foreign` (real cross-tenant collision
    # / corruption) → fail-loud. The caller
    # (`EzagentDomainInstanceMessage.SessionCreator.create_session/3`) rolls back on `{:error, _}`.
    candidate_uri = build_orchestrator_uri_for_create(session_uri, workspace_uri)
    orch_template_uri = Ezagent.URI.template(:system, :agent, "cc-orchestrator")
    instance_name = build_orchestrator_instance_name_for_create(session_uri)

    case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
      {:owned, ^candidate_uri} ->
        {:ok, candidate_uri, :already_present}

      :not_live ->
        # codex PR #408 review CRIT — instantiate via the cc Template
        # Class (`spawn_from_template_content/4`) so the role-bootstrap
        # runs, instead of bypass-spawning via `Agent.spawn_fresh/4`.
        #
        # 2026-05-31 codex-review Q4 — the pre-spawn `check_orchestrator`
        # above is a TOCTOU window: a concurrent registration of the same
        # orchestrator URI between this `:not_live` classification and
        # the template-instantiate makes `Agent.spawn_from_template_content`
        # ADOPT the existing worker (`fresh? == false`), and the adopted
        # path SKIPS the lineage + workspace obligations a fresh spawn
        # establishes. We therefore RE-VERIFY ownership AFTER the spawn
        # (`finalize_spawned_orchestrator/5`): an adopted worker has its
        # lineage + bind established idempotently so it carries the SAME
        # ownership records a fresh one does, and a post-spawn URI that
        # still does not classify `:owned` is a real foreign claim →
        # `{:error, _}` (→ caller rollback, fail-loud). No silent success
        # on an unverified adoption.
        #
        # 2026-05-31 orchestrator-startup-atomicity §5 — the readiness
        # gate (90s deadline) wraps the spawn. We SUBSCRIBE to the
        # `"orch:lifecycle"` topic BEFORE the spawn (instant-wake
        # optimization), spawn + finalize ownership, THEN POLL the durable
        # `LiveJoinRegistry.joined?(candidate_uri)` state (marked by
        # `McpChannel.join/3`) on a bounded deadline loop, with the
        # broadcast `receive` as an early-wake. On the deadline the PTY is
        # killed + `{:error, {:orchestrator_not_ready_within, ...}}` →
        # caller rollback. The POLL (not a fire-once receive) is the fix:
        # a live join that completed before the gate parked on the topic
        # is still observed. In test_mode the synchronous
        # `register_orchestrator_mcp_context` is the readiness signal
        # (there is no live claude to join the bridge), so the live wait
        # is skipped — see `await_orchestrator_ready/3`.
        ready_ref = subscribe_orchestrator_lifecycle()

        spawn_result =
          case spawn_orchestrator_via_template_content(
                 candidate_uri,
                 orch_template_uri,
                 instance_name,
                 workspace_uri,
                 owner_uri
               ) do
            {:error, _} = err ->
              err

            {:ok, ^candidate_uri, outcome, fresh?, degraded_meta} ->
              finalize_spawned_orchestrator(
                candidate_uri,
                owner_uri,
                workspace_uri,
                outcome,
                fresh?,
                degraded_meta
              )
          end

        gate_orchestrator_readiness(spawn_result, candidate_uri, ready_ref)

      {:foreign, evidence} ->
        # POSITIVE foreign evidence (lineage / workspace POSITIVELY
        # mismatches). Real corruption / cross-tenant collision.
        {:error, {:orchestrator_foreign, candidate_uri, evidence}}
    end
  end

  # 2026-05-31 codex-review Q4 — post-spawn ownership re-verification +
  # adopted-orchestrator lineage/bind establishment.
  #
  #   * `fresh? == true`  — `spawn_from_template_content/4` already ran
  #     `establish_post_spawn_obligations/3` (lineage + workspace bind)
  #     inside the spawn. We still RE-CHECK to close the race where a
  #     concurrent claimant overwrote our just-recorded ownership; a
  #     non-`:owned` result is fail-loud.
  #   * `fresh? == false` — ADOPTED a worker someone else (or a racing
  #     create) registered. The adopt path in `spawn_from_template_content/4`
  #     SKIPS the obligations, so we establish them HERE, idempotently
  #     (`AgentLineage.record/2` upserts; `WorkspaceRegistry.bind/2`
  #     overwrites), giving the adopted orchestrator the SAME lineage +
  #     bind a fresh one has — THEN re-check `:owned`.
  #
  # A `check_orchestrator/3` that is not `:owned` after this →
  # `{:error, {:orchestrator_not_owned_after_spawn, candidate_uri, ev}}`
  # so the caller (`EzagentDomainInstanceMessage.SessionCreator.create_session/3`) rolls back.
  defp finalize_spawned_orchestrator(
         %URI{} = candidate_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri,
         outcome,
         fresh?,
         degraded_meta
       ) do
    unless fresh? do
      _ = establish_orchestrator_ownership(candidate_uri, owner_uri, workspace_uri)
    end

    case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
      {:owned, ^candidate_uri} ->
        wrap_orchestrator_ok(candidate_uri, outcome, degraded_meta)

      other ->
        {:error, {:orchestrator_not_owned_after_spawn, candidate_uri, other}}
    end
  end

  # Idempotent ownership records for an ADOPTED orchestrator — the same
  # two writes `Agent.establish_post_spawn_obligations/3` performs for a
  # fresh worker, lifted here so the adopt path is not left without them.
  # Both are upsert/overwrite semantics, so a re-run (or running over a
  # worker that already had them) is a no-op.
  defp establish_orchestrator_ownership(
         %URI{} = orchestrator_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :record, 2) do
      _ = Ezagent.AgentLineage.record(orchestrator_uri, owner_uri)
    end

    _ = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, workspace_uri)
    :ok
  end

  defp wrap_orchestrator_ok(%URI{} = candidate_uri, outcome, degraded_meta)
       when map_size(degraded_meta) == 0,
       do: {:ok, candidate_uri, outcome}

  defp wrap_orchestrator_ok(%URI{} = candidate_uri, outcome, degraded_meta),
    do: {:ok, candidate_uri, outcome, degraded_meta}

  # 2026-05-31 orchestrator-startup-atomicity §5 — the LIVE-join readiness
  # gate. Called AFTER the spawn + ownership finalize. On a spawn/finalize
  # error it short-circuits (no PTY to gate). On success it awaits the
  # live bridge join via a robust poll:
  #
  #   * PRODUCTION (real PTY) — POLL `LiveJoinRegistry.joined?(candidate)`
  #     on a 90s deadline loop (durable state marked by
  #     `McpChannel.join/3`), with the `{:orchestrator_ready, candidate}`
  #     broadcast as an instant-wake. On ready → return the spawn ok. On
  #     the deadline → kill the orchestrator PTY + Kind and return
  #     `{:error, {:orchestrator_not_ready_within, 90_000}}` so the caller
  #     (`EzagentDomainInstanceMessage.ensure_orchestrated_session/4`) fail-loud rolls
  #     back. NO `:pending`, NO `:failed`-alive zombie.
  #   * TEST-MODE — there is no live claude to JOIN the MCP bridge, so the
  #     live-join state is NEVER marked. The synchronous
  #     `register_orchestrator_mcp_context` (caller step 7) is the test's
  #     readiness; skip the live wait + return the spawn ok unchanged. The
  #     true gate is validated by the live e2e, NOT the unit suite.
  defp gate_orchestrator_readiness({:error, _} = err, _candidate_uri, ready_ref) do
    # Don't leak the "orch:lifecycle" subscription on the spawn/finalize
    # error path (success + timeout paths already unsubscribe). (codex Q2.)
    if ready_ref == :subscribed, do: unsubscribe_orchestrator_lifecycle()
    err
  end

  defp gate_orchestrator_readiness({:ok, %URI{} = candidate_uri, _, _} = ok, candidate_uri, ref) do
    await_orchestrator_ready(ok, candidate_uri, ref)
  end

  defp gate_orchestrator_readiness({:ok, %URI{} = candidate_uri, _} = ok, candidate_uri, ref) do
    await_orchestrator_ready(ok, candidate_uri, ref)
  end

  # Subscribe to the orchestrator lifecycle topic BEFORE the spawn. In
  # test_mode we don't subscribe (no live join arrives) — `nil` ref signals
  # the await to bypass. Returns `:subscribed | nil`.
  defp subscribe_orchestrator_lifecycle do
    if orchestrator_gate_test_mode?() do
      nil
    else
      :ok =
        Phoenix.PubSub.subscribe(
          EzagentCore.PubSub,
          Ezagent.Session.OrchestratorReadinessPort.lifecycle_topic()
        )

      :subscribed
    end
  end

  # Await the orchestrator's LIVE bridge join. `nil` ref → test_mode
  # bypass (return ok unchanged — no live claude joins in `:test`). On
  # the overall deadline → kill the PTY + Kind, return the loud error.
  #
  # ROBUST POLL (not fire-once receive): the source of truth is the
  # DURABLE `Ezagent.Orchestrator.LiveJoinRegistry.joined?/1` state marked
  # by `McpChannel.join/3`. We poll it on a bounded deadline loop so a
  # join that completed BEFORE we parked on the topic is still observed —
  # the fire-once `{:orchestrator_ready, _}` broadcast was lost in exactly
  # that race, false-killing a working orchestrator. The broadcast is kept
  # as an opportunistic INSTANT-WAKE inside the `receive`'s timeout.
  defp await_orchestrator_ready(ok, _candidate_uri, nil), do: ok

  defp await_orchestrator_ready(ok, %URI{} = candidate_uri, :subscribed) do
    deadline = System.monotonic_time(:millisecond) + @orchestrator_readiness_timeout_ms
    poll_orchestrator_ready(ok, candidate_uri, deadline)
  end

  @doc false
  # TEST-ONLY entrypoint for the readiness poll. The production gate is
  # compile-time bypassed in `:test` (`@compile_env == :test`), so the
  # poll loop has no other exercise in the unit suite. This drives the
  # SAME `poll_orchestrator_ready/3` deadline loop with a caller-supplied
  # timeout so the invariant — `:ready` when `LiveJoinRegistry` is marked
  # within the window, fail-loud (`:orchestrator_not_ready_within`) when
  # never marked — is covered without a 90s wait or a live claude.
  # NOT a production path; the live gate calls `await_orchestrator_ready/3`.
  @spec __await_orchestrator_ready_for_test__(term(), URI.t(), non_neg_integer()) :: term()
  def __await_orchestrator_ready_for_test__(ok, %URI{} = candidate_uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_orchestrator_ready(ok, candidate_uri, deadline)
  end

  # Deadline loop: check durable live-join state, then block on a short
  # broadcast `receive` (instant wake) bounded by the remaining time. On
  # a matching broadcast OR a `joined?/1` true → ready. On the overall
  # deadline → fail-loud.
  defp poll_orchestrator_ready(ok, %URI{} = candidate_uri, deadline) do
    cond do
      Ezagent.Session.OrchestratorReadinessPort.joined?(candidate_uri) ->
        unsubscribe_orchestrator_lifecycle()
        ok

      true ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          orchestrator_ready_timeout(candidate_uri)
        else
          wait_ms = min(@orchestrator_readiness_poll_ms, remaining)

          receive do
            {:orchestrator_ready, %URI{}} ->
              # The broadcast is ONLY a wake signal (instant-wake so we
              # don't sleep the full poll tick). It is NOT proof of
              # readiness: loop back so the DURABLE
              # `LiveJoinRegistry.joined?/1` check at the top of
              # poll_orchestrator_ready/3 is the SOLE authority. A
              # spurious/stale broadcast for `candidate_uri` (one not
              # backed by a `mark_joined`) must NOT pass the gate.
              # codex #505 review MED. (The unsubscribe happens at the
              # top once `joined?` is true.)
              poll_orchestrator_ready(ok, candidate_uri, deadline)
          after
            wait_ms ->
              # Poll tick — re-check `joined?/1` (covers the lost-broadcast
              # race) and continue until the deadline.
              poll_orchestrator_ready(ok, candidate_uri, deadline)
          end
        end
    end
  end

  defp orchestrator_ready_timeout(%URI{} = candidate_uri) do
    unsubscribe_orchestrator_lifecycle()

    Logger.error(
      "Session.ensure_orchestrator: orchestrator #{URI.to_string(candidate_uri)} did " <>
        "NOT join its live MCP bridge within #{@orchestrator_readiness_timeout_ms}ms — " <>
        "killing the PTY + Kind and failing loud (caller rolls back the create)."
    )

    kill_orchestrator(candidate_uri)

    {:error, {:orchestrator_not_ready_within, @orchestrator_readiness_timeout_ms}}
  end

  defp unsubscribe_orchestrator_lifecycle do
    _ =
      Phoenix.PubSub.unsubscribe(
        EzagentCore.PubSub,
        Ezagent.Session.OrchestratorReadinessPort.lifecycle_topic()
      )

    :ok
  end

  # Tear down a PTY + Agent Kind that never reported ready. Best-effort,
  # each idempotent — the caller's rollback also runs, but the PTY/Kind
  # teardown belongs HERE (the gate spawned them).
  defp kill_orchestrator(%URI{} = candidate_uri) do
    _ =
      if Code.ensure_loaded?(Ezagent.Domain.Pty) and
           function_exported?(Ezagent.Domain.Pty, :stop, 1) do
        Ezagent.Domain.Pty.stop(candidate_uri)
      end

    _ = Ezagent.Kind.terminate(candidate_uri)

    # Clear any durable live-join row so a stale signal from this killed
    # incarnation can never satisfy a future startup gate. Idempotent.
    _ = Ezagent.Session.OrchestratorReadinessPort.clear(candidate_uri)
    :ok
  end

  # test_mode = `Mix.env() == :test`. The cc PtyServer short-circuits the
  # real `:exec.run/2` in `:test` env (cc_agent.ex build_pty_params_for_env
  # → `test_mode: true`), so no live claude exists to JOIN the MCP bridge
  # and signal readiness — the gate would always time out. The synchronous
  # `register_orchestrator_mcp_context` is the test's readiness instead.
  # Only PRODUCTION (real PTY) awaits the live join. Keep the compile-time
  # check for release-safety, and fall back to guarded runtime Mix detection
  # for precommit/app-start paths that may recompile this module outside the
  # test app context before running tests.
  defp orchestrator_gate_test_mode? do
    @compile_env == :test or (Code.ensure_loaded?(Mix) and Mix.env() == :test)
  end

  # codex PR #408 review CRIT — call `Agent.spawn_from_template_content/4`
  # directly after reading the cc-orchestrator AgentTemplate's content
  # slice. This routes the spawn through the cc Template Class's
  # `instantiate/3` (so role-bootstrap runs) but skips the dispatch's
  # action-body anti-cross-workspace check (`Behavior.Template.resolve_workspace_uri/3`)
  # — the cc-orchestrator template is `template://agent/system/...` but
  # each tenant workspace's orchestrator agent must land in THEIR OWN
  # workspace, which is a legitimate cross-workspace spawn the action
  # body intentionally refuses for V1.
  #
  # `instance_name` is the bare segment (e.g. `cc_orchestrator-<disc>`)
  # — `spawn_from_template_content/4`'s URI builder is given a fully-
  # formed `instance_uri` by us (the action body's flavor-prepending
  # is bypassed; we feed the URI verbatim).
  defp spawn_orchestrator_via_template_content(
         %URI{} = candidate_uri,
         %URI{} = orch_template_uri,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       )
       when is_binary(instance_name) do
    with {:ok, content} <- read_orchestrator_template_content(orch_template_uri),
         {:ok, result} <-
           Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             candidate_uri,
             owner_uri,
             workspace_uri,
             Ezagent.Entity.Session.orchestrator_spawn_template_opts(owner_uri, orch_template_uri)
           ) do
      # codex PR #408 review CRIT — return `candidate_uri` (URI.new!'d
      # form) as the canonical orchestrator URI, NOT `result.workers`'s
      # element (which is URI.parse'd by the cc Template Class — the
      # two are STRUCTURALLY different per `URI.parse` adding an
      # `authority` field that `URI.new!` omits, and downstream
      # callers/tests pinned against the URI.new! shape `spawn_fresh/4`
      # used pre-fix).
      #
      # 2026-05-31 codex-review Q4 — surface the raw `fresh?` flag so the
      # caller (`ensure_orchestrator/3` → `finalize_spawned_orchestrator/5`)
      # can re-verify ownership and establish lineage/bind on the adopt
      # path (`fresh? == false`). The 5-tuple is internal to this module.
      fresh? = Map.get(result, :fresh?, false) == true
      outcome = if fresh?, do: :created, else: :already_present
      degraded_meta = Map.take(result, [:role_degraded, :role_degraded_reason])

      {:ok, candidate_uri, outcome, fresh?, degraded_meta}
    end
  end

  # Read the cc-orchestrator AgentTemplate's `:template` slice content
  # via `:sys.get_state` — same pattern `CcOrchestratorSeed.seed_status/0`
  # uses. The AgentTemplate Kind must be alive (the boot seed runs
  # before any `ensure_orchestrator` call); a missing Kind returns
  # `{:error, :orchestrator_template_not_alive}` so the operator can see
  # the boot-order issue rather than a downstream confusing error.
  defp read_orchestrator_template_content(%URI{} = orch_template_uri) do
    case Ezagent.KindRegistry.lookup(orch_template_uri) do
      :error ->
        {:error, {:orchestrator_template_not_alive, orch_template_uri}}

      {:ok, pid} ->
        case safe_get_template_content(pid) do
          %{} = content when map_size(content) > 0 ->
            {:ok, content}

          _ ->
            {:error, {:orchestrator_template_not_populated, orch_template_uri}}
        end
    end
  end

  # `:sys.get_state` on a Kind.Server returns `%{state: %{template: <slice>}}`.
  # Wrapped to swallow timeouts / restarts (the AgentTemplate Kind is
  # snapshot-persisted, so a brief restart races are normal) — returns
  # `%{}` on any failure so the caller surfaces
  # `:orchestrator_template_not_populated`.
  #
  # Lifecycle migration (SPEC 2026-05-29): `Ezagent.Behavior.Template`
  # now uses `use Ezagent.Lifecycle`, so the `:template` slice is the
  # two-container `%{state: %{content: ...}, transients: %{}}` shape (the
  # framework persists only `:state`; `:content` is fully persistent).
  # This raw `:sys.get_state` read therefore matches the two-container
  # form FIRST, then falls back to the legacy flat `%{content: ...}` form
  # (a pre-migration snapshot or a non-Lifecycle Behavior). Reading the
  # raw process state (vs `Kind.get_slice/2`'s normalized view) is
  # deliberate here — it swallows restart-race timeouts the comment above
  # describes without a blocking `GenServer.call`.
  defp safe_get_template_content(pid) do
    case :sys.get_state(pid, 500) do
      %{state: %{template: %{state: %{content: content}}}} when is_map(content) -> content
      %{state: %{template: %{content: content}}} when is_map(content) -> content
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # 2-way classification on a LIVE candidate (2026-05-31
  # orchestrator-startup-atomicity §4 step 5):
  #   :owned — BOTH lineage + workspace POSITIVELY match us
  #   {:foreign, ev} — anything else on a live URI (a positive mismatch
  #     OR a missing lineage/workspace binding under a URI someone else
  #     already registered). With adoption gone + the atomic create
  #     committing lineage+bind inside the spawn, there is no "spawn
  #     inflight" limbo to wait out — a live-but-unmatched URI is a real
  #     foreign claim, surfaced fail-loud so the caller rolls back.
  #   :not_live — KindRegistry lookup missed (we are clear to spawn)
  defp check_orchestrator(%URI{} = uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        :not_live

      {:ok, _pid} ->
        lineage_state =
          case Ezagent.AgentLineage.lookup(uri) do
            {:ok, %URI{} = principal} ->
              if URI.to_string(principal) == URI.to_string(owner_uri),
                do: :match,
                else: {:mismatch, URI.to_string(principal)}

            :error ->
              :absent
          end

        workspace_state =
          case Ezagent.WorkspaceRegistry.lookup(uri) do
            {:ok, %URI{} = bound} ->
              if URI.to_string(bound) == URI.to_string(workspace_uri),
                do: :match,
                else: {:mismatch, URI.to_string(bound)}

            :error ->
              :absent
          end

        if lineage_state == :match and workspace_state == :match do
          {:owned, uri}
        else
          # Live URI that does not positively match us — a foreign claim
          # (mismatch) OR an incomplete binding under an already-registered
          # URI. No retry/limbo (adoption + Generator removed); fail-loud.
          {:foreign, %{lineage: lineage_state, workspace: workspace_state}}
        end
    end
  end

  @doc """
  Read the stored orchestrator agent URI for a session.

  The orchestrator is a session attribute stored in the Chat working-copy
  slice and resolved through `Ezagent.UriQuery`; callers must not infer it
  from URI segment names.
  """
  @spec orchestrator_uri(URI.t()) :: {:ok, URI.t()} | :none | {:error, term()}
  def orchestrator_uri(%URI{} = session_uri) do
    Ezagent.UriQuery.resolve(:orchestrator, session_uri)
  end

  @doc """
  Read the stored orchestrator instance name for a session.
  """
  @spec orchestrator_instance_name(URI.t()) :: {:ok, String.t()} | :none | {:error, term()}
  def orchestrator_instance_name(%URI{} = session_uri) do
    case orchestrator_uri(session_uri) do
      {:ok, %URI{} = orchestrator_uri} -> Ezagent.URI.name(orchestrator_uri)
      :none -> :none
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec planned_orchestrator_uri(URI.t(), URI.t()) :: URI.t()
  def planned_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    build_orchestrator_uri_for_create(session_uri, workspace_uri)
  end

  defp build_orchestrator_uri_for_create(%URI{} = session_uri, %URI{} = workspace_uri) do
    instance_name = build_orchestrator_instance_name_for_create(session_uri)

    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    Ezagent.URI.agent(workspace_name, instance_name)
  end

  defp build_orchestrator_instance_name_for_create(%URI{} = session_uri) do
    # Preserve the historical "cc_orchestrator-<session_name>" shape.
    "cc_orchestrator-#{session_discriminator(session_uri)}"
  end

  @doc """
  Ownership predicate — a worker is "owned by us" iff its `AgentLineage`
  row points at our orchestrator AND its `WorkspaceRegistry` binding
  points at our workspace. URI comparison is canonical-string (registries
  store parsed structs derived from strings).

  Used by the orchestrator tools (`Ezagent.Orchestrator.Tools`) to gate
  worker adoption. (The Generator slot-reconcile call sites were deleted
  in the 2026-05-31 orchestrator-startup-atomicity pass.)
  """
  @spec worker_already_owned_by_us?(URI.t(), URI.t(), URI.t()) :: boolean()
  def worker_already_owned_by_us?(%URI{} = worker_uri, %URI{} = orch_uri, %URI{} = ws_uri) do
    case Ezagent.KindRegistry.lookup(worker_uri) do
      {:ok, _pid} ->
        lineage_ok? =
          case Ezagent.AgentLineage.lookup(worker_uri) do
            {:ok, %URI{} = sb} -> URI.to_string(sb) == URI.to_string(orch_uri)
            :error -> false
          end

        ws_ok? =
          case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
            {:ok, %URI{} = bw} -> URI.to_string(bw) == URI.to_string(ws_uri)
            :error -> false
          end

        lineage_ok? and ws_ok?

      :error ->
        false
    end
  end

  @doc """
  Read the durable `template_working_copy` map from a live Session's
  `:chat` slice (or the default when the session isn't live).

  2026-05-31 orchestrator-startup-atomicity §4 step 4 — kept + made
  public so the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can merge
  the OTU fields into the existing working copy before writing it back.
  """
  @spec read_template_working_copy(URI.t()) :: map()
  def read_template_working_copy(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        # Lifecycle migration (SPEC 2026-05-29 §2.3C): the Chat slice is now
        # two-container; the persistent `template_working_copy` lives under
        # its `:state`. The outer `Map.get(:state, ...)` reaches the
        # per-Kind slice store; the inner one unwraps the Chat two-container
        # (falling through for a not-yet-converted flat slice).
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.Behavior.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        Ezagent.Behavior.Session.template_working_copy(chat_persistent)

      :error ->
        Ezagent.Behavior.Session.default_template_working_copy()
    end
  end

  @doc """
  Read the live Session's `:chat` member URIs as a list.

  2026-05-31 orchestrator-startup-atomicity §4 step 2 (codex-review Q2)
  — used by the completeness check for an already-existing session: an
  owner that is NOT a chat member is one symptom of a half-create that
  crashed before the step-8 member join. Reads the same two-container
  `:chat` slice `read_template_working_copy/1` does (the persistent
  `:members` map lives under `:state`). Returns `[]` when the Session
  Kind is not live (it cannot have members if it isn't running).
  """
  @spec session_member_uris(URI.t()) :: [URI.t()]
  def session_member_uris(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.Behavior.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        chat_persistent
        |> Map.get(:members, %{})
        |> Map.keys()

      :error ->
        []
    end
  catch
    :exit, _ -> []
  end

  @doc """
  The live `:chat` slice's session-scoped legend registry (`name => entry`).

  team-routing-unification §3.6 (PR-6) — the legend-aware mention parsers
  (Feishu / LiveView) read this to resolve a `@legend` symbolic handle to its
  bound rule-set entry BEFORE the URI-mention path. Reads the same
  two-container `:chat` slice as `session_member_uris/1`; returns `%{}` when the
  Session Kind is not live (no legends if it isn't running).
  """
  @spec session_legends(URI.t()) :: map()
  def session_legends(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.Behavior.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)
        Ezagent.Behavior.Session.legends_of(chat_persistent)

      :error ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  # ─────────────────────────────────────────────────────────────────────
@doc "Grant the orchestrator its scope-bounded delegation caps (RFC #402 caps #1–#4) at session create. Delegates to `Orchestrator.Caps`; idempotent (skips logically-equal re-grants)."
defdelegate grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri),
  to: Ezagent.Entity.Session.Orchestrator.Caps

@doc "Revoke exactly the scoped-cap set `grant_orchestrator_scoped_caps/3` adds — the rollback inverse on a failed create. Delegates to `Orchestrator.Caps`; best-effort + idempotent."
defdelegate revoke_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri, workspace_uri),
  to: Ezagent.Entity.Session.Orchestrator.Caps

@doc "Whether two caps are logically equal ignoring volatile metadata (e.g. `granted_at`) — the idempotency comparator used by the scoped-cap grant/revoke. Delegates to `Orchestrator.Caps`."
defdelegate cap_equal_ignoring_metadata?(left, right),
  to: Ezagent.Entity.Session.Orchestrator.Caps

  # register_orchestrator_mcp_context  (2026-05-31 §4 step 7)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Register the orchestrator's MCP context (cache-fill).

  2026-05-31 orchestrator-startup-atomicity §4 step 7 — made public so
  the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` chokepoint can call it
  directly. The lazy `rebuild_from_durable` (now able to read OTU via
  the A+C2 unwrap fix) also reconstructs it on JOIN.
  """
  @spec register_orchestrator_mcp_context(URI.t(), URI.t(), URI.t(), URI.t(), URI.t()) ::
          :ok | {:error, term()}
  def register_orchestrator_mcp_context(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri,
        %URI{} = parent_template_uri
      ) do
    Ezagent.Session.OrchestratorReadinessPort.register_context(orchestrator_uri,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      parent_template_uri: parent_template_uri
    )
  end

  @doc "Ensure the SessionTemplate Kind at `template_uri` is materialized/alive before it is read or instantiated. Delegates to `Ezagent.Entity.Session`."
  defdelegate ensure_template_alive(template_uri), to: Ezagent.Entity.Session

  @doc """
  Read a SessionTemplate's `:template` content slice via the
  `template.read` dispatch (under the `system://template-materialize`
  principal). Returns `{:ok, content}` | `{:error, reason}`.

  2026-05-31 orchestrator-startup-atomicity §4 — kept + made public so
  the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can read the template's
  `orchestrator_template_uri` to materialize the session working copy.
  """
  @spec read_template_content(URI.t()) :: {:ok, map()} | {:error, term()}
  def read_template_content(%URI{} = session_template_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           # SPEC caps-cleanup-v1 §4.4 — reading template content
           # during materialization; runs under
           # `system://template-materialize` (closed Catalog).
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("template-materialize"),
             caps:
               "template-materialize"
               |> Ezagent.SystemPrincipal.uri()
               |> Ezagent.SystemPrincipal.caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:error, :session_template_not_populated}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_read_result, other}}
    end
  end

  # session discriminator: the session URI's name segment.
  defp session_discriminator(%URI{} = session_uri) do
    case Ezagent.URI.name(session_uri) do
      {:ok, name} -> name
      :error -> session_uri.host || "session"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
end
