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
    kind: module(),                # the Kind module (e.g. Ezagent.Entity.Echo)
    uri:  URI.t(),                 # this instance's URI
    state: %{atom() => map()},     # per-Behavior slices, keyed by behavior.state_slice()
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
  `Ezagent.Behavior` let a Behavior schedule deferred work that runs
  after `:announce_ready`. See `Ezagent.Behavior` moduledoc + the
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

    slice_state = Ezagent.Kind.Snapshot.load_or_init(uri, kind_module, args)

    # PR-EM-CORE: collect post_init/2 continuations in behaviors/0
    # declaration order. `post_init/2` is OPTIONAL — Behaviors that
    # don't export it (or return `:ok`) contribute nothing to the
    # queue. The actual handle_continue/3 calls run AFTER
    # :announce_ready (see handle_continue/2 below).
    post_init_queue = collect_post_init_queue(kind_module, args, slice_state)

    state = %{
      kind: kind_module,
      uri: uri,
      state: slice_state,
      post_init_queue: post_init_queue
    }

    case Ezagent.KindRegistry.put_new(uri_str, self()) do
      :ok ->
        :ok = Ezagent.ReadyGate.put(uri_str, :not_ready)
        schedule_periodic_snapshot(kind_module)
        {:ok, state, {:continue, :announce_ready}}

      {:error, {:already_registered, _other_pid}} ->
        # Let-it-crash — duplicate spawn is a bug at the caller layer.
        {:stop, {:already_registered, uri_str}}
    end
  end

  # PR-EM-CORE: walk each Behavior, call its optional post_init/2 with
  # (args, behavior's own slice), and collect `{behavior, term}` entries
  # for any that returned `{:continue, term}`. Behaviors that don't
  # export `post_init/2` or that returned `:ok` are skipped. Order is
  # `kind_module.behaviors/0` (declaration order) — deterministic.
  defp collect_post_init_queue(kind_module, args, slice_state) do
    kind_module.behaviors()
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
    case kind_module.persistence() do
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
        drain_then_mark_ready(uri_str)
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
    %{kind: kind_module, uri: self_uri, state: slice_state} = state

    new_slice_state =
      run_post_init_continuation(behavior, term, slice_state, kind_module, self_uri)

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
        drain_then_mark_ready(URI.to_string(self_uri))
        {:noreply, new_state}

      _ ->
        {:noreply, new_state, {:continue, {:ezagent_post_init, rest}}}
    end
  end

  defp run_post_init_continuation(behavior, term, slice_state, kind_module, self_uri) do
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
    _ = Ezagent.Kind.Snapshot.commit(uri, kind_module, old_slice_state, new_slice_state)
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
  defp drain_then_mark_ready(uri_str) when is_binary(uri_str) do
    case Ezagent.PendingDelivery.flush(uri_str) do
      [] ->
        :ok = Ezagent.ReadyGate.mark_ready(uri_str)

      entries ->
        Enum.each(entries, fn buffered_inv ->
          GenServer.cast(self(), {:ezagent_dispatch, buffered_inv})
        end)

        # Re-check — dispatchers may have added entries while we were
        # self-casting (they still saw :not_ready).
        drain_then_mark_ready(uri_str)
    end
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

  # PR-OWN-2 (caps-data-ownership SPEC #306 §7) — read a single
  # Behavior slice. Used by `Ezagent.Kind.get_slice/2` for cross-
  # process lookups (e.g. `Session.owner/1` resolves session.owner_uri
  # so `Behavior.Chat.data_owner/1` can return a real URI).
  def handle_call({:ezagent_get_slice, slice_key}, _from, %{state: slice_state} = state)
      when is_atom(slice_key) do
    {:reply, {:ok, Map.get(slice_state, slice_key)}, state}
  end

  def handle_call({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, _from, state) do
    case Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri) do
      {:ok, new_slice_state, result, slice_change_event} ->
        commit_and_notify(state, new_slice_state, slice_change_event)

        reply = if is_nil(result), do: :ok, else: {:ok, result}
        {:reply, reply, %{state | state: new_slice_state}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_cast({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, state) do
    case Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri) do
      {:ok, new_slice_state, result, slice_change_event} ->
        commit_and_notify(state, new_slice_state, slice_change_event)

        # cast still replies via ctx.reply if set (e.g. caller_inbox).
        Ezagent.Invocation.reply(inv.ctx, {:ok, result})
        {:noreply, %{state | state: new_slice_state}}

      {:error, reason} ->
        Ezagent.Invocation.reply(inv.ctx, {:error, reason})
        {:noreply, state}
    end
  end

  # Commit-then-notify ordering (codex PR-N1 round-2 MEDIUM +
  # round-3 HIGH-1 fix):
  # 1. `Snapshot.commit/4` returns the STRICT outcome:
  #    `:ok` = durably persisted; `:not_durable` = policy doesn't
  #    require a durable write here (ephemeral / unchanged / periodic);
  #    `{:error, _}` = durable policy attempted + failed
  # 2. Emit ONLY on `:ok` or `:not_durable`:
  #    - `:ok` — slice survives restart, subscribers safe to act
  #    - `:not_durable` — by-design no durability promise (e.g. an
  #      `:ephemeral` Kind); in-memory slice IS the truth so notify
  #      is correct
  #    - `{:error, _}` — GenServer holds state that won't survive
  #      crash. Ghost-notify would tell LV "Alice → Bob" but a
  #      restart re-loads "Alice → Carol". Suppress emit. `commit/4`
  #      has already logged + emitted `:failed` telemetry.
  defp commit_and_notify(state, new_slice_state, slice_change_event) do
    commit_result =
      Ezagent.Kind.Snapshot.commit(state.uri, state.kind, state.state, new_slice_state)

    if slice_change_event && commit_result in [:ok, :not_durable] do
      Ezagent.SliceChange.emit(slice_change_event)
    end

    :ok
  end

  # Unified forwarder: any GenServer message a Kind's Behaviors might want
  # to react to (currently only `:DOWN` from Process.monitor; Phase 3+ may
  # add timer ticks etc) routes through `handle_kind_message/3` on each
  # Behavior that exports it. Behaviors that ignore the message return
  # their slice unchanged.
  #
  # The optional hook signature `handle_kind_message(message, slice, ctx)`:
  #  - `message`: the raw GenServer message (e.g. `{:DOWN, ref, ..., reason}`)
  #  - `slice`: this Behavior's slice
  #  - `ctx`: %{kind_module:, self_uri:} so Behaviors can route based on Kind
  #
  # Returns `{:ok, new_slice}` or `:ignore` (slice unchanged). This lets
  # multi-Behavior Kinds share one mailbox without each Behavior shadowing
  # everything (P2-D2 K-path principle: one Behavior, multiple Kinds —
  # not a Kind-wide message bus).
  @impl true
  def handle_info(:snapshot_tick, %{kind: kind_module, uri: uri, state: slice_state} = wrapper) do
    # Phase 4-completion: periodic strategy — write via Writer (async)
    # then re-schedule. If Writer isn't running (e.g. test envs without
    # full sup tree), fall back to sync save_now to remain useful.
    case kind_module.persistence() do
      {:snapshot, :periodic, ms} ->
        if Process.whereis(Ezagent.Snapshot.Writer) do
          Ezagent.Snapshot.Writer.async_save(uri, kind_module, slice_state)
        else
          _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
        end

        Process.send_after(self(), :snapshot_tick, ms)
        {:noreply, wrapper}

      _ ->
        {:noreply, wrapper}
    end
  end

  def handle_info(message, %{kind: kind_module, uri: self_uri, state: slice_state} = wrapper) do
    new_slice_state =
      kind_module.behaviors()
      |> Enum.reduce(slice_state, fn behavior, acc_state ->
        forward_to_behavior(behavior, message, acc_state, kind_module, self_uri)
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
      ctx = %{kind_module: kind_module, self_uri: self_uri}

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
    Ezagent.Kind.Snapshot.commit(uri, kind_module, old_slice_state, new_slice_state)
  end

  @impl true
  def terminate(reason, %{kind: kind_module, uri: uri, state: slice_state} = _state) do
    # Phase 4-completion: :on_terminate strategy writes on graceful
    # shutdown. Use try/rescue so a failing save never prevents the
    # Kind from going down.
    case kind_module.persistence() do
      :on_terminate ->
        try do
          _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end

    # PR-EM-2 codex round-1 HIGH-1 fix (2026-05-25): drain
    # per-Behavior `terminate/3` callbacks so Behaviors with
    # owned resources (e.g. `Ezagent.Behavior.ExternalMirrorWorker`
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

    Enum.each(kind_module.behaviors(), fn behavior ->
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
