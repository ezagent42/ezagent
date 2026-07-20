defmodule Ezagent.ActionSet.ExternalMirrorWorker do
  @moduledoc """
  `Ezagent.ActionSet.ExternalMirrorWorker` — the per-binding Worker
  Behavior on `Ezagent.Entity.ExternalMirrorWorker`.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.3 / §6.1 / §8.3.

  Owns:
  - the `:external_mirror_worker` slice
  - the `:publish` action (the only action this Behavior implements)
  - the post-init split-init pattern (PR-EM-CORE hook): `post_init/2`
    returns `{:continue, :subscribe_and_init}`; `handle_continue/3`
    runs AFTER `:announce_ready` and (a) subscribes to the Session
    Publisher (b) calls `binding.init/1`
  - the `{:publisher_event, %Event{}}` mailbox hook
    (`handle_kind_message/3`) which self-dispatches `:publish`

  ## Slice shape (`:external_mirror_worker`)

      %{
        # static — set at spawn time
        session_uri:        %URI{},
        adapter_id:         String.t(),
        target_id:          term(),
        opts:               map(),

        # late-bound — set in handle_continue/3 after init succeeds
        adapter_module:     module() | nil,
        binding_module:     module() | nil,
        binding_state:      term() | nil,
        subscription_state: :pending | :active,
        publisher_cursor:   non_neg_integer() | :latest,

        # accumulated over publishes
        count:              non_neg_integer(),
        error_count:        non_neg_integer(),
        last_published_at:  DateTime.t() | nil,
        last_publish_result: :ok | :skip | {:error, term()} | nil,

        # composite idempotency key of the last successfully-published
        # event: `{message_id, send_cursor}` (or nil before the first
        # publish). The `send_cursor` half is what distinguishes a
        # legitimate retry-send (reused msg.id, bumped send_cursor —
        # MUST publish) from a true event replay (same msg.id AND same
        # send_cursor — MUST dedupe).
        last_published_send_key: {term(), non_neg_integer()} | nil
      }

  ## :publish action

  Self-dispatched (`:cast`) from `handle_kind_message/3` on receipt
  of a `{:publisher_event, %Event{}}` message — routing the publish
  through `Kind.Runtime.handle_dispatch/4` so step 5.5 CapBAC +
  audit + telemetry + idempotency apply (P14 hygiene).

  Body:
    1. `payload = adapter_module.event_to_payload(event)`
    2. if `:skip` → update cursor + count, no transport call
    3. if `{:publish, payload}` → `binding_module.publish(payload, binding_state)`
    4. on `{:ok, new_binding_state}` → update slice cursor / count / timestamps
    5. on `{:error, reason, new_binding_state}` → recoverable; log +
       update error_count; carry new_binding_state forward
    6. on RAISE inside `event_to_payload` or `publish` → let it
       crash; PerBindingSupervisor restarts per `:permanent` budget

  ## Failure semantics (per `feedback_let_it_crash_no_workarounds`)

  NO `:warning`+degrade paths. Recoverable failures
  (`{:error, _, _}` from `publish/2`) update slice telemetry
  fields and return successfully — the next slice change
  dispatches a fresh `:publish` and the binding may recover.
  UNrecoverable failures (RAISE inside adapter or binding) let
  the Worker crash; the PerBindingSupervisor's 3/30s budget
  absorbs short bursts; a sustained crash loop trips the
  PerBindingSupervisor itself and leaves it down — operator sees
  telemetry, unbinds.

  ## data_owner/1

  `:no_owner` — Worker Kinds are framework-internal (SPEC §4.3 /
  §7.3 Cap 3). Users never hold caps on Worker instances directly;
  the Session Kind holds a scope-bounded
  `{:within_session, session_uri}` delegation cap that PR-EM-3 will
  wire when `:bind` spawns the worker. PR-EM-2 leaves the cap
  table populated with the `:publish` subject (registered in
  `EzagentDomainExternalMirror.Application`) but does not yet
  enforce the per-session delegation — that's PR-EM-3's scope.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.Publisher.Event
  alias Ezagent.ActionSet.ExternalMirrorWorker.SendKey

  # ----- Ezagent.Lifecycle contract (Phase B lifecycle migration) ---------
  #
  # SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §2.3
  # / §5. Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`.
  #
  # Two-container split (SPEC §0.1 / §2.1):
  #
  #   - `state` (PERSISTENT, auto-snapshotted): the binding's identity
  #     (`session_uri` / `adapter_id` / `target_id` / `opts`) + the
  #     publish telemetry the worker accumulates and that must survive a
  #     cold restart so cursor-based catch-up replays the right window
  #     (`publisher_cursor` / `count` / `error_count` / `last_published_at`
  #     / `last_publish_result` / `last_published_send_key`).
  #   - `transients` (NEVER persisted, rebuilt in `activate/2`): the LIVE
  #     transport handles — `adapter_module` / `binding_module` (resolved
  #     from registries every start), `binding_state` (the OPEN transport
  #     connection, dead after a restart), and `subscription_state` (the
  #     live Publisher subscription, re-established every start). These are
  #     exactly the "PIDs/refs/handles/cached connections" the SPEC names
  #     as transient. Persisting `binding_state` was the latent
  #     cold-restart bug — a snapshotted-then-rehydrated transport handle
  #     is dead; `activate/2` re-opens it.
  #
  # `activate/2` UNIFIES the old `post_init/2` → `handle_continue/3`
  # split-init: resolve modules, open the binding transport, and subscribe
  # to the Session Publisher + lifecycle topic. This runs PRE-`:ready` — the
  # SAME timing as the old `handle_continue(:subscribe_and_init, …)` (the
  # engine runs post-init continuations while the host is still
  # `:not_ready`; SPEC §10-R1 only forces a defer when the work targets
  # THIS Kind's own readiness — here the subscribe `:call` targets the
  # SESSION Kind, which is already `:ready`, so no self-defer is needed).
  #
  # `handle_signal/2` (the `handle_kind_message/3` successor) handles the
  # `:publisher_event` / `:publisher_alive` / resubscribe-retry mailbox
  # messages. CRITICALLY (T1): on `:publisher_event` it now returns a
  # `{:dispatch, %Cmd{}}` EFFECT (was an imperative `Router.dispatch/1`
  # call) — the declarative effect path executes the cross-Kind publish
  # dispatch with the same ordering + atomicity as an action handler.
  #
  # `handle_publish/2` reads slice keys via `ctx.read.(:key, default)` for
  # persistent fields and `ctx.transients[:key]` for the live transport
  # handles, and returns `{:ok, result, [effect]}` with `{:set, …}` for
  # persistent mutations and `{:set_transient, :binding_state, …}` for the
  # advanced transport handle.

  # `caps: [:publish]` ⇒ atom; the macro's auto-derived `required_caps/0`
  # would produce `cap(:any, _, :publish)`. We override below to pin
  # the `:external_mirror_worker` kind axis Step 5.5 expects.
  action(:publish,
    args: %{},
    returns: %{ok: :boolean, cursor: :integer},
    caps: [:publish],
    modes: [:cast],
    description:
      "publish a Publisher event to an external system via the bound adapter+binding pair"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Explicit override — pin kind axis `:external_mirror_worker`.
  def required_caps do
    %{
      publish: Ezagent.Capability.cap(:external_mirror_worker, __MODULE__, :publish)
    }
  end

  # state_slice/0 is AUTO-DERIVED by `use Ezagent.Lifecycle` from the
  # module's last segment: `Ezagent.ActionSet.ExternalMirrorWorker` →
  # `:external_mirror_worker` — identical to the pre-migration explicit
  # `def state_slice, do: :external_mirror_worker`, so the snapshot slice
  # key is unchanged and no `state_slice:` override is needed (SPEC §5
  # step 2 / A5 verdict).

  # `create/1` builds ONLY the PERSISTENT `state` (SPEC §2.3 step 3). The
  # transport handles + subscription that the old `init_slice/1` seeded as
  # `nil`/`:pending` placeholders are now TRANSIENTS, built in `activate/2`.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       session_uri: Map.fetch!(args, :session_uri),
       adapter_id: Map.fetch!(args, :adapter_id),
       target_id: Map.fetch!(args, :target_id),
       opts: Map.get(args, :opts, %{}),
       subscribe_cap: Map.fetch!(args, :subscribe_cap),
       # Remediation SPEC 2026-05-30 (C-A): seed the FIRST-subscribe cursor
       # from the Session's publisher cursor captured at BIND time (passed by
       # `Behavior.ExternalMirror.do_bind` as `initial_publisher_cursor`).
       # Subscribing from this cursor replays any slice change that lands in
       # the Publisher ring during the deferred-subscribe window — no
       # first-event loss. Defaults `:latest` when not supplied (cold-load
       # rehydration doesn't run `create/1`; direct unit spawns omit it).
       publisher_cursor: Map.get(args, :initial_publisher_cursor, :latest),
       count: 0,
       error_count: 0,
       last_published_at: nil,
       last_publish_result: nil,
       # 2026-05-26 (Allen e2e Bug 5): every chat-slice mutation
       # (presence updates, member joins, last_seen ticks, ...) emits
       # a fresh publisher_event with `new_slice` carrying the CURRENT
       # `last_message`. The adapter's `event_to_payload/1` sees a
       # `nil` old_slice (PR-N3 r2 HIGH-1 stripped slice content from
       # the envelope) and falls into `chat_send_occurred?(new_slice,
       # nil)` which returns true for any non-nil last_message_id —
       # re-publishing the SAME message every time the chat slice
       # mutates for ANY reason. Result: Allen got 4 identical replies
       # in Feishu. The worker dedupes BEFORE invoking the adapter.
       #
       # PR #420 codex r4 MED (2026-06-01): the dedupe key is the
       # COMPOSITE `{message_id, send_cursor}`, NOT message_id alone.
       # `Chat.invoke(:send)` deliberately bumps `:send_cursor` on
       # every send INCLUDING a retry that reuses `msg.id` (MessageStore
       # `on_conflict: :nothing` returns the same row). The adapter's
       # `chat_send_occurred?/2` already treats any `send_cursor` delta
       # as a real publish, so dedupe by `msg.id` alone SILENTLY DROPS a
       # legitimate retry-send. Keying on the pair lets a retry through
       # (reused id + new cursor ≠ stored pair) while a true replay
       # (same id AND same cursor — `send_cursor` is monotonic per
       # `:send`, so a re-delivered event matches exactly) still dedupes.
       last_published_send_key: nil
     }}
  end

  @doc """
  `activate/2` (SPEC §2.3 step 4-5) — the UNIFIED start hook. Rebuilds
  ALL transients from `state`, every start (fresh spawn + cold-load):

  1. Resolve `adapter_module` + `binding_module` from the registries
     (raises on missing — structural error per SPEC §5.2; let-it-crash
     → PerBindingSupervisor restarts → `activate` re-runs).
  2. Open the binding's transport via `binding_module.init/1` → the live
     `binding_state` handle (TRANSIENT — a snapshotted handle would be a
     dead reference; this is precisely the cold-restart bug the
     two-container model kills).
  3. Subscribe `self()` to the Session Publisher (+ the lifecycle topic).
     The subscribe is a `:call` to the SESSION Kind (already `:ready`),
     NOT to this worker — so it is correct PRE-`:ready` (no §10-R1
     self-defer needed; this matches the old post-init `handle_continue`
     timing exactly).

  On binding-init failure → raise (let-it-crash; PerBindingSupervisor
  `:permanent` + 3/30s budget per SPEC §6.2).

  The 3-arity `{:ok, transients, state}` return reconciles `state`: on a
  cold-load the persisted `publisher_cursor` drives cursor-based catch-up
  (so re-subscribe replays events emitted during the down window), and
  `current_cursor` from the subscribe is folded back into `state` so the
  worker resumes from the right point.
  """
  @impl Ezagent.Lifecycle
  def activate(state, %{self_uri: self_uri}) do
    adapter_module = AdapterRegistry.lookup!(state.adapter_id)
    binding_module = BindingRegistry.lookup!(state.adapter_id)
    publish_cap = issue_publish_cap!(self_uri)

    # §10-R1 (remediation SPEC 2026-05-30 C-A) — DEFER the Session-Publisher
    # subscribe to a DETACHED Task, off this Worker's own GenServer.
    #
    # The subscribe is a synchronous Router `:call` to the SESSION Kind.
    # Doing it INLINE here deadlocks: `external_mirror.unbind` (running in the
    # Session's `handle_call`) tears THIS Worker down via
    # `WorkerSpawn.terminate → DynamicSupervisor.terminate_child`; a Worker
    # blocked in a `:call` to that same Session cannot process its own
    # shutdown until the call returns, while the Session is blocked in
    # `terminate_child` waiting for the Worker to die — deadlock until the 5s
    # shutdown brutal-kill (observed as the bind→unbind roundtrip timing out).
    # Running the subscribe in a Task keeps the Worker GenServer responsive.
    # The Task carries the Worker's pid as `subscriber_pid` (so the Session
    # fans publisher events to the Worker, not the Task) and reports its
    # outcome back as a `{:ezagent_worker_subscribe_result, _}` signal. This
    # is the canonical §10-R1 `activate → defer → handle_signal` pattern.
    #
    # On a cold-load `state.publisher_cursor` is the last-published cursor
    # (cursor-based catch-up replay); on a fresh spawn it is the cursor
    # captured at BIND time (`Behavior.ExternalMirror.do_bind` passes the
    # Session's then-current publisher cursor as `initial_publisher_cursor`),
    # so the first subscribe replays any slice change emitted during the
    # spawn→subscribe window — no first-event loss.
    send(self(), :ezagent_worker_initial_subscribe)

    # Task #49 (2026-05-27) — subscribe to the Session's lifecycle topic
    # so we get a kick if the Session is cold-spawned later. On
    # `:publisher_alive` we re-attach our (still-live) pid to the new
    # (empty) `:publisher.subscribers` map. See `Ezagent.PublisherLifecycle`
    # moduledoc + the `handle_signal/2` `:publisher_alive` clause below.
    # Local PubSub.subscribe (no cross-Kind `:call`) — safe here.
    :ok = Ezagent.PublisherLifecycle.subscribe(state.session_uri)

    case binding_module.init({state.target_id, adapter_module, state.opts}) do
      {:ok, binding_state} ->
        transients = %{
          adapter_module: adapter_module,
          binding_module: binding_module,
          binding_state: binding_state,
          publish_cap: publish_cap,
          # OPTIMISTICALLY `:active` (the Worker IS the subscriber pid). The
          # Publisher fans replay/live events straight to the Worker mailbox
          # during the Task's `subscribe_from`; those `:publisher_event`
          # messages can land BEFORE the Task's result signal flips the flag,
          # and the `:publisher_event` clause DROPS events while `:pending`.
          # Marking `:active` up front ensures the catch-up window is
          # accepted. If the subscribe ultimately fails (Session unreachable),
          # no events arrive and "active" is harmless until the
          # `:publisher_alive` handshake re-subscribes.
          subscription_state: :active
        }

        {:ok, transients}

      {:error, reason} ->
        # SPEC §6.2: binding's transport failed to open; raise to
        # crash the worker — PerBindingSupervisor restarts per
        # `:permanent` + 3/30s budget. If init keeps failing the
        # PerBindingSupervisor itself crashes and stays down
        # (operator sees telemetry; unbinds to recover).
        raise "ExternalMirrorWorker binding init failed: #{inspect(reason)}"
    end
  end

  @doc """
  Multi-clause `handle_signal/2` (the `handle_kind_message/3` successor —
  SPEC §9 OQ-3) covering:

  - `{:publisher_event, %Event{}}` — Publisher event from Session. Under
    Lifecycle (T1) this returns a `{:dispatch, %Cmd{}}` EFFECT (NOT an
    imperative `Router.dispatch/1` call) routing the `:publish` action to
    self, so step 5.5 CapBAC + audit + telemetry + idempotency apply (P14
    hygiene) AND the dispatch flows through the declarative effect pipeline.
  - `{:publisher_alive, %URI{}}` — Session lifecycle handshake (task #49);
    re-subscribe the still-alive Worker pid to a newly cold-spawned Session's
    publisher slice (which loads with `:subscribers = %{}` per CONCERN #3).
  - `{:ezagent_worker_resubscribe_retry, attempt}` — bounded retry tick for
    the `:not_ready` defence-in-depth backoff (see `attempt_resubscribe/3`).
  - `_other` — ignored.

  The `:publisher_alive` + retry clauses mutate the PERSISTENT
  `publisher_cursor` via a `{:set, :publisher_cursor, …}` effect; the
  publisher-event clause emits a `:dispatch` effect; clauses with nothing
  to do return `:ignore` so the engine skips the commit path.
  `subscription_state` is now a TRANSIENT (read via
  `ctx.transients[:subscription_state]`).
  """
  @impl Ezagent.Lifecycle
  def handle_signal({:publisher_event, %Event{} = event}, ctx) do
    self_uri = ctx.self_uri

    if ctx.transients[:subscription_state] == :active do
      # T1: declarative cross-Kind dispatch effect (was an imperative
      # `Router.dispatch/1` call). The framework re-enters the Router
      # with this %Cmd{}; same CapBAC + idempotency + audit as before.
      {:ok, [dispatch_publish_effect(self_uri, event, ctx.transients[:publish_cap])]}
    else
      # Defensive: events shouldn't arrive while subscription_state
      # is :pending (we're not subscribed yet). Log + drop per
      # latest-wins (SPEC §3).
      Logger.warning(
        "ExternalMirrorWorker received publisher_event while subscription_state=:pending; " <>
          "dropping (latest-wins per SPEC §3). uri=#{URI.to_string(self_uri)}"
      )

      :ignore
    end
  end

  # Task #49 (2026-05-27) — Session lifecycle event hook. See the
  # `handle_signal/2` function-head moduledoc above.
  def handle_signal({:publisher_alive, %URI{} = pub_uri}, ctx) do
    session_uri = ctx.read.(:session_uri, nil)

    cond do
      is_nil(session_uri) or URI.to_string(pub_uri) != URI.to_string(session_uri) ->
        # Lifecycle event for a different Session. Topic shape is
        # per-URI so this shouldn't happen, but be paranoid.
        :ignore

      ctx.transients[:subscription_state] != :active ->
        # Our own activate/2 hasn't completed yet — the subscribe inside
        # it will pick up the current cursor. Skip the re-subscribe.
        :ignore

      true ->
        attempt_resubscribe(ctx, session_uri, ctx.self_uri, 1)
    end
  end

  # Task #49 codex round-1 FAIL #6 (2026-05-27) — retry tick for the
  # defence-in-depth `:not_ready` backoff (see `attempt_resubscribe/4`).
  # See the `handle_signal/2` function-head moduledoc above.
  def handle_signal({:ezagent_worker_resubscribe_retry, attempt}, ctx) do
    if ctx.transients[:subscription_state] == :active do
      attempt_resubscribe(ctx, ctx.read.(:session_uri, nil), ctx.self_uri, attempt)
    else
      :ignore
    end
  end

  # §10-R1 / remediation C-A — kick the DEFERRED initial subscribe (self-sent
  # from `activate/2`). Runs the blocking `subscribe_from` `:call` in a
  # DETACHED Task (off this Worker process) so the Worker stays responsive to
  # a concurrent unbind→terminate. The Task reports back via
  # `{:ezagent_worker_subscribe_result, _}`.
  def handle_signal(:ezagent_worker_initial_subscribe, ctx) do
    session_uri = ctx.read.(:session_uri, nil)
    persisted_cursor = ctx.read.(:publisher_cursor, :latest)
    subscribe_cap = ctx.read.(:subscribe_cap, nil)

    spawn_initial_subscribe_task(session_uri, ctx.self_uri, persisted_cursor, subscribe_cap)
    # Still optimistically `:active` from activate — nothing to commit yet.
    :ignore
  end

  # §10-R1 / remediation C-A — the Task's result. The catch-up replay was
  # already applied IN the Task's `subscribe_from`; here we just fold the
  # resolved cursor into PERSISTENT state (subscription_state is already
  # `:active`). On a not-yet-reachable Session, leave it (the
  # `:publisher_alive` handshake re-arms when the Session cold-spawns).
  def handle_signal({:ezagent_worker_subscribe_result, result}, _ctx) do
    case result do
      {:ok, current_cursor} ->
        {:ok, [{:set, :publisher_cursor, current_cursor}]}

      {:error, reason} ->
        Logger.info(
          "ExternalMirrorWorker initial subscribe deferred-task result " <>
            "#{inspect(reason)}; will re-subscribe on :publisher_alive"
        )

        :ignore
    end
  end

  def handle_signal(_other, _ctx), do: :ignore

  # Run the (blocking) initial Publisher subscribe in a DETACHED Task under
  # `SubscribeTaskSup`, NOT on the Worker's own GenServer (see `activate/2`
  # for the deadlock rationale). The Task carries the Worker's pid as the
  # `subscriber_pid` (so the Session fans publisher events to the Worker, not
  # the Task) and the Worker URI as the CapBAC caller; it sends the result
  # back as a signal.
  defp spawn_initial_subscribe_task(nil, _self_uri, _cursor, _subscribe_cap), do: :ok

  defp spawn_initial_subscribe_task(
         %URI{} = session_uri,
         %URI{} = self_uri,
         persisted_cursor,
         %Ezagent.Capability{} = subscribe_cap
       ) do
    worker_pid = self()

    {:ok, _task_pid} =
      Task.Supervisor.start_child(Ezagent.ExternalMirror.SubscribeTaskSup, fn ->
        result =
          do_initial_subscribe(
            session_uri,
            self_uri,
            worker_pid,
            persisted_cursor,
            subscribe_cap
          )

        send(worker_pid, {:ezagent_worker_subscribe_result, result})
      end)

    :ok
  end

  # Cursor-based catch-up for the FIRST subscribe, run INSIDE the detached
  # Task (`subscriber_pid` passed explicitly — it is the Worker, not the
  # Task). On `:cursor_out_of_window` we fall back to `:earliest` (NOT
  # `:latest`): the captured/persisted cursor is older than the ring's oldest
  # retained entry, so replaying the WHOLE (bounded-by-retention) ring is the
  # correct catch-up — `:latest` would silently DROP the spawn→subscribe
  # window. Dedup by `last_published_send_key` keeps replayed-but-already-
  # published events from re-hitting the external transport.
  defp do_initial_subscribe(
         %URI{} = session_uri,
         %URI{} = self_uri,
         worker_pid,
         persisted_cursor,
         subscribe_cap
       ) do
    case subscribe_to_session_publisher_from(
           session_uri,
           self_uri,
           persisted_cursor,
           subscribe_cap,
           worker_pid
         ) do
      {:ok, current_cursor} ->
        {:ok, current_cursor}

      {:error, :cursor_out_of_window} ->
        subscribe_to_session_publisher_from(
          session_uri,
          self_uri,
          :earliest,
          subscribe_cap,
          worker_pid
        )

      {:error, _reason} = err ->
        err
    end
  end

  # Task #49 codex round-1 FAIL #6 — bounded retry on `{:error, :not_ready}`.
  #
  # Primary fix is `Ezagent.ActionSet.Publisher.SessionImpl.on_ready/2`
  # broadcasting AFTER ReadyGate flips, so this retry path should be
  # cold in normal operation. It exists as defence-in-depth for two
  # cases:
  #
  # 1. The on_ready broadcast races a concurrent Session vanish — by
  #    the time the Worker dispatches its subscribe `:call`, the
  #    Session has been terminated again. The Worker sees `:not_ready`
  #    (the Session is gone, ReadyGate is `:unknown` or `:not_ready`
  #    during the brief teardown window). A bounded retry waits out
  #    the next cold-spawn.
  # 2. A third-party Publisher Kind in the future fires
  #    `broadcast_alive` from its own `handle_continue/3` (forgetting
  #    the on_ready discipline). Workers subscribed to that publisher
  #    would still recover via the retry path.
  #
  # 5 attempts × 200ms = 1s total — bounded so a permanently-down
  # Session doesn't queue infinite retry messages. After the budget
  # exhausts we log + give up; the next `:publisher_alive` (e.g. a
  # later cold-spawn) re-arms the handshake.
  @max_resubscribe_attempts 5
  @resubscribe_backoff_ms 200

  # Task #49 codex round-3 NEW CHECK C — cursor-based catchup on
  # re-subscribe.
  #
  # Pre-r3, the lifecycle re-subscribe passed `cursor: :latest` →
  # zero replay. Between `on_ready/2` firing and the Worker's
  # `:publisher_alive` handler dispatching its subscribe `:call`,
  # any slice mutation lands in the Publisher's `:ring` with a fresh
  # cursor BUT fans out to `subscribers = %{}` — silent drop. This
  # is the same class of bug PR #420 was meant to fix; the first
  # message in the cold-spawn window could still drop.
  #
  # Fix: re-subscribe with the WORKER's persisted `publisher_cursor`
  # so the Publisher replays every event with `cursor > persisted`.
  # The publisher slice's `:ring` + `:cursor` survive snapshot load
  # (only `:subscribers` + `:monitors` are cleared by
  # `Behavior.Publisher.SessionImpl.reconcile_after_load/2`), so the
  # ring carries events emitted during the window.
  #
  # Idempotency: the worker dedupes by the composite
  # `last_published_send_key` (`{msg.id, send_cursor}`) in
  # `invoke(:publish, ...)`. Replayed events for sends the worker
  # already published get `:duplicate_skip` — no second outbound
  # transport call.
  #
  # Bounded: the publisher ring is bounded by `:retention` (default
  # 100 events); even if the persisted cursor is way behind, replay
  # is capped at retention. Cursors older than the ring's oldest
  # entry return `{:error, :cursor_out_of_window}` — we fall back to
  # `:latest` (restoring subscription is more important than
  # replaying unrecoverable events).
  #
  # First-subscribe (`publisher_cursor == :latest`) keeps the
  # original behaviour — there's no prior cursor to replay from,
  # the first subscribe in `activate/2` IS the first subscribe.
  #
  # Returns a `handle_signal/2`-shaped result: `{:ok, [effect]}` (a
  # `{:set, :publisher_cursor, cursor}` effect on the PERSISTENT cursor)
  # or `:ignore`. `publisher_cursor` is read from `ctx.read` (state).
  defp attempt_resubscribe(ctx, session_uri, self_uri, attempt) do
    persisted_cursor = ctx.read.(:publisher_cursor, :latest)
    subscribe_cap = ctx.read.(:subscribe_cap, nil)

    case subscribe_to_session_publisher_from(
           session_uri,
           self_uri,
           persisted_cursor,
           subscribe_cap
         ) do
      {:ok, current_cursor} ->
        {:ok, [{:set, :publisher_cursor, current_cursor}]}

      {:error, :cursor_out_of_window} ->
        # Persisted cursor is older than the publisher's retention
        # ring; the missed events are gone. Re-subscribe at :latest
        # to restore the live wire. Operator-visible via the
        # cursor-out-of-window log.
        Logger.warning(
          "ExternalMirrorWorker re-subscribe: persisted cursor " <>
            "#{inspect(persisted_cursor)} older than publisher retention; " <>
            "falling back to :latest. session=#{URI.to_string(session_uri)}"
        )

        case subscribe_to_session_publisher_from(session_uri, self_uri, :latest, subscribe_cap) do
          {:ok, current_cursor} ->
            {:ok, [{:set, :publisher_cursor, current_cursor}]}

          {:error, reason} ->
            Logger.warning(
              "ExternalMirrorWorker re-subscribe (fallback :latest) failed; " <>
                "session=#{URI.to_string(session_uri)} reason=#{inspect(reason)}"
            )

            :ignore
        end

      {:error, :not_ready} when attempt < @max_resubscribe_attempts ->
        Process.send_after(
          self(),
          {:ezagent_worker_resubscribe_retry, attempt + 1},
          @resubscribe_backoff_ms
        )

        :ignore

      {:error, reason} ->
        Logger.warning(
          "ExternalMirrorWorker re-subscribe failed after #{attempt} attempt(s); " <>
            "session=#{URI.to_string(session_uri)} reason=#{inspect(reason)}"
        )

        :ignore
    end
  end

  @doc """
  `deactivate/2` (SPEC §2.3 step 6) — the `terminate/3` successor:
  graceful shutdown hook invoked on Kind exit. Calls
  `binding_module.terminate(reason, binding_state)` per SPEC §6.2 to
  release the transport. `:ok`-only (F5) — it does side-effecting
  external cleanup, never a state write.

  The binding handles it reads (`subscription_state` / `binding_module`
  / `binding_state`) are TRANSIENTS, read via `ctx.transients[:key]`.

  Defensive: if the Binding's terminate is not exported (optional per
  SPEC §2.3), skip. If activate never advanced past `:pending` (e.g. a
  brutal kill before activate completed), there's no binding_state to
  clean up — skip. (On a brutal kill `deactivate` does not run at all —
  §OTP; that path leaks nothing this hook would have freed because the
  whole BEAM is gone.)
  """
  @impl Ezagent.Lifecycle
  def deactivate(reason, ctx) do
    subscription_state = ctx.transients[:subscription_state]
    binding_module = ctx.transients[:binding_module]
    binding_state = ctx.transients[:binding_state]

    cond do
      subscription_state != :active ->
        # Binding never finished init (still :pending) — no
        # transport handle to release.
        :ok

      not is_atom(binding_module) ->
        :ok

      not function_exported?(binding_module, :terminate, 2) ->
        # Binding.terminate/2 is optional per SPEC §2.3.
        :ok

      true ->
        try do
          _ = binding_module.terminate(reason, binding_state)
          :ok
        rescue
          err ->
            Logger.warning(
              "ExternalMirrorWorker: binding #{inspect(binding_module)}.terminate/2 " <>
                "raised on shutdown (#{inspect(err)}); transport resources may leak. " <>
                "binding_id=#{ctx.read.(:adapter_id, nil)}/#{inspect(ctx.read.(:target_id, nil))}"
            )

            :ok
        end
    end
  end

  # ----- The :publish action ------------------------------------------------

  # `handle_publish/2`. The in-memory working shape `do_invoke_publish/3`
  # expects is reconstructed from BOTH containers — persistent fields via
  # `ctx.read`, the live transport handles (`adapter_module` /
  # `binding_module` / `binding_state` / `subscription_state`) via
  # `ctx.transients`. `translate_publish_return/2` emits one effect per
  # CHANGED field: `{:set, …}` for persistent keys, `{:set_transient,
  # :binding_state, …}` for the advanced transport handle (a transient) —
  # preserving the dispatch pipeline's slice-change diff semantics while
  # keeping the open transport out of the snapshot.
  def handle_publish(%{event: %Event{} = event}, ctx) do
    slice = read_full_slice(ctx)

    # 2026-05-26 (Allen e2e Bug 5): dedupe BEFORE calling the adapter.
    # Every chat-slice mutation (presence, member join, last_seen)
    # emits a publisher_event with the current `last_message` in
    # `new_slice`; without this dedupe the adapter sees
    # `chat_send_occurred?(new_slice, nil) == true` for ALL of them and
    # re-publishes the SAME message N times to Feishu (Allen got 4
    # copies of one cc reply).
    #
    # PR #420 codex r4 MED (2026-06-01): the dedupe key is the COMPOSITE
    # `{msg.id, send_cursor}`. `msg.id` alone is too coarse — a
    # legitimate retry-send reuses the id but bumps `send_cursor`
    # (`Chat.invoke(:send)` always increments it; MessageStore's
    # `on_conflict: :nothing` returns the same row). The adapter treats
    # every `send_cursor` delta as a real publish, so an id-only dedupe
    # SILENTLY DROPS the retry. Keying on the pair:
    #   - retry-send (reused id, NEW cursor) ≠ stored pair → publishes
    #   - true replay (same id AND same cursor — `send_cursor` is
    #     monotonic per `:send`, a re-delivered event carries the exact
    #     same pair) == stored pair → dedupes
    event_send_key = SendKey.extract_event_send_key(event)

    legacy_result =
      cond do
        not is_nil(event_send_key) and event_send_key == slice.last_published_send_key ->
          new_slice = %{
            slice
            | publisher_cursor: event.cursor,
              count: slice.count + 1,
              last_publish_result: :duplicate_skip,
              last_published_at: DateTime.utc_now()
          }

          {:ok, new_slice, %{ok: true, cursor: event.cursor, skipped: true}}

        true ->
          do_invoke_publish(slice, event, event_send_key)
      end

    translate_publish_return(slice, legacy_result)
  end

  # Reconstruct the in-memory working shape `do_invoke_publish/3` expects.
  # PERSISTENT fields come from `ctx.read`; the live transport handles
  # (`adapter_module` / `binding_module` / `binding_state` /
  # `subscription_state`) are TRANSIENTS, read from `ctx.transients` (the
  # `:pending` / nil defaults match a Worker that hasn't activated yet).
  defp read_full_slice(ctx) do
    %{
      session_uri: ctx.read.(:session_uri, nil),
      adapter_id: ctx.read.(:adapter_id, nil),
      target_id: ctx.read.(:target_id, nil),
      opts: ctx.read.(:opts, %{}),
      adapter_module: ctx.transients[:adapter_module],
      binding_module: ctx.transients[:binding_module],
      binding_state: ctx.transients[:binding_state],
      subscription_state: ctx.transients[:subscription_state] || :pending,
      publisher_cursor: ctx.read.(:publisher_cursor, :latest),
      count: ctx.read.(:count, 0),
      error_count: ctx.read.(:error_count, 0),
      last_published_at: ctx.read.(:last_published_at, nil),
      last_publish_result: ctx.read.(:last_publish_result, nil),
      last_published_send_key: ctx.read.(:last_published_send_key, nil)
    }
  end

  # Translate `{:ok, new_slice, result}` from `do_invoke_publish/3` into
  # `{:ok, result, [effect]}`. We emit one effect per CHANGED field (skip
  # unchanged) so the slice-change diff fires identically to the
  # pre-migration path. `:binding_state` is a TRANSIENT (the live transport
  # handle) → `{:set_transient, …}`; every other mutated field is
  # persistent → `{:set, …}`.
  @publish_persistent_keys [
    :publisher_cursor,
    :count,
    :error_count,
    :last_publish_result,
    :last_published_at,
    :last_published_send_key
  ]

  defp translate_publish_return(old_slice, {:ok, new_slice, result}) do
    # `:publish` only ever returns `{:ok, _, _}` (recoverable transport
    # failures are folded into the success path with bumped
    # `error_count`); the `{:error, _}` branch is unreachable here.
    persistent_effects =
      Enum.flat_map(@publish_persistent_keys, fn key ->
        if Map.get(old_slice, key) == Map.get(new_slice, key) do
          []
        else
          [{:set, key, Map.get(new_slice, key)}]
        end
      end)

    transient_effects =
      if Map.get(old_slice, :binding_state) == Map.get(new_slice, :binding_state) do
        []
      else
        [{:set_transient, :binding_state, Map.get(new_slice, :binding_state)}]
      end

    {:ok, result, persistent_effects ++ transient_effects}
  end

  # ----- internals -----

  # Send-key derivation (extract_event_send_key / unwrap_chat_slice /
  # fetch_send_cursor) lives in
  # `Ezagent.ActionSet.ExternalMirrorWorker.SendKey` (#25 Phase-3 PR-3O).

  defp do_invoke_publish(slice, %Event{} = event, event_send_key) do
    case slice.adapter_module.event_to_payload(event) do
      :skip ->
        new_slice = %{
          slice
          | publisher_cursor: event.cursor,
            count: slice.count + 1,
            last_publish_result: :skip,
            last_published_at: DateTime.utc_now()
        }

        {:ok, new_slice, %{ok: true, cursor: event.cursor, skipped: true}}

      {:publish, payload} ->
        case slice.binding_module.publish(payload, slice.binding_state) do
          {:ok, new_binding_state} ->
            new_slice = %{
              slice
              | binding_state: new_binding_state,
                publisher_cursor: event.cursor,
                count: slice.count + 1,
                last_publish_result: :ok,
                last_published_at: DateTime.utc_now(),
                last_published_send_key: event_send_key
            }

            {:ok, new_slice, %{ok: true, cursor: event.cursor}}

          {:error, reason, new_binding_state} ->
            # Recoverable: log + bump error_count; do NOT crash.
            # The next slice change dispatches a fresh :publish and
            # the binding may recover.
            Logger.warning(
              "ExternalMirror publish failed (recoverable): " <>
                "adapter_id=#{inspect(slice.adapter_id)} " <>
                "target_id=#{inspect(slice.target_id)} " <>
                "reason=#{inspect(reason)}"
            )

            new_slice = %{
              slice
              | binding_state: new_binding_state,
                publisher_cursor: event.cursor,
                count: slice.count + 1,
                error_count: slice.error_count + 1,
                last_publish_result: {:error, reason},
                last_published_at: DateTime.utc_now()
            }

            {:ok, new_slice, %{ok: false, cursor: event.cursor, reason: reason}}
        end
    end
  end

  # `interface/0`, `actions/0`, `cap_subjects/0` are auto-derived by
  # `use Ezagent.ActionSet` from the `action :publish, ...` declaration
  # at the top of this module. The legacy explicit `interface/0` was
  # removed as part of the Phase 2-d r3 migration.

  @doc """
  SPEC §4.3: Worker Kinds are framework-internal; only bootstrap
  admin can grant caps. Users never hold caps on `entity://worker/...`
  URIs directly — the Session Kind holds a scope-bounded delegation
  cap (PR-EM-3 will wire this) per SPEC §7.3 Cap 3.
  """
  def data_owner(%URI{}), do: :no_owner
  def data_owner(:any), do: :no_owner
  def data_owner({:scope, :within_session, %URI{}}), do: :no_owner
  def data_owner(_), do: :no_owner

  # ----- internals ----------------------------------------------------------

  # Wiring of Publisher.subscribe_from — carries the Worker's OWN inline
  # subscribe cap (`worker_subscribe_caps/0`) in `ctx.caps` so step 5.5
  # (`granted_via_ctx_caps?`) admits the call. System-principal elimination
  # (#154, 2026-06-19): BOTH internal dispatch sites (this one +
  # `dispatch_publish_effect/2`) previously borrowed the ambient
  # `system://worker-publish` principal; that principal is DELETED and each
  # now carries the Worker's OWN inline authorizer cap (`caller: self_uri`).
  # See the self-authority helpers below for the granted_by rationale + the
  # PR-EM-3 `{:within_session}` Cap 3 follow-up.
  #
  # We don't call `Ezagent.Entity.Session.subscribe_from/4`
  # directly: `:ezagent_domain_session` depends on
  # `:ezagent_domain_external_mirror` (for the Publisher contract),
  # so a reverse reference here would form a Mix dep cycle.
  # The dispatch goes through `?action=publisher.subscribe_from`
  # — identical wire-shape to what `Session.subscribe_from/4`
  # constructs (SPEC §8.1).

  # Cursor replay is synchronous so the lifecycle hook can persist the returned
  # cursor. The detached initial task passes the Worker pid explicitly.
  defp subscribe_to_session_publisher_from(
         session_uri,
         self_uri,
         cursor,
         subscribe_cap,
         subscriber_pid \\ nil
       )

  defp subscribe_to_session_publisher_from(
         %URI{} = session_uri,
         %URI{} = self_uri,
         cursor,
         %Ezagent.Capability{} = subscribe_cap,
         sub_pid
       ) do
    subscriber_pid = sub_pid || self()

    cmd =
      Ezagent.Cmd.new(
        session_uri,
        :subscribe_from,
        %{subscriber_pid: subscriber_pid, cursor: cursor},
        %{
          caller: self_uri,
          caps: [subscribe_cap],
          reply: {:caller_inbox, self()},
          # Setup can queue behind Session persistence work.
          deadline_ms: 30_000
        }
      )

    case Ezagent.Router.dispatch(cmd) do
      {:ok, %{cursor: new_cursor}} -> {:ok, new_cursor}
      {:error, _} = err -> err
      :ok -> {:ok, :latest}
    end
  end

  # The signal handler returns a declarative self-dispatch so CapBAC,
  # idempotency, audit, and telemetry all stay on the normal Router path.
  defp dispatch_publish_effect(
         %URI{} = self_uri,
         %Event{} = event,
         %Ezagent.Capability{} = publish_cap
       ) do
    # Scope idempotency to the Worker URI. Publisher cursors are local to
    # one publisher/session, while Ezagent.Idempotency is process-wide;
    # cursor-only keys would make different workers with cursor 1 collide.
    idem = "external_mirror_worker.publish/#{URI.to_string(self_uri)}##{event.cursor}"

    {:dispatch,
     Ezagent.Cmd.new(
       self_uri,
       :publish,
       %{event: event},
       %{
         caller: self_uri,
         caps: [publish_cap],
         reply: :ignore,
         command_uuid: idem,
         idempotency_key: idem
       }
     )}
  end

  # Publish authority is issued once during activation and retained only in the
  # Worker's transient state.
  defp issue_publish_cap!(self_uri) do
    requested =
      Ezagent.Capability.cap(
        :external_mirror_worker,
        __MODULE__,
        :publish,
        Ezagent.URI.instance(self_uri),
        Ezagent.Capability.workspace_of(self_uri)
      )

    case Ezagent.Identity.Grant.issue_cap(
           self_uri,
           requested,
           {:admin, Ezagent.Entity.User.admin_uri()}
         ) do
      {:ok, cap} ->
        cap

      {:error, reason} ->
        raise "failed to issue ExternalMirrorWorker publish cap: #{inspect(reason)}"
    end
  end
end
