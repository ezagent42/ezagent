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
  `cap_subjects/0` is the cap shape and whose `invoke/4` is the
  handler. Step 5.5 (CapBAC) still gates every dispatch via this
  Behavior's cap subjects — the SPEC's gating guarantee holds.

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
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.Publisher.Event

  # V1 retention default per OQ-EM-A (Allen 2026-05-24 — option (a),
  # count-based). Implementers can override `history_retention/0` on
  # the publisher Kind module (Session does — see `Ezagent.Entity.Session`).
  @default_retention 100

  # ----- Ezagent.Behavior callbacks --------------------------------------

  @impl Ezagent.Behavior
  def actions, do: [:subscribe_from, :snapshot, :history]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Publisher.SessionImpl is registered on Session Kind only — kind axis
  # is `:session`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      subscribe_from: Ezagent.Capability.cap(:session, __MODULE__, :subscribe_from),
      snapshot: Ezagent.Capability.cap(:session, __MODULE__, :snapshot),
      history: Ezagent.Capability.cap(:session, __MODULE__, :history)
    }
  end

  @impl Ezagent.Behavior
  def state_slice, do: :publisher

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:subscribe_from,
       "subscribe to a publisher Kind's structured slice-change stream from a cursor"},
      {:snapshot, "read a publisher Kind's current cursor + state without subscribing"},
      {:history, "read events from a publisher Kind's retained history in a cursor window"}
    ]
  end

  @doc """
  Per SPEC §2.1: the Publisher cap is gated on the publishing Kind
  (the Session). Session caps' data_owner is the user/agent that
  created the session (same rule as `Ezagent.Behavior.Chat.data_owner/1`).
  Reads via `Ezagent.Kind.get_slice/2` on the `:chat` slice's
  `:owner_uri` field — caps-data-ownership SPEC #306 §7.

  `:any` (workspace-scoped publisher caps) → workspace admin grants.
  Concrete session URI → that session's owner.
  """
  @impl Ezagent.Behavior
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

  @impl Ezagent.Behavior
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
  its OWN SliceChange topic (PR-EM-CORE hook + r4 split-init pattern)
  AND broadcast a `:publisher_alive` lifecycle event for any
  subscriber (e.g. ExternalMirrorWorkers) that needs to re-attach
  on cold-spawn rehydration.

  Returns `{:continue, :subscribe_to_self_slice_change}` so the
  subscribe + lifecycle broadcast run AFTER `:announce_ready` — by
  the time SliceChange events flow, the Kind is `:ready` and dispatch
  can route inbound publisher actions.
  """
  @impl Ezagent.Behavior
  def post_init(_args, _slice) do
    {:continue, :subscribe_to_self_slice_change}
  end

  @impl Ezagent.Behavior
  def handle_continue(:subscribe_to_self_slice_change, _slice, %{self_uri: self_uri}) do
    :ok = Ezagent.SliceChange.subscribe_unverified(self_uri)

    # Task #49 (2026-05-27) — every Session reaching `:ready` (boot OR
    # cold-spawn rehydrate via `SpawnRegistry.spawn/1`) emits a single
    # `{:publisher_alive, self_uri}` lifecycle event. The
    # `:publisher.subscribers` slice rehydrates with stale pids from
    # the snapshot; the still-alive ExternalMirrorWorker Kinds that
    # subscribed pre-vanish need a kick to re-subscribe with their
    # current pid. The lifecycle event IS that kick. See
    # `Ezagent.PublisherLifecycle` moduledoc + the
    # `Ezagent.Behavior.ExternalMirrorWorker.handle_kind_message/3`
    # `:publisher_alive` clause.
    :ok = Ezagent.PublisherLifecycle.broadcast_alive(self_uri)

    # Slice unchanged — return `:ignore` so the Server skips the
    # snapshot commit path (we just opened a PubSub subscription;
    # no slice mutation).
    :ignore
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
  def handle_kind_message({:slice_changed, %{} = event}, slice, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    cond do
      not is_publisher_target?(event, self_uri) ->
        :ignore

      Map.get(event, :slice_key) == :publisher ->
        # Don't mirror our own bookkeeping mutations.
        :ignore

      true ->
        new_cursor = slice.cursor + 1

        publisher_event = %Event{
          cursor: new_cursor,
          publisher_uri: self_uri,
          slice_key: Map.get(event, :slice_key),
          # PR-N3 codex r2 HIGH-1: envelope field renamed `:at` -> `:event_at`.
          event_at: Map.get(event, :event_at) || DateTime.utc_now(),
          payload: build_payload(event, ctx)
        }

        new_ring = append_with_retention(slice.ring, publisher_event, slice.retention)

        fan_out(publisher_event, slice.subscribers)

        {:ok, %{slice | ring: new_ring, cursor: new_cursor}}
    end
  end

  def handle_kind_message({:DOWN, ref, :process, _pid, _reason}, slice, _ctx) do
    case Map.pop(slice.monitors, ref) do
      {nil, _} ->
        # Not one of our refs (could belong to another Behavior on
        # the same Kind — Chat also monitors pids).
        :ignore

      {pid, new_monitors} ->
        new_subscribers = Map.delete(slice.subscribers, pid)
        {:ok, %{slice | subscribers: new_subscribers, monitors: new_monitors}}
    end
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  # ----- Invoke ---------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:subscribe_from, slice, args, _ctx) do
    subscriber_pid = Map.fetch!(args, :subscriber_pid)
    cursor = Map.get(args, :cursor, :latest)

    unless is_pid(subscriber_pid) do
      raise ArgumentError,
            "publisher_subscribe_from: :subscriber_pid must be a pid, got #{inspect(subscriber_pid)}"
    end

    case prepare_replay(slice, cursor) do
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
        flushed_slice = prune_dead_subscribers(slice)
        {_ref, new_slice} = ensure_monitored(flushed_slice, subscriber_pid)

        {:ok, new_slice, %{cursor: slice.cursor}}
    end
  end

  def invoke(:snapshot, slice, _args, _ctx) do
    state =
      case List.last(slice.ring) do
        nil -> nil
        %Event{payload: payload} -> payload
      end

    {:ok, slice, %{cursor: slice.cursor, state: state}}
  end

  def invoke(:history, slice, args, _ctx) do
    from = Map.get(args, :from, :earliest)
    to = Map.get(args, :to, :latest)

    case window(slice, from, to) do
      {:ok, events} -> {:ok, slice, %{events: events}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----- Interface schema -----------------------------------------------

  @impl Ezagent.Behavior
  def interface do
    # `args: %{}` for all three actions — the InterfaceValidator's
    # schema grammar does not have a `:pid` or `:any` atom (see
    # `Ezagent.InterfaceValidator` @moduledoc), and the publisher
    # actions pass typed-but-unrestricted runtime values (a `pid()`,
    # the polymorphic `cursor()` sentinel-or-integer, the
    # `from`/`to` window endpoints). Argument shape is enforced by
    # `invoke/4` (Map.fetch! on required keys + guard clauses on
    # type) — the validator pre-check just confirms args is a map.
    %{
      subscribe_from: %{
        description:
          "Subscribe a pid to this Publisher's structured stream from a cursor (:latest / :earliest / integer)",
        args: %{},
        returns: %{cursor: :integer},
        modes: [:call]
      },
      snapshot: %{
        description: "Read this Publisher's current cursor + state without subscribing",
        args: %{},
        returns: %{cursor: :integer},
        modes: [:call]
      },
      history: %{
        description: "Read events in the (from, to] cursor window from this Publisher's ring",
        args: %{},
        returns: %{},
        modes: [:call]
      }
    }
  end

  # ----- Internals ------------------------------------------------------

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

    new_slice = Map.get(slice_state, slice_key)

    %{
      new_slice: new_slice
    }
  end

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

  defp ensure_monitored(slice, pid) do
    case Map.get(slice.subscribers, pid) do
      nil ->
        ref = Process.monitor(pid)

        new_slice = %{
          slice
          | subscribers: Map.put(slice.subscribers, pid, ref),
            monitors: Map.put(slice.monitors, ref, pid)
        }

        {ref, new_slice}

      ref ->
        # Already monitored — return existing ref, slice unchanged.
        {ref, slice}
    end
  end

  # 2026-05-26 (perf fix paired with the prune in `invoke(:subscribe_from)`):
  # walks `slice.subscribers` and removes any pid whose process is no
  # longer alive locally. Demonitors the matching ref with
  # `:flush` so the inevitable `:DOWN` (already queued for these dead
  # pids) is swallowed rather than racing the next `handle_kind_message`.
  # If two nodes ever publish into one Session this needs to grow a
  # remote-node liveness check; today's single-node invariant lets us
  # use `Process.alive?/1`.
  defp prune_dead_subscribers(slice) do
    Enum.reduce(slice.subscribers, slice, fn {pid, ref}, acc ->
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
  defp prepare_replay(_slice, :latest), do: {:ok, []}
  defp prepare_replay(slice, :earliest), do: {:ok, slice.ring}

  defp prepare_replay(slice, cursor) when is_integer(cursor) and cursor >= 0 do
    case window(slice, cursor, :latest) do
      {:ok, events} -> {:ok, events}
      {:error, _} = err -> err
    end
  end

  defp prepare_replay(_slice, bad),
    do: {:error, {:invalid_cursor, bad}}

  # window(slice, from, to) — returns events with cursor in (from, to]:
  #   - from = :earliest  → no lower bound
  #   - from = integer    → cursor > from (exclusive)
  #   - to   = :latest    → no upper bound
  #   - to   = integer    → cursor <= to (inclusive)
  # Raises `{:error, :cursor_out_of_window}` if `from` is older than
  # the oldest retained cursor (the ring's first entry's cursor - 1).
  defp window(slice, from, to) do
    with :ok <- validate_window(slice, from, to) do
      events =
        slice.ring
        |> Enum.filter(fn %Event{cursor: c} -> in_window?(c, from, to) end)

      {:ok, events}
    end
  end

  # `:earliest` lower bound is always in-window (no lower bound at all).
  defp validate_window(_slice, :earliest, _to), do: :ok

  # Integer `from`: bounds-check + retention-check. Order matters —
  # bounds-check first (basic shape), then retention (the "is `from`
  # still in the ring?" check). The retention check fires even when
  # `to` is `:latest` because the SPEC says raise on cursor_out_of_window
  # for ANY history call whose lower bound predates the oldest
  # retained event.
  defp validate_window(slice, from, to) when is_integer(from) and from >= 0 do
    cond do
      is_integer(to) and to < from ->
        {:error, {:invalid_window, from, to}}

      true ->
        # Retention check (applies whether `to` is `:latest` or integer).
        # See `cursor_out_of_window?/2` for the semantics.
        if cursor_out_of_window?(slice, from) do
          {:error, :cursor_out_of_window}
        else
          :ok
        end
    end
  end

  defp validate_window(_slice, bad, _to), do: {:error, {:invalid_cursor, bad}}

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
  defp cursor_out_of_window?(%{ring: []} = _slice, _from), do: false

  defp cursor_out_of_window?(%{ring: [%Event{cursor: oldest} | _]}, from),
    do: from < oldest - 1

  defp in_window?(_c, :earliest, :latest), do: true
  defp in_window?(c, :earliest, to) when is_integer(to), do: c <= to
  defp in_window?(c, from, :latest) when is_integer(from), do: c > from

  defp in_window?(c, from, to) when is_integer(from) and is_integer(to),
    do: c > from and c <= to
end
