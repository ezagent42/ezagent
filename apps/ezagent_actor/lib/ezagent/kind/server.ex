defmodule Ezagent.Kind.Server do
  @moduledoc """
  Shared GenServer that hosts every Kind instance.

  Per DECISIONS P1-D2 / Decision #84 (path B in ARCHITECTURE.md §5.7.4),
  Phase 1 uses **one** GenServer module for all Kinds. Each instance is
  parameterised by its `{kind_module, args}` pair at `start_link/1`.
  Plugin authors cannot bypass the register → subscribe → announce_ready
  lifecycle because they never write `init/1` themselves — this module
  is the only `def init/1` in the codebase (invariant #2).

  ## State shape

  ```
  %{
    kind: module(),                # the Kind module (e.g. Ezagent.Entity.Agent)
    uri:  URI.t(),                 # this instance's URI
    state: %{atom() => map()},     # per-Behavior slices, keyed by behavior.state_slice()
    authority: term(),                 # OPAQUE AuthorityPort token (§3.4); framework-private; never snapshotted
    post_init_queue: [{module(), term()}] # PR-EM-CORE: pending post-init continuations
                                          # populated by init/1, drained by chained
                                          # handle_continue/2 after :announce_ready
  }
  ```

  ## Lifecycle (Appendix A precondition)

  1. `init/1`:
     - build initial per-Behavior slices via `init_slice/1`
     - call optional `post_init/2` on each Behavior (collects
       continuation terms in `behaviors/0` declaration order)
     - put_new into `KindRegistry` (crash on duplicate)
     - mark `:not_ready` in `ReadyGate`
     - hand off to `handle_continue(:announce_ready, ...)`
  2. `handle_continue(:announce_ready, ...)`:
     - when no Behavior declared `post_init/2`: mark `:ready` in
       `ReadyGate` + flush buffered `:cast` invocations via
       `PendingDelivery.flush` — identical to pre-PR-EM-CORE
       behaviour
     - when at least one Behavior queued a post-init continuation:
       defer BOTH the mark_ready + the flush; chain
       `{:continue, {:ezagent_post_init, queue}}`. ReadyGate stays
       `:not_ready` through the entire post-init phase (codex
       round-2 HIGH-1 fix — otherwise external dispatches arriving
       between mark_ready and the end of post-init would bypass
       PendingDelivery and die with the process on a crashing
       post-init handler)
  3. `handle_continue({:ezagent_post_init, [{behavior, term} | rest]}, ...)`:
     - invoke the Behavior's optional `handle_continue/3` callback
       with `{term, slice, ctx}`; merge `{:ok, new_slice}` back into
       `state.state[state_slice()]` via `Ezagent.Kind.Snapshot.commit/4`
       (codex round-1 MEDIUM-1 fix — without this a
       `{:snapshot, :on_change}` Kind silently loses post-init slice
       mutations on restart)
     - chain to the next queued Behavior continuation; on the LAST
       entry mark `:ready` in `ReadyGate` AND drain
       `PendingDelivery` (both deferred from step 2 per round-2
       HIGH-1 fix)
     - boot-order invariant: the URI is registered + post-init
       complete BEFORE `:ready` is published; subscribers /
       dispatchers see a fully-initialised Kind. Post-init
       `handle_continue/3` callbacks can call OUT to other Kinds
       (which gates ReadyGate on the target, not on self) but
       cannot dispatch back into themselves (self is still
       `:not_ready`; the dispatch would buffer via PendingDelivery
       and run AFTER post-init completes — which is the documented
       contract)
  4. `handle_call(:ezagent_dispatch, ...)` / `handle_cast(:ezagent_dispatch, ...)`:
     - delegate to `Ezagent.Kind.Runtime.handle_dispatch/3` which runs
       Appendix A steps 5-10 (BehaviorRegistry → authz stub → invoke →
       slice update → telemetry)

  ## Post-init continuation hook (PR-EM-CORE)

  The `post_init/2` + `handle_continue/3` callbacks on
  `Ezagent.ActionSet` let a Behavior schedule deferred work that runs
  after `:announce_ready`. See `Ezagent.ActionSet` moduledoc + the
  ExternalMirror SPEC (`docs/superpowers/specs/2026-05-24-external-mirror-domain.md`)
  §6.1 split-init pattern for the canonical use case (Worker Kind
  subscribes to a Session Publisher AFTER `Kind.spawn/2` returns,
  avoiding a synchronous-init deadlock).

  ## Why `:trap_exit`

  Borrowed from old esr `Ezagent.Entity.Server` (SPEC borrow #4): we want
  graceful `terminate/2` so the GenServer can emit a final telemetry
  event before going down. Phase 4-completion PR 2 wired
  snapshot-on-shutdown for Kinds declaring `:on_terminate` persistence.
  """

  use GenServer

  @doc """
  Start a Kind instance for `{kind_module, args}`.

  `args` MUST include `:uri` (the instance URI). Other keys are
  forwarded to each Behavior's `init_slice/1`.
  """
  @spec start_link({module(), map()}) :: GenServer.on_start()
  def start_link({kind_module, args}) when is_atom(kind_module) and is_map(args) do
    GenServer.start_link(__MODULE__, {kind_module, args})
  end

  @impl true
  def init({kind_module, args}) do
    Process.flag(:trap_exit, true)

    uri = Map.fetch!(args, :uri)
    uri_str = URI.to_string(uri)
    create_freshness = create_freshness(kind_module, uri)
    # #201 PR-1 — publish the verdict BEFORE any later init step can fail and
    # BEFORE the initial persist writes the `ever_created` marker, so the
    # atomic spawn winner reads THIS incarnation's verdict back from the
    # spawning process (no GenServer.call queued behind post_init/activate).
    :ok = Ezagent.Kind.CreateFreshness.record(uri_str, create_freshness)
    args = Map.put(args, :create_freshness, create_freshness)

    # main's before-start hook: `LaunchContextInit.prepare` may transform
    # `args` and yields a `launch_context_relay` threaded through init and
    # discarded on terminate. It runs BEFORE the authority open + snapshot load.
    with {:ok, args, launch_context_relay} <-
           Ezagent.Kind.LaunchContextInit.prepare(kind_module, args) do
      init_after_before_start(
        kind_module,
        args,
        uri,
        uri_str,
        create_freshness,
        launch_context_relay
      )
    else
      {:error, :launch_context_lost} -> {:stop, :launch_context_lost}
      {:error, reason} -> {:stop, {:before_start_failed, reason}}
    end
  end

  defp init_after_before_start(
         kind_module,
         args,
         uri,
         uri_str,
         create_freshness,
         launch_context_relay
       ) do
    # #195: open the per-Kind signing authority (generation-aware, 3-arg) and
    # run the snapshot load UNDER that authority so cap verification during load
    # sees the current signer.
    authority_result =
      authority().open(uri, kind_module.type_name(), create_freshness)

    snapshot_result =
      case authority_result do
        {:ok, authority} ->
          authority().with_authority(authority, fn ->
            Ezagent.Kind.Snapshot.safe_load_or_init(uri, kind_module, args)
          end)

        {:error, reason} ->
          {:authority_error, reason}
      end

    # #108 — the snapshot READ is a DB access too; `Snapshot.safe_load_or_init/3`
    # surfaces sandbox-owner-death (OwnershipError/:exit) as a clean `{:stop,…}`
    # instead of an uncaught init crash, symmetric with the WRITE
    # (`persist_initial_snapshot/3`). let-it-crash, no fresh-state fallback.
    case snapshot_result do
      {:authority_error, reason} ->
        {:stop, {:authority_load_failed, reason}}

      {:error, reason} ->
        {:stop, {:snapshot_load_failed, reason}}

      {:ok, slice_state} ->
        with {:ok, authority} <- authority_result do
          # PR-EM-CORE: collect post_init/2 continuations in behaviors/0
          # declaration order. `post_init/2` is OPTIONAL — Behaviors that
          # don't export it (or return `:ok`) contribute nothing to the
          # queue. The handle_continue/3 calls run AFTER :announce_ready.
          post_init_queue = collect_post_init_queue(kind_module, args, slice_state)

          state = %{
            kind: kind_module,
            uri: uri,
            state: slice_state,
            authority: authority,
            launch_context_relay: launch_context_relay,
            post_init_queue: post_init_queue,
            # #533 5a (§3.10.3) — the authenticated creator, threaded as a
            # create-arg exactly like Session's `owner_uri`. `nil` on rehydrate
            # or when no creator is supplied. PR-5c reads this to grant the
            # manage-cap to the right principal.
            created_by: Map.get(args, :created_by),
            # #533 5a (§3.10.3) — freshness comes from the Lifecycle's own
            # create-vs-activate decision (`create_freshness/2`, gated on Kind
            # METADATA `hosts_lifecycle?/1` — NOT the slice shape, which a cold
            # rehydrate can lack `:transients` on and mis-classify; codex review
            # P2). Computed in `init/1` BEFORE the authority open so the
            # create/activate concept has one definition and can't drift.
            create_freshness: create_freshness
          }

          case Ezagent.Kind.ReadyTransition.register_not_ready(uri_str, self()) do
            :ok ->
              case persist_initial_snapshot(uri, kind_module, slice_state) do
                :ok ->
                  schedule_periodic_snapshot(kind_module)
                  {:ok, state, {:continue, :announce_ready}}

                {:error, reason} ->
                  # Persistence is a durability promise. Registration is already
                  # visible, so fail and detach any pending delivery before exit.
                  :ok = Ezagent.Kind.ReadyTransition.mark_failed(uri_str)
                  {:stop, {:persistence_failed, reason}}
              end

            {:error, {:already_registered, _other_pid}} ->
              # Let-it-crash — duplicate spawn is a bug at the caller layer.
              {:stop, {:already_registered, uri_str}}
          end
        else
          {:error, reason} -> {:stop, {:authority_load_failed, reason}}
        end
    end
  end

  defp create_freshness(kind_module, uri) do
    if Ezagent.Lifecycle.hosts_lifecycle?(kind_module) do
      if Ezagent.Lifecycle.fresh_create?(uri), do: :created, else: :existed
    else
      :unknown
    end
  end

  # Issue #342 r1 (Allen 2026-05-25 — let-it-crash). Previously this
  # function discarded the result of `save_now/3` because save_now
  # itself silently returned `:ok` on DB error. With save_now now
  # strict (rescue removed in #342), an initial-snapshot failure
  # propagates here, which propagates to `init/1`, which returns
  # `{:stop, {:persistence_failed, reason}}` — so a spawn that can't
  # durably persist reports the failure to its caller (mix task /
  # Workspace.create_agent / LV) instead of leaving a Kind in
  # memory-only mode that disappears on restart.
  defp persist_initial_snapshot(uri, kind_module, slice_state) do
    case Ezagent.Kind.persistence_of(kind_module) do
      :ephemeral ->
        :ok

      :external ->
        :ok

      _ ->
        # Lifecycle Phase A (SPEC §9 OQ-1, F3) — when this Kind hosts a
        # Lifecycle (two-container) slice, the `ever_created` marker is
        # written in the SAME upsert as the initial state binary
        # (`save_now/4` with `mark_ever_created: true`), so the marker is
        # ATOMIC with the snapshot it gates. There is no separate
        # fire-and-forget marker write that a crash between save + mark
        # could skip, re-running `create` on the next boot. Per
        # let-it-crash, a failed atomic write propagates to `{:stop, ...}`
        # below — the same durability promise as the state itself.
        save_opts =
          if hosts_lifecycle_slice?(slice_state),
            do: [mark_ever_created: true],
            else: []

        # save_now/4 may raise (infra exceptions) OR exit (linked DB
        # connection process death — observed in the ExUnit sandbox
        # when the test owner has exited before the Kind init runs).
        # Catch BOTH at this boundary so init/1 can return
        # `{:stop, ...}` cleanly rather than have the failure abort
        # the GenServer with an opaque `:EXIT` tuple.
        try do
          Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state, save_opts)
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
    end
  end

  # Lifecycle Phase A (SPEC §9 OQ-1) — structural detection (a slice
  # carrying a `:transients` sub-key), no Behavior coupling. A Kind with
  # any Lifecycle slice gets the atomic ever-created marker on its initial
  # persist.
  defp hosts_lifecycle_slice?(slice_state) do
    Enum.any?(slice_state, fn {_key, slice} ->
      is_map(slice) and Map.has_key?(slice, :transients)
    end)
  end

  # PR-EM-CORE: walk each Behavior, call its optional post_init/2 with
  # (args, behavior's own slice), and collect `{behavior, term}` entries
  # for any that returned `{:continue, term}`. Behaviors that don't
  # export `post_init/2` or that returned `:ok` are skipped. Order is
  # `kind_module.behaviors/0` (declaration order) — deterministic.
  defp collect_post_init_queue(kind_module, args, slice_state) do
    # P1 (SPEC §3.1, E1) — enumerate the INSTANCE effective set, not the module
    # superset, so an out-of-set behavior's post_init/activate never queues.
    Ezagent.Kind.BehaviorSet.materialized_set(kind_module, slice_state)
    |> Enum.reduce([], fn behavior, acc ->
      if function_exported?(behavior, :post_init, 2) do
        slice = Map.get(slice_state, behavior.state_slice(), %{})

        case behavior.post_init(args, slice) do
          :ok -> acc
          {:continue, term} -> [{behavior, term} | acc]
        end
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp schedule_periodic_snapshot(kind_module) do
    case Ezagent.Kind.persistence_of(kind_module) do
      {:snapshot, :periodic, ms} when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :snapshot_tick, ms)
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def handle_continue(:announce_ready, %{uri: uri, post_init_queue: queue} = state) do
    uri_str = URI.to_string(uri)

    # PR-EM-CORE codex round-2 HIGH-1 fix: defer BOTH ReadyGate mark +
    # PendingDelivery flush until AFTER post-init completes. Round-1
    # only deferred the flush, but marked `:ready` here — that opened
    # a NEW loss window: external `dispatch/1` calls arriving between
    # mark_ready and the end of post-init see `:ready`, send their
    # cast directly to this GenServer's mailbox (bypassing
    # PendingDelivery), and would be lost with the process if a later
    # post-init `handle_continue/3` raised.
    #
    # The fix: stay `:not_ready` through the entire post-init phase.
    # External casts arriving during post-init buffer to
    # PendingDelivery (the standard not-ready path); external calls
    # fail-fast (existing invariant #3). Then mark_ready + flush
    # together on the LAST post-init continuation. On crash, ReadyGate
    # stays `:not_ready`, buffer stays intact, supervisor restart
    # re-runs init → post-init → mark_ready.
    #
    # Pre-PR behaviour for Kinds with no post-init Behaviors is still
    # preserved exactly: empty queue → drain + mark_ready right here
    # (the drain-then-mark order is the round-3 HIGH-1 fix, see the
    # post-init clause below).
    case queue do
      [] ->
        if Ezagent.Kind.ReadyTransition.drain_then_mark_ready(uri_str, self()) == :ready do
          # Task #49 — invoke on_ready hooks AFTER ReadyGate flip.
          authority().with_authority(state.authority, fn ->
            run_on_ready_hooks(state.kind, uri, state.state)
          end)
        end

        {:noreply, state}

      _ ->
        {:noreply, state, {:continue, {:ezagent_post_init, queue}}}
    end
  end

  # PR-EM-CORE: process the head of the post-init queue. Each entry is
  # `{behavior_module, term}` where `term` is the value the Behavior
  # returned from `post_init/2`. We invoke the Behavior's optional
  # `handle_continue/3` callback with `{term, slice, ctx}`, merge
  # `{:ok, new_slice}` back via the same snapshot-commit path used by
  # dispatch (codex round-1 MEDIUM-1 fix — `:snapshot, :on_change`
  # Kinds otherwise lost post-init slice mutations on restart), then
  # chain to the next entry. ReadyGate stays `:not_ready` during this
  # phase (round-2 HIGH-1 fix); it flips to `:ready` only after the
  # LAST entry, at which point we ALSO drain `PendingDelivery`.
  #
  # If `handle_continue/3` is not exported, we log + skip — the
  # Behavior returned `{:continue, _}` from `post_init/2` but did not
  # implement the receiver. Treating this as a programmer error and
  # logging (rather than crashing) keeps a buggy Behavior from taking
  # down its host Kind on init; the Behavior author still sees the
  # warning in test runs.
  def handle_continue({:ezagent_post_init, [{behavior, term} | rest]}, state) do
    %{kind: kind_module, uri: self_uri, state: slice_state, authority: authority} = state

    new_slice_state =
      run_post_init_continuation(
        behavior,
        term,
        slice_state,
        kind_module,
        self_uri,
        authority
      )

    commit_post_init(state, new_slice_state)
    new_state = %{state | state: new_slice_state}

    case rest do
      [] ->
        # All post-init continuations succeeded — drain any messages
        # buffered during the entire register→post-init-complete
        # window AND publish `:ready` atomically with respect to
        # incoming dispatchers. The drain-then-mark order is the
        # round-3 HIGH-1 fix (otherwise external `dispatch/1` calls
        # arriving between mark_ready and the self-cast loop could
        # overtake older buffered entries in the GenServer mailbox,
        # breaking per-target FIFO).
        if Ezagent.Kind.ReadyTransition.drain_then_mark_ready(URI.to_string(self_uri), self()) ==
             :ready do
          # Task #49 — invoke on_ready hooks AFTER ReadyGate flip.
          # Uses the post-init mutated slice state.
          authority().with_authority(new_state.authority, fn ->
            run_on_ready_hooks(new_state.kind, self_uri, new_state.state)
          end)
        end

        {:noreply, new_state}

      _ ->
        {:noreply, new_state, {:continue, {:ezagent_post_init, rest}}}
    end
  end

  defp run_post_init_continuation(
         behavior,
         term,
         slice_state,
         kind_module,
         self_uri,
         authority
       ) do
    authority().with_authority(authority, fn ->
      if function_exported?(behavior, :handle_continue, 3) do
        slice_key = behavior.state_slice()
        slice = Map.get(slice_state, slice_key, %{})
        ctx = %{kind_module: kind_module, self_uri: self_uri}

        case behavior.handle_continue(term, slice, ctx) do
          {:ok, new_slice} -> Map.put(slice_state, slice_key, new_slice)
          :ignore -> slice_state
        end
      else
        require Logger

        Logger.warning(
          "Ezagent.Kind.Server: Behavior #{inspect(behavior)} returned " <>
            "{:continue, #{inspect(term)}} from post_init/2 but does not " <>
            "export handle_continue/3; dropping continuation. URI=#{URI.to_string(self_uri)}"
        )

        slice_state
      end
    end)
  end

  # PR-EM-CORE codex round-1 MEDIUM-1 fix: route post-init slice
  # mutations through the same snapshot commit path used by dispatch
  # (`commit_and_notify/3` calls this same `Snapshot.commit/4`).
  # Without this, a `{:snapshot, :on_change}` Kind whose post-init
  # `handle_continue/3` returns `{:ok, new_slice}` keeps that slice
  # in memory only — a restart before the next dispatch silently
  # drops the post-init mutation.
  #
  # We deliberately skip `SliceChange.emit/1` here: post-init is the
  # tail of the init phase, not a user-initiated mutation. Subscribers
  # would see a confusing "the slice changed from X to Y" event for
  # an entity that JUST became `:ready` — semantically the slice has
  # always been Y from any observer's perspective. (Dispatch path
  # emits SliceChange; init path does not.)
  defp commit_post_init(%{state: old_slice_state}, new_slice_state)
       when old_slice_state == new_slice_state do
    # `:ignore` from handle_continue/3 leaves slice_state unchanged —
    # skip the commit entirely (Snapshot.commit/4 would return
    # `:not_durable` for an unchanged on_change Kind anyway, but this
    # is the explicit fast path).
    :ok
  end

  defp commit_post_init(%{uri: uri, kind: kind_module, state: old_slice_state}, new_slice_state) do
    # Issue #342 (Allen 2026-05-25): post-init is best-effort by
    # design — propagating a transient DB error here would restart
    # the Kind in its pre-mutation state, only to fail post-init
    # again on restart (boot-loop on persistent DB failure). The
    # dispatch path enforces durability strictly; post-init's slice
    # mutation will be re-asserted by the next user-initiated
    # dispatch that touches it. Wrap save_now's strict raise at this
    # boundary so the handle_continue continues cleanly.
    try do
      _ = Ezagent.Kind.Snapshot.commit(uri, kind_module, old_slice_state, new_slice_state)
    rescue
      e ->
        require Logger

        Logger.warning(
          "Ezagent.Kind.Server.commit_post_init: snapshot commit raised for " <>
            "#{inspect(uri)}: #{inspect(e)} — post-init mutation kept " <>
            "in-memory; will re-assert on next dispatch"
        )
    catch
      :exit, reason ->
        require Logger

        Logger.warning(
          "Ezagent.Kind.Server.commit_post_init: snapshot commit exited for " <>
            "#{inspect(uri)}: #{inspect(reason)} — post-init mutation kept " <>
            "in-memory; will re-assert on next dispatch"
        )
    end

    :ok
  end

  # PR-EM-CORE codex round-3 HIGH-1 fix: ensure per-target FIFO across
  # the not-ready → ready transition. The naive "mark_ready then
  # flush" order (rounds 1+2) lets a concurrent external dispatch
  # observe `:ready` and `GenServer.cast` directly into our mailbox
  # AHEAD of the self-casts we issue for the older buffered entries —
  # breaking FIFO for non-commutative actions.
  #
  # Drain order:
  # 1. Flush PendingDelivery → self-cast each buffered entry into our
  #    own mailbox. While ReadyGate is still `:not_ready`, concurrent
  #    dispatchers buffer (so no external direct-cast can race ahead
  #    in our mailbox).
  # 2. Loop: if more entries arrived in PendingDelivery during step 1
  #    (because dispatchers kept buffering), repeat step 1. Terminates
  #    when the buffer is empty.
  # 3. Mark ready ONLY when the buffer is empty AND all buffered
  #    entries are already enqueued in our mailbox. From this point
  #    external direct-casts go to the END of our mailbox, AFTER the
  #    older self-casts. FIFO preserved.
  #
  # Bounded iteration: a buggy / hostile dispatcher producing entries
  # faster than we can self-cast could theoretically loop forever.
  # Kind init is not the hot dispatch path so this is acceptable for
  # v1; if production data shows unbounded loops, switch to a
  # `:draining` ReadyGate state with a hand-off semaphore.
  # Task #49 (2026-05-27) — codex round-1 FAIL #6 fix.
  #
  # Run each Behavior's optional `on_ready/2` callback AFTER ReadyGate
  # has flipped to `:ready` and the PendingDelivery buffer has been
  # drained. Used by Behaviors that need to fire a lifecycle broadcast
  # whose subscribers may dispatch BACK into this Kind synchronously
  # (e.g. `Behavior.Publisher.SessionImpl.on_ready/2` broadcasts
  # `:publisher_alive`; subscribed ExternalMirrorWorkers re-run
  # `subscribe_to_session_publisher/2` which is a `:call` mode
  # dispatch that would otherwise hit `{:error, :not_ready}` if the
  # broadcast had fired from `handle_continue/3` BEFORE mark_ready).
  #
  # Best-effort: a raise/throw/exit inside any one Behavior's
  # `on_ready/2` is logged + isolated; we do NOT un-flip ReadyGate
  # (an external observer may have already seen `:ready` and routed
  # through). The Kind stays `:ready`; siblings still run.
  #
  # The implementation lives in `Ezagent.Kind.MountDetach.run_on_ready_all/3`
  # (RF-2 extraction — shared with mount's single-behavior path; keeps
  # server.ex under the oversized-module gate).
  defp run_on_ready_hooks(kind_module, self_uri, slice_state) do
    Ezagent.Kind.MountDetach.run_on_ready_all(kind_module, self_uri, slice_state)
  end

  # codex round-10 HIGH — `Ezagent.Kind.terminate/1` needs the Kind
  # module of a LIVE process to resolve its owning `DynamicSupervisor`
  # (`kind_module.supervisor/0`). The caller (a Tier-3 plugin Template
  # Class undoing its own partial spawn) only has the URI / pid — it
  # must NOT name a Tier-2 supervisor constant. This synchronous query
  # lets a Tier-1 helper resolve the supervisor without that coupling.
  @impl true
  def handle_call(:ezagent_kind_module, _from, %{kind: kind_module} = state) do
    {:reply, {:ok, kind_module}, state}
  end

  def handle_call(
        {:ezagent_validate_cap_artifact, artifact, receiver},
        _from,
        state
      ) do
    result =
      authority().with_authority(state.authority, fn ->
        authority().validate_artifact(artifact, receiver)
      end)

    {:reply, result, state}
  end

  def handle_call(:ezagent_runtime_view, _from, state) do
    view = Map.take(state, [:kind, :uri, :state])
    {:reply, {:ok, view}, state}
  end

  # SPEC 2026-07-23 §2.2 — the action-subject resolution op. Runs the
  # behavior-set resolution INSIDE the actor and returns ONLY the two module
  # atoms `{kind_module, behavior_module}` — never the slice map. The
  # purpose-specific replacement for `Ezagent.Cap.action_context/3`'s raw
  # `:ezagent_runtime_view` reach-through (§2.3): the slice state never leaves
  # the process, so publishing this op does not make arbitrary state reach-in
  # gate-legal. Additive (C0) — existing `:ezagent_runtime_view` unchanged.
  def handle_call(
        {:ezagent_resolve_action_subject, action},
        _from,
        %{kind: kind_module, state: slice_state} = state
      )
      when is_atom(action) do
    result =
      case Ezagent.Kind.BehaviorSet.resolve_action(kind_module, action, slice_state) do
        {:ok, behavior_module} -> {:ok, {kind_module, behavior_module}}
        {:error, _reason} = error -> error
      end

    {:reply, result, state}
  end

  # G-6: expose only the non-secret proof needed by bearer recredentialing.
  # A generation-N token may rotate solely from a live Kind whose lifecycle
  # classified this boot as a genuine create/reprovision. Cold rehydrate and
  # an old process left behind by a standalone generation bump both fail.
  def handle_call(
        :ezagent_recredential_generation,
        _from,
        # C5 §3.4 opacity rule (codex fidelity fix) — the authority token is
        # OPAQUE: gate on `create_freshness` ONLY, then read the generation
        # via the port accessor (`authority().generation/1`). NEVER a
        # `%{generation: _}` map match — a conforming adapter may return a
        # non-map token, which the old match would have dropped into the
        # `:principal_revoked` fall-through, wrongly denying bridge
        # recredentialing.
        %{create_freshness: :created, authority: token} = state
      ) do
    # Fail-closed: an adapter whose accessor raises (e.g. a token without a
    # generation reading) gets the old match-fall-through semantics
    # (`:principal_revoked`), not a GenServer crash.
    generation =
      try do
        authority().generation(token)
      rescue
        _ -> nil
      end

    if is_integer(generation) and generation > 0 do
      {:reply, {:ok, generation}, state}
    else
      {:reply, {:error, :principal_revoked}, state}
    end
  end

  def handle_call(:ezagent_recredential_generation, _from, state) do
    {:reply, {:error, :principal_revoked}, state}
  end

  def handle_call(:ezagent_launch_context_relay, _from, state) do
    {:reply, Map.get(state, :launch_context_relay), state}
  end

  # PR-OWN-2 (caps-data-ownership SPEC #306 §7) — read a single
  # Behavior slice. Used by `Ezagent.Kind.get_slice/2` for cross-
  # process lookups (e.g. `Session.owner/1` resolves session.owner_uri
  # so `Behavior.Session.data_owner/1` can return a real URI).
  def handle_call({:ezagent_get_slice, slice_key}, _from, %{state: slice_state} = state)
      when is_atom(slice_key) do
    {:reply, {:ok, Map.get(slice_state, slice_key)}, state}
  end

  # Lifecycle Phase A (SPEC §2 destroy path, F4) — drain each Lifecycle
  # Behavior's `destroy/2` cleanup hook BEFORE the framework clears
  # durable state. Invoked synchronously by `Ezagent.Lifecycle.destroy/2`
  # so the hook runs IN this Kind's process (reading its own slice) while
  # the entity is still live. This is the destroy-vs-deactivate signal:
  # a graceful stop reaches OTP `terminate/3` (→ `deactivate`); a
  # permanent deletion reaches HERE (→ `destroy`).
  #
  # Per-Behavior isolated (try/rescue) so one buggy hook doesn't block
  # the others or the caller's durable delete. The slice is NOT mutated —
  # the row is about to be deleted regardless.
  def handle_call({:ezagent_lifecycle_destroy, reason}, _from, state) do
    %{kind: kind_module, uri: self_uri, state: slice_state} = state
    ctx = %{kind_module: kind_module, self_uri: self_uri}

    # P1 (SPEC §3.1, E3) — only the INSTANCE effective set runs destroy.
    Enum.each(Ezagent.Kind.BehaviorSet.materialized_set(kind_module, slice_state), fn behavior ->
      if function_exported?(behavior, :__ezagent_lifecycle_destroy__, 3) do
        slice = Map.get(slice_state, behavior.state_slice(), %{})

        try do
          _ = behavior.__ezagent_lifecycle_destroy__(reason, slice, ctx)
        rescue
          err ->
            require Logger

            Logger.warning(
              "Ezagent.Kind.Server: Behavior #{inspect(behavior)} destroy/2 raised " <>
                "(#{inspect(err)}). Continuing destroy of remaining behaviors. " <>
                "URI=#{URI.to_string(self_uri)}"
            )
        catch
          kind, value ->
            require Logger

            Logger.warning(
              "Ezagent.Kind.Server: Behavior #{inspect(behavior)} destroy/2 threw " <>
                "#{inspect({kind, value})}. Continuing destroy of remaining behaviors. " <>
                "URI=#{URI.to_string(self_uri)}"
            )
        end
      end
    end)

    :ok = authority().retire(self_uri)
    {:reply, :ok, state}
  end

  # RF-2/RF-3 — runtime mount/detach of a behavior on this LIVE instance. The
  # single GenServer mailbox serializes mount/detach/dispatch (an in-flight
  # dispatch can't interleave with the set mutation; deferred/saga to OTHER
  # Kinds is out of scope per spec). `MountDetach.mount/5`/`detach/4` validate
  # BEFORE any mutation, run the behavior's create+activate+activated (mount) /
  # on_detach (detach), and return the new slice state; `reply_after_set_change`
  # durably snapshots it (no SliceChange emit — structural reconfig, mirroring
  # commit_post_init).
  def handle_call({:ezagent_mount, behavior, args}, _from, state)
      when is_atom(behavior) and is_map(args) do
    %{kind: kind_module, uri: uri, state: slice_state} = state
    result = Ezagent.Kind.MountDetach.mount(slice_state, kind_module, behavior, args, uri)
    reply_after_set_change(result, state)
  end

  def handle_call({:ezagent_detach, behavior}, _from, state) when is_atom(behavior) do
    %{kind: kind_module, uri: uri, state: slice_state} = state
    result = Ezagent.Kind.MountDetach.detach(slice_state, kind_module, behavior, uri)
    reply_after_set_change(result, state)
  end

  def handle_call(
        # C5 §3.4 opacity rule — the artifact crosses as OPAQUE data (plain
        # binding, NEVER a `%Ezagent.Capability{}` struct match); the
        # AuthorityPort adapter validates the representation and answers
        # `false` for a non-Capability input.
        #
        # INTENTIONAL DELTA from the base handler (codex fidelity review,
        # C5 chunk-2): the base `:ezagent_verify_cap_artifact` clause
        # struct-matched `%Capability{}`, so a malformed internal call had
        # NO handler and crashed the Kind. The graceful `false` is a strict
        # improvement AND is unreachable on valid production paths: the sole
        # caller is `Ezagent.Cap.valid_for_target?/2` (`cap.ex`), whose head
        # already requires `%Capability{}` and whose non-cap fallback clause
        # answers `false` BEFORE any GenServer.call — so no conforming
        # caller can ever present a malformed artifact here. Keeping the
        # adapter's `false` (not restoring the strict match) because the
        # only reachable effect of the old strictness was a crash.
        {:ezagent_verify_cap_artifact, artifact, %URI{} = presenter},
        _from,
        state
      ) do
    valid? =
      authority().with_authority(state.authority, fn ->
        authority().verify_artifact(artifact, presenter)
      end)

    {:reply, valid?, state}
  end

  # Unified-revocation G-1 — serialize a target-wide generation bump in the
  # target's own mailbox. Authorization is cap-based inside `regenesis/3`; a
  # successful reply is published only after the durable active-row flip and
  # the private live authority swap have both completed.
  def handle_call({:ezagent_revoke_all_to, %{} = ctx}, _from, state) do
    case authority().regenesis(state.uri, state.kind.type_name(), ctx) do
      {:ok, new_authority} ->
        # The authority token is OPAQUE (§3.4) — the generation field read
        # happens in the core adapter.
        {:reply, {:ok, authority().generation(new_authority)},
         %{state | authority: new_authority}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, _from, state) do
    dispatch_result =
      authority().with_authority(state.authority, fn ->
        Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri)
      end)

    case dispatch_result do
      {:ok, new_slice_state, result, slice_change_event, deferred} ->
        case commit_and_notify(state, new_slice_state, slice_change_event) do
          commit_ok when commit_ok in [:ok, :not_durable] ->
            mark_cap_delivery_applied(inv)

            # P2.5c — the parent slice durably committed (or by-design has no
            # durability promise). NOW run the deferred post-commit
            # dispatches. They are already ref-substituted + enriched
            # (caller=self_uri) by Runtime.Effects.execute_buckets.
            Ezagent.Kind.DeferredDispatch.enqueue(deferred)
            reply = if is_nil(result), do: :ok, else: {:ok, result}
            {:reply, reply, %{state | state: new_slice_state}}

          {:error, reason} ->
            # Issue #342 (Allen 2026-05-25 — let-it-crash). The action
            # body produced a new slice but the durable write failed
            # (`commit_and_notify/3` already suppressed the
            # `SliceChange` emit + logged + emitted `:failed`
            # telemetry). Returning `{:ok, result}` here would lie to
            # the dispatch caller (LV / mix task / cross-Kind dispatcher)
            # — they would broadcast a "succeeded" state that won't
            # survive restart. Keep the in-memory slice un-advanced
            # and propagate the persistence error.
            delivery_reason = {:persistence_failed, reason}
            record_cap_delivery_failure(inv, delivery_reason)
            {:reply, {:error, delivery_reason}, state}
        end

      {:error, reason} = err ->
        record_cap_delivery_failure(inv, reason)
        {:reply, err, state}
    end
  end

  @impl true
  def handle_cast({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, state) do
    dispatch_result =
      authority().with_authority(state.authority, fn ->
        Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri)
      end)

    case dispatch_result do
      {:ok, new_slice_state, result, slice_change_event, deferred} ->
        case commit_and_notify(state, new_slice_state, slice_change_event) do
          commit_ok when commit_ok in [:ok, :not_durable] ->
            mark_cap_delivery_applied(inv)

            # P2.5c — run the deferred post-commit dispatches AFTER the
            # parent slice durably committed (before replying to the caller,
            # mirroring the handle_call ordering).
            Ezagent.Kind.DeferredDispatch.enqueue(deferred)
            # cast still replies via ctx.reply if set (e.g. caller_inbox).
            Ezagent.Invocation.reply(inv.ctx, {:ok, result})
            {:noreply, %{state | state: new_slice_state}}

          {:error, reason} ->
            # Issue #342 — durable write failed. Mirror the handle_call
            # branch: propagate the error to the caller, leave the
            # in-memory slice un-advanced.
            log_unobservable_cast_error(inv, {:persistence_failed, reason})
            delivery_reason = {:persistence_failed, reason}
            record_cap_delivery_failure(inv, delivery_reason)
            Ezagent.Invocation.reply(inv.ctx, {:error, delivery_reason})
            {:noreply, state}
        end

      {:error, reason} ->
        log_unobservable_cast_error(inv, reason)
        record_cap_delivery_failure(inv, reason)
        Ezagent.Invocation.reply(inv.ctx, {:error, reason})
        {:noreply, state}
    end
  end

  # P2.5c (codex impl HIGH r2) — a cast dispatch is fire-and-forget: its error
  # surfaces HERE in the target's `handle_cast`, AFTER `Router.dispatch` already
  # returned `:ok` to the (post-commit deferred) caller. When the cast carries
  # `reply: :ignore` (every `DeferredDispatch` Cmd, and Turn's own settlement
  # Cmds), `Invocation.reply/2` is a NO-OP — so without this log the failure is
  # invisible in-uptime. The durable side is still safe: the settlement record
  # stays `:pending` (the retry marker) and `Turn.activated/2` re-drives it on
  # restart. This closes the in-uptime OBSERVABILITY half; in-uptime no-restart
  # RETRY is P3's outbox-replay concern. Observable-reply casts (caller_inbox)
  # already see the error via `Invocation.reply`, so only log the `:ignore` case.
  defp log_unobservable_cast_error(%Ezagent.Invocation{ctx: ctx} = inv, reason) do
    if Map.get(ctx, :reply) == :ignore do
      require Logger

      Logger.error(
        "Kind.Server: fire-and-forget cast dispatch FAILED (no caller will see it) " <>
          "target=#{inspect(inv.target)} reason=#{inspect(reason)} — if this is a " <>
          "post-commit settlement the record stays :pending and Turn.activated/2 " <>
          "recovers it on restart"
      )
    end

    :ok
  end

  defp mark_cap_delivery_applied(%Ezagent.Invocation{ctx: %{cap_delivery_id: id}} = inv)
       when is_integer(id) do
    case outbox().mark_applied(id, inv) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.error(
          "Kind.Server: cap delivery handler committed but outbox mark_applied failed " <>
            "delivery_id=#{id} reason=#{inspect(reason)}; row remains pending for idempotent retry"
        )

        :ok
    end
  end

  defp mark_cap_delivery_applied(%Ezagent.Invocation{}), do: :ok

  # C5 §3.4 AuthorityPort — signing-authority calls go through the
  # config-resolved port, never the literal `Ezagent.Cap.Authority` spine;
  # the authority token is OPAQUE. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.AuthorityAdapter`.
  defp authority, do: Application.fetch_env!(:ezagent_actor, :authority)

  # C5 §3.4 OutboxPort — cap-delivery outbox calls go through the
  # config-resolved port, never the literal `Ezagent.Cap.DeliveryOutbox`
  # spine. Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.OutboxAdapter`.
  defp outbox, do: Application.fetch_env!(:ezagent_actor, :outbox)

  defp record_cap_delivery_failure(%Ezagent.Invocation{} = inv, reason) do
    case outbox().record_handler_failure(inv, reason) do
      :ok ->
        :ok

      {:error, failure_reason} ->
        require Logger

        Logger.error(
          "Kind.Server: cap delivery failure state update failed " <>
            "reason=#{inspect(failure_reason)}; claim lease remains the retry backstop"
        )

        :ok
    end
  end

  # Commit-then-notify ordering (codex PR-N1 round-2 MEDIUM +
  # round-3 HIGH-1 fix + issue #342 propagation, Allen 2026-05-25):
  # 1. `Snapshot.commit/4` returns the STRICT outcome:
  #    `:ok` = durably persisted; `:not_durable` = policy doesn't
  #    require a durable write here (ephemeral / unchanged / periodic);
  #    `{:error, _}` = durable policy attempted + failed
  # 2. Emit ONLY on `:ok` or `:not_durable`:
  #    - `:ok` — slice survives restart, subscribers safe to act
  #    - `:not_durable` — by-design no durability promise (e.g. an
  #      `:ephemeral` Kind); in-memory slice IS the truth so notify is correct
  #    - `{:error, _}` — GenServer holds state that won't survive
  #      crash. Ghost-notify would tell LV "Alice → Bob" but a
  #      restart re-loads "Alice → Carol". Suppress emit (`commit/4` logged the `:failed` telemetry).
  # 3. Return the strict outcome (issue #342) so the dispatch
  #    reply path can propagate `{:error, {:persistence_failed, _}}`
  #    instead of falsely reporting success to the caller.
  @spec commit_and_notify(map(), %{atom() => map()}, any()) ::
          :ok | :not_durable | {:error, term()}
  # Shared mount/detach (RF-2/RF-3) reply: a no-op set (same slice) replies :ok;
  # a changed set is durably snapshotted (un-advanced + error-propagated on a
  # failed write, per let-it-crash — no half-persisted reconfig); a rejected
  # validation propagates {:error, reason} with zero residue.
  defp reply_after_set_change({:ok, same}, %{state: same} = state), do: {:reply, :ok, state}

  defp reply_after_set_change({:ok, new_slice_state}, state) do
    case commit_and_notify(state, new_slice_state, nil) do
      commit_ok when commit_ok in [:ok, :not_durable] ->
        {:reply, :ok, %{state | state: new_slice_state}}

      {:error, reason} ->
        {:reply, {:error, {:persistence_failed, reason}}, state}
    end
  end

  defp reply_after_set_change({:error, _reason} = err, state), do: {:reply, err, state}

  defp commit_and_notify(state, new_slice_state, slice_change_event) do
    commit_result =
      Ezagent.Kind.Snapshot.commit(state.uri, state.kind, state.state, new_slice_state)

    if slice_change_event && commit_result in [:ok, :not_durable] do
      maybe_dual_write_identity_caps(state, slice_change_event)
      Ezagent.SliceChange.emit(slice_change_event)
      # Membership-cap B.3 (spec §10/K3): cascade hook — enqueues a self-message.
      Ezagent.Kind.CascadeHook.maybe_enqueue(slice_change_event)
    end

    commit_result
  end

  # #189 PR-1 dual-write (identity-plane cutover step 1, ADDITIVE): every
  # committed `:identity` slice change is ALSO mirrored into the unified
  # identity-caps store (config-injected via `:ezagent_actor,
  # :identity_caps_store` — no compile-time reference from the actor layer
  # to the domain store). The domain store module decides what to skip
  # (user URIs mirror via `users.caps_json`; ephemeral/external Kinds are
  # not mirrored in PR-1) and never raises — the snapshot remains
  # authoritative until the atomic cutover.
  defp maybe_dual_write_identity_caps(state, %{slice_key: :identity, new_slice: new_slice}) do
    case Application.get_env(:ezagent_actor, :identity_caps_store) do
      nil ->
        :ok

      store ->
        if Code.ensure_loaded?(store) do
          store.sync_committed_identity(state.uri, state.kind, new_slice)
        else
          :ok
        end
    end
  end

  defp maybe_dual_write_identity_caps(_state, _slice_change_event), do: :ok

  # Behavior mailbox forwarding receives the raw message, its slice, and
  # `%{kind_module:, self_uri:}`; `:ignore` preserves that slice. Deferred
  # commands run on a later mailbox turn, after the parent commit, to avoid
  # dispatch deadlock. `DeferredDispatch` owns the detailed ordering contract.
  @impl true
  def handle_info({:ezagent_external_ready_gate, uri_str, :ok}, state)
      when is_binary(uri_str) do
    if Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(uri_str, self()) == :ready do
      run_on_ready_hooks(state.kind, state.uri, state.state)
    end

    {:noreply, state}
  end

  # The waiter already committed timeout/supersession generation-safely.
  def handle_info({:ezagent_external_ready_gate, uri_str, {:error, reason}}, state)
      when is_binary(uri_str) and reason in [:timeout, :superseded] do
    {:noreply, state}
  end

  def handle_info({:ezagent_run_deferred, cmds}, state) when is_list(cmds) do
    # A deferred self-dispatch runs on a later mailbox turn, outside the
    # handle_call/handle_cast authority scope above. Re-enter the same sealed
    # custody compartment so an exact K.grant issuance for canonical-admin
    # framework traffic can use this Kind's live signer. The key remains
    # process-local and the deferred command still traverses Router + verifier.
    authority().with_authority(state.authority, fn ->
      Ezagent.Kind.DeferredDispatch.run(cmds)
    end)

    {:noreply, state}
  end

  def handle_info(:snapshot_tick, %{kind: kind_module, uri: uri, state: slice_state} = wrapper) do
    # Phase 4-completion: periodic strategy — write via Writer (async)
    # then re-schedule. If Writer isn't running (e.g. test envs without
    # full sup tree), fall back to sync save_now to remain useful.
    case Ezagent.Kind.persistence_of(kind_module) do
      {:snapshot, :periodic, ms} ->
        if Process.whereis(Ezagent.Snapshot.Writer) do
          Ezagent.Snapshot.Writer.async_save(uri, kind_module, slice_state)
        else
          # Issue #342 — `save_now/3` is now strict (raises / returns
          # `{:error, _}`). This periodic-tick fallback is by-design
          # best-effort (it fires every N ms; one DB failure must not
          # crash the live Kind). Catch BOTH exceptions and linked
          # connection process exits at this boundary.
          try do
            _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end

        Process.send_after(self(), :snapshot_tick, ms)
        {:noreply, wrapper}

      _ ->
        {:noreply, wrapper}
    end
  end

  def handle_info(
        message,
        %{kind: kind_module, uri: self_uri, state: slice_state, authority: authority} = wrapper
      ) do
    # P1 (SPEC §3.1, E4) — only the INSTANCE effective set sees the mailbox
    # message, so an out-of-set behavior's handle_signal/handle_kind_message
    # never runs.
    new_slice_state =
      authority().with_authority(authority, fn ->
        Ezagent.Kind.BehaviorSet.materialized_set(kind_module, slice_state)
        |> Enum.reduce(slice_state, fn behavior, acc_state ->
          forward_to_behavior(behavior, message, acc_state, kind_module, self_uri)
        end)
      end)

    # ExternalMirror PR-EM-0 codex round-1 HIGH fix (2026-05-25):
    # persist slice mutations made by `handle_kind_message/3` via the
    # same snapshot commit path used by dispatch (`commit_and_notify/3`).
    # Without this, a Kind whose `handle_kind_message` mutates state
    # (Publisher's cursor + ring, Chat's :DOWN-driven offline flag,
    # any future hook-driven Behavior) would lose those mutations on
    # a crash + restart — the in-memory slice would advance but the
    # `kind_snapshots` row would still hold the pre-mutation slice.
    #
    # Per the same posture as `commit_and_notify/3`, we deliberately
    # do NOT emit a new `Ezagent.SliceChange` event here: a
    # `handle_info` message is a downstream effect of some upstream
    # action (a SliceChange already emitted, a Process.monitor :DOWN
    # fired by the runtime), NOT a fresh slice-mutating action. Emitting
    # would amplify a single dispatch into N (for Publisher SessionImpl,
    # would create an emit loop until the `slice_key == :publisher`
    # gate inside SessionImpl.handle_kind_message dropped it).
    #
    # Same defensive shape as commit_and_notify/3: skip the snapshot
    # write entirely when the slice is unchanged (slice_state == new_slice_state)
    # so `:ephemeral` / `:periodic` / unchanged-on-change Kinds incur
    # zero DB cost on a no-op handle_info.
    _ = persist_handle_info_mutation(self_uri, kind_module, slice_state, new_slice_state)

    {:noreply, %{wrapper | state: new_slice_state}}
  end

  defp forward_to_behavior(behavior, message, slice_state, kind_module, self_uri) do
    if function_exported?(behavior, :handle_kind_message, 3) do
      slice_key = behavior.state_slice()
      slice = Map.get(slice_state, slice_key, %{})

      # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25) — expose the full
      # slice_state via `ctx.slice_state` so Behaviors that need to
      # read OTHER slices on the same Kind (the Publisher's
      # SessionImpl reading `:chat` after a `:slice_changed` event
      # for that slice) can do so WITHOUT calling
      # `Kind.get_slice/2` — that would be a self-`GenServer.call`
      # from inside `handle_info`, which deadlocks. Each Behavior's
      # own slice is still the legitimate WRITE target via the
      # return value; `slice_state` is READ-ONLY context.
      ctx = %{
        kind_module: kind_module,
        self_uri: self_uri,
        slice_state: slice_state
      }

      case behavior.handle_kind_message(message, slice, ctx) do
        {:ok, new_slice} -> Map.put(slice_state, slice_key, new_slice)
        :ignore -> slice_state
      end
    else
      slice_state
    end
  end

  # ExternalMirror PR-EM-0 codex round-1 HIGH fix — see handle_info/2 moduledoc.
  defp persist_handle_info_mutation(_uri, _kind_module, slice_state, slice_state),
    do: :not_durable

  defp persist_handle_info_mutation(uri, kind_module, old_slice_state, new_slice_state) do
    # Issue #342 (Allen 2026-05-25): handle_info mutations are
    # by-design downstream effects of upstream actions (see the
    # caller's comment at line ~526). Following the same posture as
    # commit_post_init/2 above: a transient DB error here should NOT
    # crash the Kind on every fired :DOWN or :slice_changed message
    # — that would amplify a DB hiccup into a Kind boot-loop. Wrap
    # save_now's strict failures at this boundary; the next dispatch
    # path enforces durability strictly so the mutation gets a fair
    # chance to land.
    #
    # Catches BOTH `rescue` (exceptions) and `catch :exit` (linked
    # process exits, e.g. sandbox connection owner death in tests, or
    # genuine DBConnection process death in prod).
    try do
      Ezagent.Kind.Snapshot.commit(uri, kind_module, old_slice_state, new_slice_state)
    rescue
      e ->
        require Logger

        Logger.warning(
          "Ezagent.Kind.Server.persist_handle_info_mutation: snapshot commit " <>
            "raised for #{inspect(uri)}: #{inspect(e)} — handle_info mutation " <>
            "kept in-memory only"
        )

        {:error, e}
    catch
      :exit, reason ->
        require Logger

        Logger.warning(
          "Ezagent.Kind.Server.persist_handle_info_mutation: snapshot commit " <>
            "exited for #{inspect(uri)}: #{inspect(reason)} — handle_info " <>
            "mutation kept in-memory only"
        )

        {:error, {:exit, reason}}
    end
  end

  @impl true
  def terminate(reason, %{kind: kind_module, uri: uri, state: slice_state} = _state) do
    # #201-cred (codex r2 MEDIUM-6) — free THIS incarnation's pid-bound
    # freshness verdict row. Best-effort: a leaked row is never consulted
    # (its pid never recurs).
    :ok = Ezagent.Kind.CreateFreshness.delete(URI.to_string(uri), self())

    # Phase 4-completion: :on_terminate strategy writes on graceful
    # shutdown. Use try/rescue so a failing save never prevents the
    # Kind from going down.
    case Ezagent.Kind.persistence_of(kind_module) do
      :on_terminate ->
        try do
          _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
        rescue
          _ -> :ok
        catch
          # Issue #342 — also catch :exit so a linked DB connection
          # death (sandbox owner exit / DBConnection crash) doesn't
          # prevent the Kind from going down cleanly.
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    # PR-EM-2 codex round-1 HIGH-1 fix (2026-05-25): drain
    # per-Behavior `terminate/3` callbacks so Behaviors with
    # owned resources (e.g. `Ezagent.ActionSet.ExternalMirrorWorker`
    # whose `binding_module.terminate/2` releases transport state)
    # actually get a chance to clean up on graceful shutdown.
    #
    # Optional callback — `function_exported?/3` probe; Behaviors
    # without it skip. Each callback gets `(reason, slice, ctx)`
    # where ctx mirrors `handle_kind_message/3`'s
    # `%{kind_module:, self_uri:}`. Slice mutations from
    # terminate/3 are NOT persisted (the process is exiting; any
    # snapshot already happened above per persistence policy).
    drain_behavior_terminates(reason, kind_module, uri, slice_state)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # PR-EM-2 codex round-1 HIGH-1 — invoke each Behavior's optional
  # `terminate/3` callback in `behaviors/0` declaration order.
  # Crashes inside a Behavior's terminate are isolated (try/rescue)
  # so one buggy Behavior doesn't prevent siblings from cleaning up.
  defp drain_behavior_terminates(reason, kind_module, uri, slice_state) do
    ctx = %{kind_module: kind_module, self_uri: uri}

    # P1 (SPEC §3.1, E5) — only the INSTANCE effective set runs terminate.
    Enum.each(Ezagent.Kind.BehaviorSet.materialized_set(kind_module, slice_state), fn behavior ->
      if function_exported?(behavior, :terminate, 3) do
        slice = Map.get(slice_state, behavior.state_slice(), %{})

        try do
          _ = behavior.terminate(reason, slice, ctx)
        rescue
          err ->
            require Logger

            Logger.warning(
              "Ezagent.Kind.Server: Behavior #{inspect(behavior)}.terminate/3 " <>
                "raised on Kind shutdown (#{inspect(err)}). Continuing teardown " <>
                "of remaining behaviors. URI=#{URI.to_string(uri)}"
            )
        catch
          kind, value ->
            require Logger

            Logger.warning(
              "Ezagent.Kind.Server: Behavior #{inspect(behavior)}.terminate/3 " <>
                "threw #{inspect({kind, value})} on Kind shutdown. Continuing " <>
                "teardown of remaining behaviors. URI=#{URI.to_string(uri)}"
            )
        end
      end
    end)
  end
end
