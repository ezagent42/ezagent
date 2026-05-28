defmodule Ezagent.Behavior.ExternalMirrorWorker do
  @moduledoc """
  `Ezagent.Behavior.ExternalMirrorWorker` — the per-binding Worker
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
        last_publish_result: :ok | :skip | {:error, term()} | nil
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

  use Ezagent.Behavior

  require Logger

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.Publisher.Event

  # ----- Ezagent.Behavior contract (Phase 2-d r3 migration) ---------------
  #
  # SPEC §6.2 retrofit: `use Ezagent.Behavior` + `action :publish, ...`
  # macro declaration auto-derives `actions/0` / `interface/0` /
  # `cap_subjects/0`. `state_slice/0` + lifecycle hooks
  # (`init_slice/1`, `post_init/2`, `handle_continue/3`, `terminate/3`,
  # `data_owner/1`, `handle_kind_message/3`) stay as plain function
  # defs invoked directly by `Ezagent.Kind.Server`.
  #
  # `:publish` was `invoke(:publish, slice, args, ctx)`; the new
  # handler `handle_publish/2` reads slice keys via
  # `ctx[:read].(:key, default)` and returns `{:ok, result, [effect]}`
  # with `{:set, key, value}` for the multi-key slice mutation.

  # `caps: [:publish]` ⇒ atom; the macro's auto-derived `required_caps/0`
  # would produce `cap(:any, _, :publish)`. We override below to pin
  # the `:external_mirror_worker` kind axis Step 5.5 expects.
  action :publish,
    args: %{},
    returns: %{ok: :boolean, cursor: :integer},
    caps: [:publish],
    modes: [:cast],
    description:
      "publish a Publisher event to an external system via the bound adapter+binding pair"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Explicit override — pin kind axis `:external_mirror_worker`.
  def required_caps do
    %{
      publish: Ezagent.Capability.cap(:external_mirror_worker, __MODULE__, :publish)
    }
  end

  def state_slice, do: :external_mirror_worker

  def init_slice(args) do
    # SPEC §8.3 r4 HIGH-1 fix: minimal slice. NO Publisher.subscribe_from
    # here (would deadlock — see Behavior.post_init/2 + handle_continue/3
    # below). NO binding.init/1 either (transport open is the binding
    # module's job, deferred to handle_continue/3).
    %{
      session_uri: Map.fetch!(args, :session_uri),
      adapter_id: Map.fetch!(args, :adapter_id),
      target_id: Map.fetch!(args, :target_id),
      opts: Map.get(args, :opts, %{}),
      adapter_module: nil,
      binding_module: nil,
      binding_state: nil,
      subscription_state: :pending,
      publisher_cursor: :latest,
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
      # in Feishu. The worker dedupes by tracking the most recently
      # published message_id; if a publish event's payload carries
      # the same `last_message_id`, the worker skips before invoking
      # the adapter — no HTTP call, no Feishu duplicate.
      last_published_message_id: nil
    }
  end

  @doc """
  Defer Publisher subscription + binding transport-open until AFTER
  `:announce_ready`. The PR-EM-CORE post-init hook handles the
  chaining; see SPEC §6.1 + §8.3 for the deadlock rationale.

  Returning `{:continue, :subscribe_and_init}` populates
  `Kind.Server`'s `post_init_queue`; the queue drains via
  `handle_continue/3` below.
  """
  def post_init(_args, _slice), do: {:continue, :subscribe_and_init}

  @doc """
  Subscribe to the Session Publisher + open the binding's transport.
  Runs after `:announce_ready` (PR-EM-CORE invariant — see
  `Ezagent.Kind.Server` moduledoc).

  Both calls go through the lookup-then-act pattern:
  1. Resolve `adapter_module` + `binding_module` from registries
     (raises on missing — structural error per SPEC §5.2).
  2. Subscribe `self()` to the Session Publisher at cursor `:latest`
     (no replay — V1 fire-and-forget per OQ-EM-10).
  3. Call `binding_module.init({target_id, adapter_module, opts})`
     to open the transport.
  4. On success → flip `subscription_state` to `:active` + store
     `binding_state` + the resolved modules in the slice.
  5. On binding init failure → raise (let-it-crash; PerBindingSupervisor
     restarts per `:permanent` budget per SPEC §6.2).
  """
  def handle_continue(:subscribe_and_init, slice, %{self_uri: self_uri}) do
    adapter_module = AdapterRegistry.lookup!(slice.adapter_id)
    binding_module = BindingRegistry.lookup!(slice.adapter_id)

    # SPEC §6.1: subscribe via the Publisher API (NOT
    # Phoenix.PubSub.subscribe — invariant 4 enforced by PR-EM-FINAL
    # grep gate). For PR-EM-2 we use the 4-ary form on
    # `Ezagent.Entity.Session.subscribe_from/4` with the Worker's
    # OWN URI as caller + a synthetic delegation cap so step 5.5
    # admits the subscribe. PR-EM-3 will replace the synthetic cap
    # with the formal scope-bounded `{:within_session, session_uri}`
    # delegation per SPEC §7.3 Cap 3.
    {:ok, current_cursor} = subscribe_to_session_publisher(slice.session_uri, self_uri)

    # Task #49 (2026-05-27) — subscribe to the Session's lifecycle
    # topic so we get a kick if the Session is cold-spawned later.
    # On `:publisher_alive` we re-run `subscribe_to_session_publisher/2`
    # to re-attach our (still-live) pid to the new (empty)
    # `:publisher.subscribers` map. See `Ezagent.PublisherLifecycle`
    # moduledoc + `handle_kind_message/3` `:publisher_alive` clause
    # below.
    :ok = Ezagent.PublisherLifecycle.subscribe(slice.session_uri)

    case binding_module.init({slice.target_id, adapter_module, slice.opts}) do
      {:ok, binding_state} ->
        new_slice = %{
          slice
          | adapter_module: adapter_module,
            binding_module: binding_module,
            binding_state: binding_state,
            subscription_state: :active,
            publisher_cursor: current_cursor
        }

        {:ok, new_slice}

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
  Multi-clause `handle_kind_message/3` covering:

  - `{:publisher_event, %Event{}}` — Publisher event from Session; self-
    dispatch the `:publish` action so step 5.5 CapBAC + audit + telemetry +
    idempotency apply (P14 hygiene).
  - `{:publisher_alive, %URI{}}` — Session lifecycle handshake (task #49);
    re-subscribe the still-alive Worker pid to a newly cold-spawned Session's
    publisher slice (which loads with `:subscribers = %{}` per CONCERN #3).
  - `{:ezagent_worker_resubscribe_retry, attempt}` — bounded retry tick for
    the `:not_ready` defence-in-depth backoff (see `attempt_resubscribe/3`).
  - `_other` — ignored.

  Slice mutation on the `:publisher_alive` + retry clauses updates
  `publisher_cursor`; the publisher-event and retry-pending clauses return
  `:ignore` so `Kind.Server` skips the snapshot commit path.
  """
  def handle_kind_message(message, slice, ctx)

  def handle_kind_message({:publisher_event, %Event{} = event}, slice, %{self_uri: self_uri}) do
    if slice.subscription_state == :active do
      dispatch_publish_to_self(self_uri, event)
    else
      # Defensive: events shouldn't arrive while subscription_state
      # is :pending (we're not subscribed yet). Log + drop per
      # latest-wins (SPEC §3).
      Logger.warning(
        "ExternalMirrorWorker received publisher_event while subscription_state=:pending; " <>
          "dropping (latest-wins per SPEC §3). uri=#{URI.to_string(self_uri)}"
      )
    end

    :ignore
  end

  # Task #49 (2026-05-27) — Session lifecycle event hook. See the
  # `handle_kind_message/3` function-head moduledoc above.
  def handle_kind_message({:publisher_alive, %URI{} = pub_uri}, slice, %{self_uri: self_uri}) do
    cond do
      URI.to_string(pub_uri) != URI.to_string(slice.session_uri) ->
        # Lifecycle event for a different Session. Topic shape is
        # per-URI so this shouldn't happen, but be paranoid.
        :ignore

      slice.subscription_state != :active ->
        # Our own handle_continue hasn't completed yet — the
        # subscribe_to_session_publisher inside it will pick up the
        # current cursor. Skip the re-subscribe.
        :ignore

      true ->
        attempt_resubscribe(slice, self_uri, 1)
    end
  end

  # Task #49 codex round-1 FAIL #6 (2026-05-27) — retry tick for the
  # defence-in-depth `:not_ready` backoff (see `attempt_resubscribe/3`).
  # See the `handle_kind_message/3` function-head moduledoc above.
  def handle_kind_message({:ezagent_worker_resubscribe_retry, attempt}, slice, %{
        self_uri: self_uri
      }) do
    if slice.subscription_state == :active do
      attempt_resubscribe(slice, self_uri, attempt)
    else
      :ignore
    end
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  # Task #49 codex round-1 FAIL #6 — bounded retry on `{:error, :not_ready}`.
  #
  # Primary fix is `Ezagent.Behavior.Publisher.SessionImpl.on_ready/2`
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
  # Idempotency: the worker dedupes by `last_published_message_id`
  # in `invoke(:publish, ...)`. Replayed events for messages the
  # worker already published get `:duplicate_skip` — no second
  # outbound transport call.
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
  # the first subscribe in `handle_continue/3` IS the first
  # subscribe.

  defp attempt_resubscribe(slice, self_uri, attempt) do
    case subscribe_to_session_publisher_from(
           slice.session_uri,
           self_uri,
           slice.publisher_cursor
         ) do
      {:ok, current_cursor} ->
        {:ok, %{slice | publisher_cursor: current_cursor}}

      {:error, :cursor_out_of_window} ->
        # Persisted cursor is older than the publisher's retention
        # ring; the missed events are gone. Re-subscribe at :latest
        # to restore the live wire. Operator-visible via the
        # cursor-out-of-window log.
        Logger.warning(
          "ExternalMirrorWorker re-subscribe: persisted cursor " <>
            "#{inspect(slice.publisher_cursor)} older than publisher retention; " <>
            "falling back to :latest. session=#{URI.to_string(slice.session_uri)}"
        )

        case subscribe_to_session_publisher_from(slice.session_uri, self_uri, :latest) do
          {:ok, current_cursor} ->
            {:ok, %{slice | publisher_cursor: current_cursor}}

          {:error, reason} ->
            Logger.warning(
              "ExternalMirrorWorker re-subscribe (fallback :latest) failed; " <>
                "session=#{URI.to_string(slice.session_uri)} reason=#{inspect(reason)}"
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
            "session=#{URI.to_string(slice.session_uri)} reason=#{inspect(reason)}"
        )

        :ignore
    end
  end

  @doc """
  PR-EM-2 codex round-1 HIGH-1 fix (2026-05-25): graceful shutdown
  hook — invoked by `Ezagent.Kind.Server.terminate/2` on Kind
  exit. Calls `binding_module.terminate(reason, binding_state)`
  per SPEC §6.2 ("`terminate/2` runs on graceful unbind ... the
  Worker Kind's `terminate/2` callback calls the binding module's
  `terminate/2` to release transport resources").

  Defensive: if the Binding's terminate is not exported (optional
  per SPEC §2.3), skip. If the slice was never advanced past
  `:pending` (e.g. terminate during handle_continue), there's no
  binding_state to clean up — skip.
  """
  def terminate(reason, slice, _ctx) do
    cond do
      slice.subscription_state != :active ->
        # Binding never finished init (still :pending) — no
        # transport handle to release.
        :ok

      not is_atom(slice.binding_module) ->
        :ok

      not function_exported?(slice.binding_module, :terminate, 2) ->
        # Binding.terminate/2 is optional per SPEC §2.3.
        :ok

      true ->
        try do
          _ = slice.binding_module.terminate(reason, slice.binding_state)
          :ok
        rescue
          err ->
            Logger.warning(
              "ExternalMirrorWorker: binding #{inspect(slice.binding_module)}.terminate/2 " <>
                "raised on shutdown (#{inspect(err)}); transport resources may leak. " <>
                "binding_id=#{slice.adapter_id}/#{inspect(slice.target_id)}"
            )

            :ok
        end
    end
  end

  # ----- The :publish action ------------------------------------------------

  # Phase 2-d r3: `handle_publish/2` replaces `invoke(:publish, ...)`.
  # The slice (all keys initialised by `init_slice/1`) is reconstructed
  # from `ctx[:read]` so `do_invoke_publish/3` (kept verbatim from the
  # pre-migration body) operates on the same in-memory shape.
  # `translate_publish_return/2` emits one `:set` effect per slice
  # field the handler actually mutates — preserving the dispatch
  # pipeline's slice_change_event diff semantics.
  def handle_publish(%{event: %Event{} = event}, ctx) do
    slice = read_full_slice(ctx)

    # 2026-05-26 (Allen e2e Bug 5): dedupe by last_message_id BEFORE
    # calling the adapter. Every chat-slice mutation (presence,
    # member join, last_seen) emits a publisher_event with the
    # current `last_message` in `new_slice`; without this dedupe the
    # adapter sees `chat_send_occurred?(new_slice, nil) == true` for
    # ALL of them and re-publishes the SAME message N times to
    # Feishu (Allen got 4 copies of one cc reply). The cursor field
    # also advances on every mutation so we can't use it as the
    # dedupe key — last_message_id is the stable invariant per
    # actual chat.send.
    event_msg_id = extract_event_message_id(event)

    legacy_result =
      cond do
        not is_nil(event_msg_id) and event_msg_id == slice.last_published_message_id ->
          new_slice = %{
            slice
            | publisher_cursor: event.cursor,
              count: slice.count + 1,
              last_publish_result: :duplicate_skip,
              last_published_at: DateTime.utc_now()
          }

          {:ok, new_slice, %{ok: true, cursor: event.cursor, skipped: true}}

        true ->
          do_invoke_publish(slice, event, event_msg_id)
      end

    translate_publish_return(slice, legacy_result)
  end

  # Reconstruct the in-memory slice shape `do_invoke_publish/3` expects.
  # The `:default` map mirrors `init_slice/1`'s shape so a slice that
  # hasn't been fully written (e.g. a Worker still in `:pending`) reads
  # back as documented.
  defp read_full_slice(ctx) do
    %{
      session_uri: ctx[:read].(:session_uri, nil),
      adapter_id: ctx[:read].(:adapter_id, nil),
      target_id: ctx[:read].(:target_id, nil),
      opts: ctx[:read].(:opts, %{}),
      adapter_module: ctx[:read].(:adapter_module, nil),
      binding_module: ctx[:read].(:binding_module, nil),
      binding_state: ctx[:read].(:binding_state, nil),
      subscription_state: ctx[:read].(:subscription_state, :pending),
      publisher_cursor: ctx[:read].(:publisher_cursor, :latest),
      count: ctx[:read].(:count, 0),
      error_count: ctx[:read].(:error_count, 0),
      last_published_at: ctx[:read].(:last_published_at, nil),
      last_publish_result: ctx[:read].(:last_publish_result, nil),
      last_published_message_id: ctx[:read].(:last_published_message_id, nil)
    }
  end

  # Translate `{:ok, new_slice, result}` from legacy `do_invoke_publish/3`
  # into `{:ok, result, [{:set, key, value}, ...]}`. We emit one `:set`
  # per CHANGED slice key (skip unchanged) so the slice_change_event
  # diff (`new_slice != slice` in `Kind.Runtime.handle_dispatch/4`)
  # fires identically to the pre-migration path.
  @publish_slice_keys [
    :binding_state,
    :publisher_cursor,
    :count,
    :error_count,
    :last_publish_result,
    :last_published_at,
    :last_published_message_id
  ]

  defp translate_publish_return(old_slice, {:ok, new_slice, result}) do
    # `:publish` only ever returns `{:ok, _, _}` (recoverable transport
    # failures are folded into the success path with bumped
    # `error_count`); the legacy `{:error, _}` branch from the
    # `Ezagent.Behavior.invoke_return/0` typespec is unreachable here.
    effects =
      Enum.flat_map(@publish_slice_keys, fn key ->
        old_val = Map.get(old_slice, key)
        new_val = Map.get(new_slice, key)

        if old_val == new_val do
          []
        else
          [{:set, key, new_val}]
        end
      end)

    {:ok, result, effects}
  end

  # ----- internals -----

  # Extract the message_id from the publisher event's payload. Only the
  # :chat slice carries a `:last_message` ezagent.Message struct;
  # other slices return nil (and we fall through to adapter-side
  # `:skip`). String and atom keys are both accepted because the
  # MessageStore JSON roundtrip serialises atom keys as strings.
  defp extract_event_message_id(%Event{payload: %{} = payload, slice_key: :chat}) do
    new_slice = Map.get(payload, :new_slice) || Map.get(payload, "new_slice")

    case new_slice do
      %{last_message: %Ezagent.Message{id: id}} -> id
      %{"last_message" => %Ezagent.Message{id: id}} -> id
      _ -> nil
    end
  end

  defp extract_event_message_id(_), do: nil

  defp do_invoke_publish(slice, %Event{} = event, event_msg_id) do
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
                last_published_message_id: event_msg_id
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
  # `use Ezagent.Behavior` from the `action :publish, ...` declaration
  # at the top of this module. The legacy explicit `interface/0` was
  # removed as part of the Phase 2-d r3 migration.

  @doc """
  SPEC §4.3: Worker Kinds are framework-internal; only bootstrap
  admin can grant caps. Users never hold caps on `entity://worker/...`
  URIs directly — the Session Kind holds a scope-bounded delegation
  cap (PR-EM-3 will wire this) per SPEC §7.3 Cap 3.
  """
  def data_owner(%URI{scheme: "entity", host: "worker"} = _worker_uri), do: :no_owner
  def data_owner(:any), do: :no_owner
  def data_owner({:scope, :within_session, %URI{}}), do: :no_owner
  def data_owner(_), do: :no_owner

  # ----- internals ----------------------------------------------------------

  # PR-EM-2 wiring of Publisher.subscribe_from. Uses an inline
  # admin-elevated ctx for the subscribe so step 5.5 admits the
  # call — PR-EM-3 replaces this with the formal scope-bounded
  # cap (`{:within_session, session_uri}` per SPEC §7.3 Cap 3)
  # delegated to the Session Kind at bind time.
  #
  # codex round-1 STRUCTURAL fix (2026-05-25): the PR-EM-2 deferral
  # to PR-EM-3 covers BOTH internal dispatch sites — `subscribe_to_
  # session_publisher/2` AND `dispatch_publish_to_self/2` (the
  # `:publish` self-cast on `{:publisher_event, _}` mailbox
  # message). Both currently use the inline admin caps; PR-EM-3
  # will:
  #
  #   - subscribe path: switch to the scope-bounded
  #     `{:within_session, session_uri}` Cap 3 delegated at bind time
  #   - publish path: switch to the Worker's own default-granted
  #     publish cap (auto-granted on spawn per SPEC §7.3 Cap 3 +
  #     caps-data-ownership §4.1)
  #
  # The Worker NEVER accepts admin caps from external callers;
  # admin caps appear ONLY in these two internal self-dispatches
  # for the structural reason that ezagent's dispatch pipeline
  # has no ambient-caps mechanism (every Invocation.dispatch/1
  # requires explicit ctx.caps per CapBAC step 5.5).
  #
  # We don't call `Ezagent.Entity.Session.subscribe_from/4`
  # directly: `:ezagent_domain_chat` depends on
  # `:ezagent_domain_external_mirror` (for the Publisher contract),
  # so a reverse reference here would form a Mix dep cycle.
  # The dispatch goes through `?action=publisher.subscribe_from`
  # — identical wire-shape to what `Session.subscribe_from/4`
  # constructs (SPEC §8.1).
  defp subscribe_to_session_publisher(%URI{} = session_uri, %URI{} = self_uri) do
    # First subscribe (from `handle_continue/3`) — no prior cursor,
    # `:latest` is correct (V1 fire-and-forget per OQ-EM-10).
    subscribe_to_session_publisher_from(session_uri, self_uri, :latest)
  end

  # Task #49 codex r3 NEW CHECK C — catchup-on-resubscribe.
  #
  # `cursor` is either:
  #   - `:latest` (no replay; same as the original `subscribe_to_session_publisher/2`)
  #   - non-negative integer (Publisher replays events with cursor > given)
  #
  # The Publisher's `prepare_replay/2` returns the events; `subscribe_from`
  # `send/2`s each one to `subscriber_pid` BEFORE returning. By the time
  # this call returns `{:ok, current_cursor}` the replay messages are
  # already in our mailbox (or will be — same process can't out-pace its
  # own GenServer reply). They land in `handle_kind_message/3` as
  # `{:publisher_event, %Event{}}` and self-dispatch through the regular
  # `:publish` path — same dedupe, same telemetry.
  defp subscribe_to_session_publisher_from(%URI{} = session_uri, %URI{} = self_uri, cursor) do
    target = Ezagent.URI.parse!("#{URI.to_string(session_uri)}?action=publisher.subscribe_from")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{subscriber_pid: self(), cursor: cursor},
      # SPEC caps-cleanup-v1 §4.4 — Worker's internal dispatches run
      # under `system://worker-publish` per the closed Catalog.
      ctx: %{
        caller: self_uri,
        caps: Ezagent.SystemPrincipal.caps("system://worker-publish"),
        reply: :ignore,
        # 2026-05-26 (Allen e2e blocker): Session.handle_call queues
        # subscribe_from behind concurrent list_bindings polls, chat
        # mutations, and snapshot.commit cycles (each writing ~30KB
        # state binary to SQLite). Under steady-state polling the
        # default 5s `deadline_ms` is too tight — the call times out
        # and the worker exits, supervisor restarts it, and the cycle
        # accumulates dead subscriber pids in the Publisher slice
        # (each fresh worker subscribes with a NEW pid that gets
        # monitored; DOWN fires only after replacement). Bumping
        # subscribe_from's deadline to 30s lets the call complete
        # under realistic load. Bind/publish flows have their own
        # deadlines; this only widens the SETUP path.
        deadline_ms: 30_000
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, %{cursor: new_cursor}} -> {:ok, new_cursor}
      {:error, _} = err -> err
      :ok -> {:ok, :latest}
    end
  end

  defp dispatch_publish_to_self(%URI{} = self_uri, %Event{} = event) do
    target = Ezagent.URI.parse!("#{URI.to_string(self_uri)}?action=external_mirror_worker.publish")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{event: event},
      # SPEC caps-cleanup-v1 §4.4 — Worker outbound publish runs
      # under `system://worker-publish` (closed Catalog).
      ctx: %{
        caller: self_uri,
        caps: Ezagent.SystemPrincipal.caps("system://worker-publish"),
        reply: :ignore,
        idempotency_key: "external_mirror_worker.publish/#{event.cursor}"
      }
    })
  end
end
