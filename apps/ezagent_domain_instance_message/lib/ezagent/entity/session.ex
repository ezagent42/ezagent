defmodule Ezagent.Entity.Session do
  @moduledoc """
  Session Kind — the "room" in Phase 2's chat routing model.

  A Session is the entity that holds a set of member URIs and routes
  outbound chat messages to them. Per Decision #61 + P2-D2 K-path:
  Session handles `:send / :join / :leave` actions; the member-side
  `:receive` action runs on the recipient Kind (User / Agent).

  Phase 2 spawns exactly one default instance — `session://default/system/main` —
  at `EzagentDomainInstanceMessage.Application.start/2`. Multi-Session support is
  intentionally out of scope (Phase 3+).

  ## Persistence: {:snapshot, :on_change} — session membership survives restart

  See git history for the rationale (Allen V1 acceptance 2026-05-22) —
  the slice is now snapshotted on every change so membership +
  template_working_copy survive an unclean crash.
  """

  @behaviour Ezagent.Kind
  @behaviour Ezagent.Behavior.Publisher

  # Compile-time env capture (release-safe; Mix is not loaded in releases).
  # Used by the orchestrator-readiness gate's test-mode bypass. (codex Q1.)
  @compile_env Mix.env()

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors,
    # ExternalMirror PR-EM-0 (SPEC §8.1) — `Publisher.SessionImpl` owns
    # the `:publisher` slice + serves the 3 publisher actions; declared
    # alongside Chat so every Session Kind boots with both slices.
    #
    # ExternalMirror PR-EM-3 (SPEC §4.1) — `Behavior.ExternalMirror`
    # owns the `:external_mirror` slice + the bind / unbind /
    # list_bindings actions; declared here so `init_slice/1`
    # rehydrates the binding list from the projection table on
    # Session boot AND `post_init/2` schedules the worker
    # reconciliation handle_continue per SPEC §3.1.
    do: [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Publisher.SessionImpl,
      Ezagent.Behavior.ExternalMirror
    ]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.SessionSupervisor

  require Logger

  # 2026-05-31 orchestrator-startup-atomicity §5 — the LIVE-join readiness
  # gate timeout. After spawning the orchestrator PTY, the create flow
  # POLLS `Ezagent.Orchestrator.LiveJoinRegistry.joined?/1` (durable state
  # marked by `McpChannel.join/3` when the real claude's MCP bridge joins
  # + resolves to a registered orchestrator), with an opportunistic
  # `{:orchestrator_ready, uri}` broadcast `receive` for instant wake. On
  # the overall deadline the PTY is killed +
  # `{:error, {:orchestrator_not_ready_within, ms}}` is returned so the
  # caller fail-loud rolls back. NO `:pending`, NO `:failed`-alive.
  #
  # 90s (was 30s): a claude COLD start (first PTY spawn pulling the model
  # + the MCP bridge stdio handshake) realistically exceeds 30s — verified
  # live that a cold start needs tens of seconds. 30s false-killed working
  # orchestrators.
  @orchestrator_readiness_timeout_ms 90_000

  # Poll interval for the durable live-join check inside the readiness
  # deadline loop. Short enough to wake promptly, long enough to be a
  # negligible mailbox cost; the broadcast `receive` wakes earlier still.
  @orchestrator_readiness_poll_ms 2_000

  @doc """
  URI of the default Session instance spawned at boot.

  SPEC v3 §3.6 — sessions are 3-segment: `session://<template>/<workspace>/<name>`.
  """
  @spec default_uri() :: URI.t()
  # PR #335 workspace rename (default → system) + Allen 2026-05-26
  # follow-up: this hardcoded literal was the writer behind the
  # ExternalMirrorWorker restart loop observed today. Every LV
  # bind flow / mix task that called default_uri/0 wrote the OLD
  # workspace name into the DB, leaving orphan binding rows the
  # boot reconciler couldn't resolve.
  def default_uri, do: Ezagent.URI.session(:system, :default, :main)

  # ─────────────────────────────────────────────────────────────────────
  # Ezagent.Behavior.Publisher implementation (ExternalMirror PR-EM-0)
  #
  # The four callbacks below satisfy the `@behaviour Ezagent.Behavior.Publisher`
  # contract declared at the top of this module. They route every
  # publisher action through `Ezagent.Invocation.dispatch/1` against the
  # Session's URI so caps are gated at step 5.5 + workspace isolation
  # at step 5.6 — same posture as any other Session action.
  #
  # SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  # §2.1 + §8.1. The actual ring + cursor + subscriber bookkeeping
  # lives in `Ezagent.Behavior.Publisher.SessionImpl` (the Behavior
  # added to `behaviors/0`).
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Retention policy for the V1 Session publisher: 100 events
  (count-based; per OQ-EM-A resolution — option (a), Allen 2026-05-24).
  Override the slice-level `:retention` field via the
  `publisher_retention:` spawn arg if a per-session value is needed.
  """
  @impl Ezagent.Behavior.Publisher
  def history_retention, do: 100

  @doc """
  Subscribe `subscriber_pid` to this Session's structured slice-change
  stream starting from `cursor` (`:latest`, `:earliest`, or an integer).

  ## Caller MUST supply their own ctx

  The `@behaviour Ezagent.Behavior.Publisher` contract is 3-ary
  (per SPEC §2.1). The 3-ary form raises with a clear pointer to
  the 4-ary `subscribe_from/4` because the V1 codebase has no
  ambient-caps mechanism: every dispatch requires explicit
  `ctx.caller + ctx.caps` per CapBAC step 5.5, and a public 3-ary
  function with a default admin-caps fallback would let any in-VM
  caller bypass the Publisher cap (codex round-1 CRITICAL,
  2026-05-25).

  Use `subscribe_from/4` and pass an explicit `ctx` map containing
  `:caller` (a `%URI{}`) and `:caps` (a MapSet of `%Capability{}`
  the caller actually holds). Production Worker callers (PR-EM-2)
  pass their own ctx; tests pass admin caps explicitly.
  """
  @impl Ezagent.Behavior.Publisher
  def subscribe_from(%URI{} = _publisher_uri, subscriber_pid, _cursor)
      when is_pid(subscriber_pid) do
    raise_no_ambient_caps!(:subscribe_from, 4)
  end

  @doc """
  Snapshot the Session's current publisher cursor + state without
  subscribing. See `subscribe_from/3` for the no-ambient-caps
  rationale — use `snapshot/2` with explicit ctx.
  """
  @impl Ezagent.Behavior.Publisher
  def snapshot(%URI{} = _publisher_uri) do
    raise_no_ambient_caps!(:snapshot, 2)
  end

  @doc """
  Read events in the `(from, to]` cursor window from the Session's
  retained publisher ring. See `subscribe_from/3` for the
  no-ambient-caps rationale — use `history/4` with explicit ctx.
  """
  @impl Ezagent.Behavior.Publisher
  def history(%URI{} = _publisher_uri, _from, _to) do
    raise_no_ambient_caps!(:history, 4)
  end

  @doc """
  4-ary `subscribe_from` that dispatches with the caller-supplied ctx.

  `ctx` MUST contain:

  - `:caller` — a `%URI{}` identifying the caller (used for CapBAC
    step 5.5 + workspace isolation step 5.6 + audit trail)
  - `:caps` — a `MapSet.t(%Ezagent.Capability{})` of caps the caller
    actually holds; step 5.5 verifies one matches the
    publisher-subscribe cap shape on this Session.

  Returns `{:ok, current_cursor}` on success;
  `{:error, :unauthorized}` if no held cap matches;
  `{:error, :cursor_out_of_window}` if `cursor` predates the oldest
  retained event; other `{:error, _}` shapes per the standard
  dispatch envelope.
  """
  @spec subscribe_from(URI.t(), pid(), Ezagent.Behavior.Publisher.cursor(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def subscribe_from(%URI{} = publisher_uri, subscriber_pid, cursor, ctx)
      when is_pid(subscriber_pid) and is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(
      :subscribe_from,
      %{subscriber_pid: subscriber_pid, cursor: cursor},
      ctx
    )
    |> unwrap_cursor()
  end

  @doc "2-ary `snapshot` with explicit caller ctx — see `subscribe_from/4`."
  @spec snapshot(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def snapshot(%URI{} = publisher_uri, ctx) when is_map(ctx) do
    dispatch_publisher_action(publisher_uri, :snapshot, %{}, ctx)
  end

  @doc "4-ary `history` with explicit caller ctx — see `subscribe_from/4`."
  @spec history(
          URI.t(),
          Ezagent.Behavior.Publisher.cursor(),
          Ezagent.Behavior.Publisher.cursor(),
          map()
        ) ::
          {:ok, [Ezagent.Publisher.Event.t()]} | {:error, term()}
  def history(%URI{} = publisher_uri, from, to, ctx) when is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(:history, %{from: from, to: to}, ctx)
    |> unwrap_events()
  end

  # Build + dispatch a publisher action against the publisher URI
  # using the caller-supplied `ctx`. The ctx MUST carry `:caller` +
  # `:caps`; if it doesn't, CapBAC step 5.5 will deny with
  # `{:error, :unauthorized}` (the let-it-crash posture — no default
  # caps, no implicit admin elevation).
  defp dispatch_publisher_action(%URI{} = publisher_uri, action, args, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(publisher_uri)}?action=publisher.#{action}")

    # Normalise the reply field: callers that didn't supply it get
    # `:ignore` (we still return the result via the synchronous dispatch
    # tuple — the reply field is only consumed by :cast mode + outbound
    # transports).
    normalised_ctx = Map.put_new(ctx, :reply, :ignore)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: normalised_ctx
    })
  end

  defp unwrap_cursor({:ok, %{cursor: cursor}}), do: {:ok, cursor}
  defp unwrap_cursor({:error, _} = err), do: err

  defp unwrap_events({:ok, %{events: events}}), do: {:ok, events}
  defp unwrap_events({:error, _} = err), do: err

  defp raise_no_ambient_caps!(action, arity) do
    raise ArgumentError,
          "Ezagent.Entity.Session.#{action}/#{arity - 1} (the @behaviour " <>
            "Ezagent.Behavior.Publisher 3-ary contract callback) requires an " <>
            "explicit caller ctx — use Ezagent.Entity.Session.#{action}/#{arity} " <>
            "with `ctx: %{caller: %URI{...}, caps: MapSet.new([...])}` instead. " <>
            "The V1 codebase has no ambient-caps mechanism; every dispatch " <>
            "must declare its caller + caps so CapBAC step 5.5 can gate " <>
            "non-Worker access (codex round-1 CRITICAL, 2026-05-25)."
  end

  @doc """
  PR-OWN-2 (caps-data-ownership SPEC #306 §7) — return the URI of the
  entity that "owns" this session (the user/agent that created it).

  Looks up the live Session Kind's `:chat` slice via
  `Ezagent.Kind.get_slice/2`. Returns:
  - `{:ok, %URI{}}` — the owner URI recorded at session creation
  - `{:ok, nil}` — session exists but has no recorded owner
    (system session, or pre-PR-OWN-2 snapshot without `:owner_uri`)
  - `{:error, reason}` — session not live or call failed

  Used by `Behavior.Chat.data_owner/1` which converts the result
  into `%URI{} | :no_owner` for the cap-grant authorization path.
  """
  @spec owner(URI.t() | String.t()) :: {:ok, URI.t() | nil} | {:error, term()}
  def owner(uri) do
    # Lifecycle migration (SPEC 2026-05-29 §2.3C): `Ezagent.Behavior.Chat`
    # now stores the two-container `%{state, transients}` slice, so
    # `get_slice(uri, :chat)` returns that shape and `:owner_uri` lives
    # under `:state`. Unwrap (a flat slice falls through unchanged for any
    # not-yet-converted snapshot path).
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{state: %{owner_uri: owner_uri}}} -> {:ok, owner_uri}
      {:ok, %{owner_uri: owner_uri}} -> {:ok, owner_uri}
      {:ok, nil} -> {:ok, nil}
      {:ok, _} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  # ─────────────────────────────────────────────────────────────────────
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
  through `SpawnRegistry.spawn_detailed(agent_uri)` → `Kind.spawn(Agent,
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
          Ezagent.Orchestrator.McpChannel.lifecycle_topic()
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
      Ezagent.Orchestrator.LiveJoinRegistry.joined?(candidate_uri) ->
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
        Ezagent.Orchestrator.McpChannel.lifecycle_topic()
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
    _ = Ezagent.Orchestrator.LiveJoinRegistry.clear(candidate_uri)
    :ok
  end

  # test_mode = `Mix.env() == :test`. The cc PtyServer short-circuits the
  # real `:exec.run/2` in `:test` env (cc_agent.ex build_pty_params_for_env
  # → `test_mode: true`), so no live claude exists to JOIN the MCP bridge
  # and signal readiness — the gate would always time out. The synchronous
  # `register_orchestrator_mcp_context` is the test's readiness instead.
  # Only PRODUCTION (real PTY) awaits the live join. Compile-time attr
  # (not runtime Mix.env()) for release-safety. (codex final-review Q1.)
  defp orchestrator_gate_test_mode?, do: @compile_env == :test

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
             workspace_uri
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
          |> Map.get(Ezagent.Behavior.Chat.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        Ezagent.Behavior.Chat.template_working_copy(chat_persistent)

      :error ->
        Ezagent.Behavior.Chat.default_template_working_copy()
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
          |> Map.get(Ezagent.Behavior.Chat.state_slice(), %{})

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
          |> Map.get(Ezagent.Behavior.Chat.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)
        Ezagent.Behavior.Chat.legends_of(chat_persistent)

      :error ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  # ─────────────────────────────────────────────────────────────────────
  # grant_orchestrator_scoped_caps  (2026-05-31 §4 step 6; codex rev-2
  # HIGH-1 idempotency)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Grant the orchestrator its scope-bounded delegation caps + (if the
  owner holds them) the delegable Template caps.

  RFC #402 (Allen 2026-05-26): caps #1–#4 go TO the orchestrator. The
  workspace is derived from the session's `WorkspaceRegistry` binding
  (set by the atomic create before this runs).

  2026-05-31 orchestrator-startup-atomicity §4 step 6 — made public +
  the owner `OrchestratorAdmin :restart` grant was split OUT (it now
  lives in `EzagentDomainInstanceMessage.SessionCreator.create_session/3`, the single chokepoint,
  using the named `cap_equal_ignoring_metadata?/2`). This function
  grants ONLY the orchestrator-side caps.

  Idempotent: a re-grant of a logically-equal cap is skipped via
  `cap_equal_ignoring_metadata?/2`.
  """
  @spec grant_orchestrator_scoped_caps(URI.t(), URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_orchestrator_scoped_caps(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = owner_uri
      ) do
    session_workspace =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise "session #{URI.to_string(session_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for orchestrator scope caps"
      end

    do_grant_orchestrator_scoped_caps(
      orchestrator_uri,
      session_uri,
      owner_uri,
      session_workspace
    )
  end

  defp do_grant_orchestrator_scoped_caps(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = session_workspace
       ) do
    desired = build_desired_caps(orchestrator_uri, session_uri, owner_uri, session_workspace)
    current = Ezagent.Identity.list_caps_for(orchestrator_uri)

    to_grant =
      Enum.reject(desired, fn want ->
        Enum.any?(current, &cap_equal_ignoring_metadata?(&1, want))
      end)

    target = Ezagent.URI.with_action(orchestrator_uri, :identity, :grant_cap)

    # SPEC caps-cleanup-v1 §4.4 — granting scoped caps to the
    # orchestrator at session creation is template materialization;
    # runs under `system://template-materialize` (closed Catalog).
    # `owner_uri` stays as caller for provenance.
    ctx = %{
      caller: owner_uri,
      caps:
        "template-materialize" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
      reply: :ignore
    }

    results =
      Enum.map(to_grant, fn want ->
        cap = %{want | granted_at: DateTime.utc_now()}

        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: ctx
        })
      end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] -> :ok
      [err | _] -> {:error, {:scoped_cap_grant_failed, err}}
    end
  end

  @doc """
  Revoke the orchestrator's scope-bounded delegation caps — the exact
  cap set `grant_orchestrator_scoped_caps/3` adds.

  2026-05-31 orchestrator-startup-atomicity §4 step 9 (codex-review Q1)
  — the rollback inverse of the step-6 grant. Used by
  `EzagentDomainInstanceMessage.rollback_session/3` so a late create failure leaves
  NO scoped-cap residue on the orchestrator entity (in addition to the
  Kind teardown). Best-effort + idempotent: `:revoke_cap` matches by the
  cap identity-key (kind/behavior/instance/workspace_uri), so revoking
  an absent cap is a clean no-op. A dispatch failure is swallowed (the
  orchestrator Kind + its `:identity` snapshot are torn down anyway —
  this is belt-and-suspenders for the durable `caps_json` projection).

  `workspace_uri` is taken explicitly (not via `WorkspaceRegistry`)
  because the binding may already have been unbound by the time rollback
  reaches this step.
  """
  @spec revoke_orchestrator_scoped_caps(URI.t(), URI.t(), URI.t(), URI.t()) :: :ok
  def revoke_orchestrator_scoped_caps(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    desired = build_desired_caps(orchestrator_uri, session_uri, owner_uri, workspace_uri)
    target = Ezagent.URI.with_action(orchestrator_uri, :identity, :revoke_cap)

    ctx = %{
      caller: owner_uri,
      caps:
        "template-materialize" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
      reply: :ignore
    }

    Enum.each(desired, fn cap ->
      _ =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: ctx
        })
    end)

    :ok
  end

  defp build_desired_caps(
         %URI{} = orchestrator_uri,
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = session_workspace
       ) do
    # Cap #1 + #2 — unconditional scope-bounded delegation.
    # SPEC 2026-05-27 capability-action-axis — orchestrator delegation
    # is intentionally broad within the bounded scope (within-session
    # for Cap #1, spawned-by for Cap #2). `action: :any` matches the
    # `behavior: :any` axis — symmetric wildcard. The bound is the
    # instance scope tuple, not the action narrowing.
    unconditional = [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: {:within_session, session_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      },
      %Ezagent.Capability{
        kind: :agent,
        behavior: :any,
        action: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    ]

    # Caps #3/#4 — gated by owner-cap preflight (§1.4).
    template_caps = delegable_template_caps(owner_uri, session_workspace)

    unconditional ++ template_caps
  end

  @doc """
  PR-A helper (SPEC §5, codex rev-2 HIGH-1) — logical-equality
  predicate for capabilities, IGNORING `granted_at` (a per-dispatch
  timestamp).

  The IDENTITY of a cap is `{kind, behavior, instance, workspace_uri,
  granted_by}` — the authority being granted + WHO granted it. The
  WHEN is metadata; the same authority granted twice should be a
  no-op, NOT two distinct rows in the cap MapSet (which would burden
  the audit log + grow the User snapshot on every reconciler re-run).
  """
  @spec cap_equal_ignoring_metadata?(Ezagent.Capability.t(), Ezagent.Capability.t()) ::
          boolean()
  def cap_equal_ignoring_metadata?(%Ezagent.Capability{} = a, %Ezagent.Capability{} = b) do
    # SPEC 2026-05-27 capability-action-axis — include action axis in
    # logical equality via `action_of/1` for snapshot-restored
    # old-shape tolerance.
    a.kind == b.kind and
      a.behavior == b.behavior and
      Ezagent.Capability.action_of(a) == Ezagent.Capability.action_of(b) and
      a.instance == b.instance and
      a.workspace_uri == b.workspace_uri and
      a.granted_by == b.granted_by
  end

  # ─────────────────────────────────────────────────────────────────────
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
    Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      parent_template_uri: parent_template_uri
    )
  end

  @doc """
  Ensure the template Kind at `template_uri` is alive, spawning it (via
  `SpawnRegistry`) if the `KindRegistry` lookup misses. Returns
  `{:ok, pid}` | `{:error, reason}`.

  2026-05-31 orchestrator-startup-atomicity §4 — kept + made public so
  `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can demand-spawn a SessionTemplate
  Kind it resolved via the snapshot store before reading its content.
  """
  @spec ensure_template_alive(URI.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Ezagent.SpawnRegistry.spawn(template_uri) do
          {:ok, _} = ok -> ok
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

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
  # Owner-cap preflight for caps #3 and #4  (KEPT verbatim — round-1 §1.4)
  # ─────────────────────────────────────────────────────────────────────

  defp delegable_template_caps(%URI{} = owner_uri, %URI{} = session_workspace) do
    owner_caps = Ezagent.Identity.list_caps_for(owner_uri)

    workspace_name = Ezagent.URI.workspace_name!(session_workspace)

    candidates = [
      {:session_template, Ezagent.URI.template(workspace_name, :session, "_preflight@_")},
      {:agent_template, Ezagent.URI.template(workspace_name, :agent, :_preflight)}
    ]

    candidates
    |> Enum.filter(fn {kind, representative_uri} ->
      needed = %{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        # SPEC 2026-05-27 capability-action-axis — orchestrator
        # template delegation spans `:read`, `:write`, `:instantiate`,
        # `:fork` (Tools.update_agent_template + save_template_as +
        # fork + Generator instantiate). Bound by instance scope
        # `:within_workspace`; action axis stays `:any` so orchestrator
        # tooling works without one cap per action.
        action: :any,
        instance: representative_uri,
        workspace_uri: session_workspace
      }

      Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1, needed))
    end)
    |> Enum.map(fn {kind, _representative_uri} ->
      %Ezagent.Capability{
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        action: :any,
        instance: {:within_workspace, session_workspace},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: nil
      }
    end)
  end
end
