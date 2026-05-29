defmodule Ezagent.Behavior.Publisher.SessionImpl do
  @moduledoc """
  Kind-Behavior implementing `Ezagent.Behavior.Publisher` semantics for
  `Ezagent.Entity.Session` (the V1 publisher per SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §2.1,
  Allen's option (a)).

  Added to `Ezagent.Entity.Session.behaviors/0` so every Session Kind
  boots with a `:publisher` slice and self-subscribes to its own
  `Ezagent.SliceChange` topic via `post_init/2`.

  ## Where this module lives

  In `apps/ezagent_domain_chat/` — the SessionImpl is Session-specific
  code (reads `Session.owner/1` for `data_owner/1`), so it lives next
  to the Kind it implements. The Publisher CONTRACT
  (`Ezagent.Behavior.Publisher`) + Event struct live in
  `apps/ezagent_domain_external_mirror/` (the new Domain) — chat
  depends on external_mirror for the contract; external_mirror has
  zero reverse references to chat.

  ## Why one Behavior instead of two

  The SPEC §8.1 wording mentions a "cap-only `Behavior.Publisher`" but
  the codebase's `Ezagent.CapabilityRegistry.register/3` (Tier-1)
  raises on `{kind, action}` conflict — a single action cannot have
  both a cap-only subject AND a separate dispatchable handler. So
  the publisher actions live on ONE dispatchable Behavior whose
  declared actions are the cap shape and whose `handle_<action>/2`
  are the handlers. Step 5.5 (CapBAC) still gates every dispatch via
  this Behavior's cap subjects — the SPEC's gating guarantee holds.

  ## :publisher slice shape

      %{
        ring:           [%Ezagent.Publisher.Event{}, ...], # newest-last
        cursor:         non_neg_integer(),                 # last-issued cursor; init 0
        retention:      pos_integer(),                     # max ring length; V1 default 100
        subscribers:    %{pid() => reference()},           # pid -> monitor ref
        monitors:       %{reference() => pid()}            # monitor ref -> pid (reverse lookup)
      }

  Two maps (subscribers + monitors) so `:DOWN` cleanup is O(log n) on
  the monitor ref without scanning all subscribers (same pattern as
  `Ezagent.Behavior.Chat`'s members + monitors).

  ## post_init self-subscription

  `post_init/2` returns `{:continue, :subscribe_to_self_slice_change}`
  so the Kind's Server runs `handle_continue/3` AFTER `:announce_ready`
  is published. The continuation calls
  `Ezagent.SliceChange.subscribe_unverified(self_uri)` (same-VM trust
  per PR-N1 round-5 disposition — the Session Kind subscribing to its
  OWN topic at boot is the canonical legitimate use of the unverified
  primitive; the Kind's pid IS the topic owner). Subscription is
  idempotent on PubSub level — a snapshot-restored Session that
  re-runs `post_init/2` re-subscribes without dup-fan-out (PubSub
  dedups identical {pid, topic} pairs).

  ## handle_kind_message hook

  - `{:slice_changed, event}` from `Ezagent.SliceChange` —
    bumps cursor, builds `%Ezagent.Publisher.Event{}`, appends to
    ring (trimming to `retention`), fans out to all live subscribers.
    Skips events from OTHER URIs (the topic shape `esr:entity:<uri>:slice_changed`
    means this shouldn't happen, but defensively pattern-matches on
    `:self_uri == ctx.self_uri`).
  - `{:DOWN, ref, :process, _, _}` — removes the subscriber (best-
    effort cleanup; subscribers that come back via a new pid must
    re-subscribe).

  ## Dispatch actions

  - `:subscribe_from` — args `%{subscriber_pid, cursor}` —
    monitors pid, replays history per cursor semantics, returns the
    current cursor.
  - `:snapshot` — args `%{}` — returns `%{cursor, state}`.
  - `:history` — args `%{from, to}` — returns events in
    `(from, to]` window.

  All three are `:call` mode — the result is read by the caller.

  ## Migration note (P2-a r3, 2026-05-28)

  Migrated to the new SPEC 2026-05-28 action grammar. The handlers
  mutate the slice via `{:set, key, value}` effects. `:subscribe_from`
  still does `send/2` to the subscriber (a pid handle write, not a
  PubSub broadcast) — kept in-handler because the call returns the
  cursor synchronously and the per-replay-event sends are inherently
  imperative and aimed at a specific pid (not a topic).
  """

  use Ezagent.Behavior

  require Logger

  alias Ezagent.Publisher.Event

  # V1 retention default per OQ-EM-A (Allen 2026-05-24 — option (a),
  # count-based). Implementers can override `history_retention/0` on
  # the publisher Kind module (Session does — see `Ezagent.Entity.Session`).
  @default_retention 100

  # ----- Ezagent.Behavior callbacks --------------------------------------

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Publisher.SessionImpl is registered on Session Kind only — kind axis
  # is `:session`.

  action :subscribe_from,
    # `args: %{}` for all three actions — the InterfaceValidator's
    # schema grammar does not have a `:pid` or `:any` atom (see
    # `Ezagent.InterfaceValidator` @moduledoc), and the publisher
    # actions pass typed-but-unrestricted runtime values (a `pid()`,
    # the polymorphic `cursor()` sentinel-or-integer, the
    # `from`/`to` window endpoints). Argument shape is enforced by
    # the handler (Map.fetch! on required keys + guard clauses on
    # type) — the validator pre-check just confirms args is a map.
    args: %{},
    returns: %{cursor: :integer},
    caps: [:subscribe_from],
    modes: [:call],
    description:
      "Subscribe a pid to this Publisher's structured stream from a cursor " <>
        "(:latest / :earliest / integer)"

  action :snapshot,
    args: %{},
    returns: %{cursor: :integer},
    caps: [:snapshot],
    modes: [:call],
    description: "Read this Publisher's current cursor + state without subscribing"

  action :history,
    args: %{},
    returns: %{},
    caps: [:history],
    modes: [:call],
    description: "Read events in the (from, to] cursor window from this Publisher's ring"

  @doc """
  Per SPEC §2.1: the Publisher cap is gated on the publishing Kind
  (the Session). Session caps' data_owner is the user/agent that
  created the session (same rule as `Ezagent.Behavior.Chat.data_owner/1`).
  Reads via `Ezagent.Kind.get_slice/2` on the `:chat` slice's
  `:owner_uri` field — caps-data-ownership SPEC #306 §7.

  `:any` (workspace-scoped publisher caps) → workspace admin grants.
  Concrete session URI → that session's owner.
  """
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner_uri} -> Ezagent.URI.instance(owner_uri)
      {:ok, nil} -> :no_owner
      {:error, _} -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner({:within_workspace, %URI{}}), do: :any
  def data_owner(_), do: :no_owner

  def state_slice, do: :publisher

  def init_slice(args) do
    retention =
      case Map.get(args, :publisher_retention) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_retention
      end

    %{
      ring: [],
      cursor: 0,
      retention: retention,
      subscribers: %{},
      monitors: %{}
    }
  end

  @doc """
  Schedules a post-init continuation to subscribe this Kind's pid to
  its OWN SliceChange topic (PR-EM-CORE hook + r4 split-init pattern).

  Returns `{:continue, :subscribe_to_self_slice_change}` so the
  subscribe runs AFTER `:announce_ready` — by the time SliceChange
  events flow, the Kind is reachable for dispatch.

  NOTE: the `:publisher_alive` lifecycle broadcast does NOT happen
  here — it lives in `on_ready/2` so it fires AFTER
  `Ezagent.ReadyGate.mark_ready/1` flips. See `on_ready/2` doc +
  task #49 codex round-1 FAIL #6.
  """
  def post_init(_args, _publisher_slice) do
    {:continue, :subscribe_to_self_slice_change}
  end

  def handle_continue(:subscribe_to_self_slice_change, _publisher_slice, %{self_uri: self_uri}) do
    :ok = Ezagent.SliceChange.subscribe_unverified(self_uri)

    # Slice unchanged — return `:ignore` so the Server skips the
    # snapshot commit path (we just opened a PubSub subscription;
    # no slice mutation).
    :ignore
  end

  @doc """
  Task #49 codex round-1 FAIL #6 (2026-05-27) — broadcast the
  `:publisher_alive` lifecycle event AFTER
  `Ezagent.ReadyGate.mark_ready/1` has flipped this Session to
  `:ready` and the PendingDelivery buffer has drained.

  Previously this broadcast lived in `handle_continue/3`, which
  runs BEFORE ReadyGate flips. Cold-spawn flow:

      Session.handle_continue → broadcast :publisher_alive
                              → Worker receives event
                              → Worker calls subscribe_to_session_publisher (mode :call)
                              → Router.dispatch sees Session ReadyGate :not_ready
                              → returns {:error, :not_ready}
                              → Worker logs + discards (no retry)
                              → SILENT FAIL on cold-spawn — the exact case this
                                mechanism was meant to fix.

  Moving the broadcast to `on_ready/2` ensures the Worker's
  re-subscribe `:call` finds the Session `:ready`. The Worker also
  carries a defence-in-depth retry on `{:error, :not_ready}` (see
  `Ezagent.Behavior.ExternalMirrorWorker.handle_kind_message/3`
  `:publisher_alive` clause) — primary fix is the on_ready ordering;
  the retry is the belt-and-braces backup.
  """
  def on_ready(_publisher_slice, %{self_uri: self_uri}) do
    :ok = Ezagent.PublisherLifecycle.broadcast_alive(self_uri)
  end

  @doc """
  Task #49 codex round-1 CONCERN #3 (2026-05-27) — clear transient
  `:subscribers` + `:monitors` maps on snapshot load.

  Why transient: the Publisher slice's `:subscribers` map keys are
  `pid()` values + the `:monitors` map values are monitor `reference()`
  values. Both are BEAM-local handles to live processes — a snapshot
  binary written by ONE BEAM that's then loaded by a DIFFERENT BEAM
  (cold-spawn, BEAM restart) holds non-routable / stale handles.
  `Process.alive?/1` on a stale pid from another BEAM returns `false`
  (or worse, the local BEAM has reassigned that pid number to a new
  process); a stale monitor reference cannot be demonitored on a
  remote BEAM.

  Worse: the pre-task-#49 lifecycle-broadcast handshake relies on
  `ensure_monitored/2` to dedupe by pid (the publisher's "already
  subscribed" fast path). If the snapshot persisted a `subscribers`
  entry like `%{<stale_pid> => <stale_ref>}`, a fresh worker
  attempting to subscribe (which has the SAME pid number by sheer
  bad luck — pid reuse IS a thing in long-running BEAMs) would be
  recognised as "already subscribed", `ensure_monitored/2` skips
  the monitor install, the worker pid is recorded but no monitor
  exists, AND the Publisher fans out events to a non-routable
  handle (the stale ref).

  Clearing both maps on every snapshot load makes the transient
  membership EXPLICIT: every restart starts with an empty subscribers
  map; live workers re-subscribe via the lifecycle handshake. The
  `:ring`, `:cursor`, and `:retention` fields are durable and
  preserved.

  Idempotent: re-running on an already-cleared slice is a no-op
  (already `%{}`). Matches the task #34 `reconcile_after_load/2`
  contract for DB-projection slices.
  """
  def reconcile_after_load(_uri, publisher_slice) do
    %{publisher_slice | subscribers: %{}, monitors: %{}}
  end

  # ----- Kind-message hook ----------------------------------------------

  @doc """
  Receives `{:slice_changed, event}` from `Ezagent.SliceChange` (our
  own topic — we subscribed in `post_init/2`'s continuation) and
  `{:DOWN, ref, :process, pid, reason}` from `Process.monitor/1` of
  subscriber pids.

  Slice-changed events are filtered to those whose `self_uri` matches
  the Kind's own URI (defence-in-depth — the topic IS per-URI but a
  caller error could broadcast to the wrong topic and we don't want
  to mirror foreign data).

  Importantly, slice changes to the `:publisher` slice itself are
  IGNORED (they would re-trigger an emit-loop: a subscriber being
  added mutates `:publisher.subscribers`, which becomes its own
  slice-change event, which would add an entry to the ring). The
  Publisher mirrors slice changes from OTHER slices (`:chat` etc).
  """
  def handle_kind_message({:slice_changed, %{} = event}, publisher_slice, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    cond do
      not is_publisher_target?(event, self_uri) ->
        :ignore

      Map.get(event, :slice_key) == :publisher ->
        # Don't mirror our own bookkeeping mutations.
        :ignore

      true ->
        new_cursor = publisher_slice.cursor + 1

        publisher_event = %Event{
          cursor: new_cursor,
          publisher_uri: self_uri,
          slice_key: Map.get(event, :slice_key),
          # PR-N3 codex r2 HIGH-1: envelope field renamed `:at` -> `:event_at`.
          event_at: Map.get(event, :event_at) || DateTime.utc_now(),
          payload: build_payload(event, ctx)
        }

        new_ring =
          append_with_retention(publisher_slice.ring, publisher_event, publisher_slice.retention)

        fan_out(publisher_event, publisher_slice.subscribers)

        {:ok, %{publisher_slice | ring: new_ring, cursor: new_cursor}}
    end
  end

  def handle_kind_message({:DOWN, ref, :process, _pid, _reason}, publisher_slice, _ctx) do
    case Map.pop(publisher_slice.monitors, ref) do
      {nil, _} ->
        # Not one of our refs (could belong to another Behavior on
        # the same Kind — Chat also monitors pids).
        :ignore

      {pid, new_monitors} ->
        new_subscribers = Map.delete(publisher_slice.subscribers, pid)
        {:ok, %{publisher_slice | subscribers: new_subscribers, monitors: new_monitors}}
    end
  end

  def handle_kind_message(_other, _publisher_slice, _ctx), do: :ignore

  # ----- Handlers -------------------------------------------------------

  def handle_subscribe_from(args, ctx) do
    subscriber_pid = Map.fetch!(args, :subscriber_pid)
    cursor = Map.get(args, :cursor, :latest)

    unless is_pid(subscriber_pid) do
      raise ArgumentError,
            "publisher_subscribe_from: :subscriber_pid must be a pid, got #{inspect(subscriber_pid)}"
    end

    current_publisher_slice = current_slice(ctx)

    case prepare_replay(current_publisher_slice, cursor) do
      {:error, reason} ->
        {:error, reason}

      {:ok, replay_events} ->
        Enum.each(replay_events, fn %Event{} = ev ->
          send(subscriber_pid, {:publisher_event, ev})
        end)

        # 2026-05-26 (Allen e2e perf fix): proactively flush dead-pid
        # entries before adding the new subscriber. Without this, a
        # worker restart storm (where each restarted worker re-subscribes
        # with a NEW pid before the DOWN for the previous pid is
        # processed) ratchets `subscribers` size every cycle. Every
        # write to `subscribers` triggers an `:on_change` snapshot.write
        # of the full Session state binary (~30KB); compounded across
        # 100s of restarts the Session's mailbox queues up enough work
        # that subsequent subscribe_from calls hit their 5s deadline
        # before they're even dequeued. Filter is O(N) over a bounded
        # subscribers map — cheap when small, surfaces the leak
        # immediately when large.
        flushed_publisher_slice = prune_dead_subscribers(current_publisher_slice)
        {_ref, new_publisher_slice} = ensure_monitored(flushed_publisher_slice, subscriber_pid)

        # Three fields can change vs the source: subscribers, monitors.
        # Use a single `:set` per field so the effect grammar's snapshot
        # writes are surgical (vs replacing the whole slice).
        {:ok, %{cursor: current_publisher_slice.cursor},
         [
           {:set, :subscribers, new_publisher_slice.subscribers},
           {:set, :monitors, new_publisher_slice.monitors}
         ]}
    end
  end

  def handle_snapshot(_args, ctx) do
    current = current_slice(ctx)

    state =
      case List.last(current.ring) do
        nil -> nil
        %Event{payload: payload} -> payload
      end

    {:ok, %{cursor: current.cursor, state: state}, []}
  end

  def handle_history(args, ctx) do
    current = current_slice(ctx)
    from = Map.get(args, :from, :earliest)
    to = Map.get(args, :to, :latest)

    case window(current, from, to) do
      {:ok, events} -> {:ok, %{events: events}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----- Internals ------------------------------------------------------

  # Reconstruct the current publisher slice from ctx[:read]/2. The new
  # contract doesn't pass the slice as an arg; instead each field is
  # read on demand. We re-materialise the slice as a map for the
  # internal helpers (window/3, prepare_replay/2, etc).
  defp current_slice(ctx) do
    %{
      ring: ctx[:read].(:ring, []),
      cursor: ctx[:read].(:cursor, 0),
      retention: ctx[:read].(:retention, @default_retention),
      subscribers: ctx[:read].(:subscribers, %{}),
      monitors: ctx[:read].(:monitors, %{})
    }
  end

  # Default retention used when `init_slice/1` is called without
  # publisher_retention (the Session implementation reads
  # `Ezagent.Behavior.Publisher.history_retention/0` on Session and
  # threads it through; this constant is the documented fallback).
  @doc false
  def default_retention, do: @default_retention

  # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25) — SliceChange's broadcast
  # envelope is now security-minimal (`uri / slice_key / cursor /
  # event_at / result_summary`). The `self_uri` field is renamed
  # `uri` and the slice-content fields (`new_slice`/`old_slice`/
  # `result`/`action`/`caller`) are stripped. We update the target
  # check to read `:uri` and re-fetch the slice via `Kind.get_slice/2`
  # in `build_payload/2` — same trust boundary because the Publisher
  # Kind reads its OWN slice (the Kind's own pid runs this code).
  defp is_publisher_target?(event, self_uri) do
    case Map.get(event, :uri) do
      %URI{} = uri -> URI.to_string(uri) == URI.to_string(self_uri)
      _ -> false
    end
  end

  defp build_payload(event, ctx) do
    # PR-N3 codex r2 HIGH-1: SliceChange's broadcast envelope no
    # longer carries slice content. The Publisher reads the affected
    # slice directly from `ctx.slice_state` — `Kind.Server` injects
    # the full slice_state into ctx for exactly this case (a
    # `Kind.get_slice/2` call here would self-`GenServer.call`
    # from inside `handle_info`, which deadlocks). The Publisher
    # Kind reading its OWN state is the canonical safe read — same
    # trust domain, same process.
    #
    # `:action` / `:caller` are no longer in the envelope — adapters
    # that want a "who did this" breadcrumb must source it from
    # elsewhere (the slice's own metadata; the receiving message's
    # `:sender` field; etc.). PR-EM-0's `event_to_payload/1` adapter
    # contract doesn't currently rely on these — the payload is
    # passed through opaquely.
    slice_key = Map.get(event, :slice_key)
    slice_state = Map.get(ctx, :slice_state, %{})

    # Lifecycle Phase A (SPEC §0.1 / §10-R2, F1b) — strip the Lifecycle
    # `:transients` sub-key BEFORE the slice goes into the durable
    # Publisher ring. The ring is part of the `:publisher` slice and IS
    # persisted (`{:snapshot, :on_change}` Session); a mirrored peer
    # slice carrying live PIDs/refs/handles in `:transients` would
    # otherwise be serialized into the ring — the exact "transients never
    # persisted" violation via the indirect Publisher path. Only the
    # persistent `:state` view is mirrored. A legacy flat slice (no
    # `:transients` sub-key) passes through unchanged.
    new_slice = strip_transients(Map.get(slice_state, slice_key))

    %{
      new_slice: new_slice
    }
  end

  # Strip a Lifecycle two-container slice down to its persistent `:state`
  # view; pass a legacy flat slice (or nil) through unchanged.
  defp strip_transients(%{transients: _} = slice) when is_map(slice),
    do: Map.delete(slice, :transients)

  defp strip_transients(other), do: other

  defp append_with_retention(ring, %Event{} = event, retention) do
    new_ring = ring ++ [event]

    case length(new_ring) - retention do
      drop when drop > 0 -> Enum.drop(new_ring, drop)
      _ -> new_ring
    end
  end

  defp fan_out(%Event{} = event, subscribers) when is_map(subscribers) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:publisher_event, event})
    end)
  end

  defp ensure_monitored(publisher_slice, pid) do
    case Map.get(publisher_slice.subscribers, pid) do
      nil ->
        ref = Process.monitor(pid)

        new_publisher_slice = %{
          publisher_slice
          | subscribers: Map.put(publisher_slice.subscribers, pid, ref),
            monitors: Map.put(publisher_slice.monitors, ref, pid)
        }

        {ref, new_publisher_slice}

      ref ->
        # Already monitored — return existing ref, slice unchanged.
        {ref, publisher_slice}
    end
  end

  # 2026-05-26 (perf fix paired with the prune in `handle_subscribe_from/2`):
  # walks `publisher_slice.subscribers` and removes any pid whose process
  # is no longer alive locally. Demonitors the matching ref with
  # `:flush` so the inevitable `:DOWN` (already queued for these dead
  # pids) is swallowed rather than racing the next `handle_kind_message`.
  # If two nodes ever publish into one Session this needs to grow a
  # remote-node liveness check; today's single-node invariant lets us
  # use `Process.alive?/1`.
  defp prune_dead_subscribers(publisher_slice) do
    Enum.reduce(publisher_slice.subscribers, publisher_slice, fn {pid, ref}, acc ->
      if Process.alive?(pid) do
        acc
      else
        Process.demonitor(ref, [:flush])

        %{
          acc
          | subscribers: Map.delete(acc.subscribers, pid),
            monitors: Map.delete(acc.monitors, ref)
        }
      end
    end)
  end

  # Build the message list a subscriber receives based on `cursor`.
  defp prepare_replay(_publisher_slice, :latest), do: {:ok, []}
  defp prepare_replay(publisher_slice, :earliest), do: {:ok, publisher_slice.ring}

  defp prepare_replay(publisher_slice, cursor) when is_integer(cursor) and cursor >= 0 do
    case window(publisher_slice, cursor, :latest) do
      {:ok, events} -> {:ok, events}
      {:error, _} = err -> err
    end
  end

  defp prepare_replay(_publisher_slice, bad),
    do: {:error, {:invalid_cursor, bad}}

  # window(publisher_slice, from, to) — returns events with cursor in (from, to]:
  #   - from = :earliest  → no lower bound
  #   - from = integer    → cursor > from (exclusive)
  #   - to   = :latest    → no upper bound
  #   - to   = integer    → cursor <= to (inclusive)
  # Raises `{:error, :cursor_out_of_window}` if `from` is older than
  # the oldest retained cursor (the ring's first entry's cursor - 1).
  defp window(publisher_slice, from, to) do
    with :ok <- validate_window(publisher_slice, from, to) do
      events =
        publisher_slice.ring
        |> Enum.filter(fn %Event{cursor: c} -> in_window?(c, from, to) end)

      {:ok, events}
    end
  end

  # `:earliest` lower bound is always in-window (no lower bound at all).
  defp validate_window(_publisher_slice, :earliest, _to), do: :ok

  # Integer `from`: bounds-check + retention-check. Order matters —
  # bounds-check first (basic shape), then retention (the "is `from`
  # still in the ring?" check). The retention check fires even when
  # `to` is `:latest` because the SPEC says raise on cursor_out_of_window
  # for ANY history call whose lower bound predates the oldest
  # retained event.
  defp validate_window(publisher_slice, from, to) when is_integer(from) and from >= 0 do
    cond do
      is_integer(to) and to < from ->
        {:error, {:invalid_window, from, to}}

      true ->
        # Retention check (applies whether `to` is `:latest` or integer).
        # See `cursor_out_of_window?/2` for the semantics.
        if cursor_out_of_window?(publisher_slice, from) do
          {:error, :cursor_out_of_window}
        else
          :ok
        end
    end
  end

  defp validate_window(_publisher_slice, bad, _to), do: {:error, {:invalid_cursor, bad}}

  # `from` is out of window iff:
  #   - The publisher HAS emitted at least one event (cursor > 0),
  #     AND `from` is strictly less than oldest_retained - 1 (so even
  #     `from + 1` is no longer in the ring).
  # Equivalently: `from < oldest - 1` where `oldest` is the cursor of
  # the ring's first (oldest) entry.
  #
  # Empty ring before any emission (cursor == 0) → any `from >= 0` is
  # valid (no events yet means trivially the requested window is
  # in-bounds, the result is just `[]`).
  defp cursor_out_of_window?(%{ring: []}, _from), do: false

  defp cursor_out_of_window?(%{ring: [%Event{cursor: oldest} | _]}, from),
    do: from < oldest - 1

  defp in_window?(_c, :earliest, :latest), do: true
  defp in_window?(c, :earliest, to) when is_integer(to), do: c <= to
  defp in_window?(c, from, :latest) when is_integer(from), do: c > from

  defp in_window?(c, from, to) when is_integer(from) and is_integer(to),
    do: c > from and c <= to
end
