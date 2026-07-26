defmodule Ezagent.ActionSet.Publisher.SessionImpl do
  @moduledoc """
  Kind-Behavior implementing `Ezagent.ActionSet.Publisher` semantics for
  `Ezagent.Entity.Session` (the V1 publisher per SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §2.1,
  Allen's option (a)).

  Added to `Ezagent.Entity.Session.behaviors/0` so every Session Kind
  boots with a `:publisher` slice and self-subscribes to its own
  `Ezagent.SliceChange` topic in `activate/2`.

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 — the transients +
  ## post-ready reference case)

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`. This
  is the module the brief calls out as "transients + post-ready": it
  exercises EVERY non-trivial Lifecycle moment.

  ### Two-container split (SPEC §0.1 / §2.1)

  - **STATE (persistent — framework auto-snapshots):** `ring` / `cursor`
    / `retention`. These are the durable event-log fields (the Session is
    `{:snapshot, :on_change}`; the ring survives restart).
  - **TRANSIENT (never persisted — rebuilt every `activate/2`):**
    `subscribers` (`pid → ref`) + `monitors` (`ref → pid`). Both are
    BEAM-local handles to live processes — a snapshot binary written by
    ONE BEAM and loaded by ANOTHER holds non-routable / stale pids + refs
    (the exact hazard the pre-Lifecycle `reconcile_after_load/2` existed
    to scrub). Under Lifecycle they live in `transients`, which has NO
    serialization path, so they CANNOT be persisted and START EMPTY on
    every `activate/2` — live workers re-subscribe via the lifecycle
    handshake (`activated/2` → `broadcast_alive`). This makes the
    snapshot-of-stale-handles bug structurally impossible.

  ### Boot hooks (SPEC §10-R1 / §9 OQ-5)

  - `init_slice/1` → `create/1` (persistent `ring`/`cursor`/`retention`).
  - `post_init/2` + `handle_continue(:subscribe_to_self_slice_change)`
    → folded into `activate/2`: the self-subscription to this Kind's OWN
    `Ezagent.SliceChange` topic is pre-`:ready` boot work with NO
    `send(self(), ...)` self-deferral, so per §10-R1 it belongs in
    `activate/2`. The subscription is also a TRANSIENT (it binds THIS
    Kind.Server process; `activate/2` records the subscriber pid as the
    cold-restart-detectable token — a brutal kill + cold-load yields a
    DIFFERENT live pid, proving the binding was rebuilt, not rehydrated).
  - `on_ready/2` (the `:publisher_alive` reachability broadcast that
    invites a worker `:call` round-trip) → `activated/2` (§9 OQ-5 /
    §10-R1): it MUST fire AFTER the `ReadyGate` flips or the worker's
    re-subscribe `:call` hits `{:error, :not_ready}` (the exact cold-spawn
    silent-fail this broadcast was moved out of `handle_continue` to fix
    — see the `activated/2` doc). `activate` is pre-`:ready`; `activated`
    is post-`:ready`. Keeping them distinct PRESERVES that ordering.
  - `reconcile_after_load/2` is GONE: it cleared `subscribers`/`monitors`
    on snapshot load — but those are now transients that start empty
    every `activate/2`, so there is NOTHING to clear. The reconcile-clear
    is subsumed by the container model (SPEC §10-R1 / §9 OQ-5 — folding
    the clear into the structural transient guarantee).
  - `handle_kind_message/3` → `handle_signal/2` (§9 OQ-3): `{:slice_changed,
    event}` mutates `ring`/`cursor` (state → `{:set, ...}`); `{:DOWN, ...}`
    mutates `subscribers`/`monitors` (transient → `{:set_transient, ...}`).
    The per-subscriber `fan_out` (`send/2` to specific pids) + the replay
    `send/2`s stay imperative in-handler — they target specific pids, not
    a topic, so they are not `:notify` effects.

  Handler accessor changes: `ring`/`cursor`/`retention` stay `ctx[:read]`
  + `{:set, ...}`; `subscribers`/`monitors` reads go to
  `ctx.transients[k]` and writes become `{:set_transient, k, v}` effects.

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.Publisher.SessionImpl`
  — a domain module (`apps/ezagent_domain_session`); names a domain concept
  (`Publisher` contract + `SessionImpl` = "the Session's implementation of
  it"). NP-2 only forbids upper-layer words in `ezagent_core`; this is a
  domain module. NO violation; the `Session`-named segment legitimately
  identifies which Kind implements the contract. Kept as-is.

  ## Where this module lives

  In `apps/ezagent_domain_session/` — the SessionImpl is Session-specific
  code (reads `Session.owner/1` for `data_owner/1`), so it lives next
  to the Kind it implements. The Publisher CONTRACT
  (`Ezagent.ActionSet.Publisher`) + Event struct live in
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
  `Ezagent.ActionSet.Session`'s members + monitors).

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

  # lifecycle:state_slice_override
  #
  # The `:publisher` slice key is pinned (snapshot-compat — SPEC §5 step 2
  # / §7 OQ-7). The macro would auto-derive the last module segment
  # `SessionImpl` → `:session_impl`, which would orphan every existing
  # `kind_snapshots` row + break the sibling-of-`:chat` placement + the
  # Session's `behaviors/0` registration. Declared explicitly with the
  # sanctioned marker.
  use Ezagent.Lifecycle, state_slice: :publisher

  require Logger

  alias Ezagent.Publisher.Event

  # V1 retention default per OQ-EM-A (Allen 2026-05-24 — option (a),
  # count-based). Implementers can override `history_retention/0` on
  # the publisher Kind module (Session does — see `Ezagent.Entity.Session`).
  @default_retention 100

  # ----- Ezagent.ActionSet callbacks --------------------------------------

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Publisher.SessionImpl is registered on Session Kind only — kind axis
  # is `:session`.

  action(:subscribe_from,
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
  )

  action(:snapshot,
    args: %{},
    returns: %{cursor: :integer},
    caps: [:snapshot],
    modes: [:call],
    description: "Read this Publisher's current cursor + state without subscribing"
  )

  action(:history,
    args: %{},
    returns: %{},
    caps: [:history],
    modes: [:call],
    description: "Read events in the (from, to] cursor window from this Publisher's ring"
  )

  @doc """
  Per SPEC §2.1: the Publisher cap is gated on the publishing Kind
  (the Session). Session caps' data_owner is the user/agent that
  created the session (same rule as `Ezagent.ActionSet.Session.data_owner/1`).
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

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build ONLY the
  # PERSISTENT fields (`ring` / `cursor` / `retention` — the durable
  # event log). `subscribers` + `monitors` are GONE from state — they are
  # TRANSIENTS now (BEAM-local pid/ref handles), rebuilt EMPTY by
  # `activate/2` on every start. `args` carries the spawn-time retention;
  # a snapshot rehydrate shadows this `state` on cold-load.
  @impl Ezagent.Lifecycle
  def create(args) do
    retention =
      case Map.get(args, :publisher_retention) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_retention
      end

    {:ok,
     %{
       ring: [],
       cursor: 0,
       retention: retention
     }}
  end

  @doc """
  `activate/2` (SPEC §10-R1) — EVERY process (re)start. UNIFIES the
  pre-Lifecycle `post_init/2` + `handle_continue(:subscribe_to_self_slice_change)`
  AND the `reconcile_after_load/2` subscriber-clear:

  1. Self-subscribe this Kind's pid to its OWN `Ezagent.SliceChange`
     topic via `Ezagent.SliceChange.subscribe_unverified/1` (same-VM
     trust per PR-N1 round-5 — the Kind subscribing to its own topic is
     the canonical legitimate use; the Kind's pid IS the topic owner).
     This is pre-`:ready` boot work with NO `send(self(), ...)`
     self-deferral, so per §10-R1 it folds into `activate/2` (NOT
     `activated/2`). Idempotent at the PubSub level — a cold-restored
     Session re-running `activate/2` re-subscribes without dup-fan-out.

  2. Rebuild the TRANSIENT bookkeeping: `subscribers` + `monitors` start
     EMPTY on every start. Live workers re-subscribe via the lifecycle
     handshake (the `activated/2` `:publisher_alive` broadcast →
     worker `:subscribe_from`). The subscription record is itself a
     transient — `subscription.subscriber` is the host Kind.Server pid,
     the cold-restart-detectable token (a brutal kill + cold-load yields
     a DIFFERENT live pid, proving the binding was rebuilt — SPEC §6
     step 5c). This SUBSUMES the old `reconcile_after_load/2` clear: the
     maps cannot carry stale handles because they live in `transients`,
     which has no serialization path and is rebuilt here every start.

  Runs PRE-`:ready` (the `:publisher_alive` reachability broadcast is in
  `activated/2`, post-`:ready` — §9 OQ-5).
  """
  @impl Ezagent.Lifecycle
  def activate(_state, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    subscription = subscribe_to_self_slice_change(self_uri)

    {:ok,
     %{
       subscribers: %{},
       monitors: %{},
       slice_change_subscription: subscription
     }}
  end

  # Subscribe THIS process to its own SliceChange topic and return the
  # transient record. The `subscriber` pid (= the host Kind.Server) is the
  # cold-restart-detectable token (SPEC §6 step 5c). Best-effort: a
  # subscribe failure must not crash the boot.
  defp subscribe_to_self_slice_change(%URI{} = self_uri) do
    try do
      :ok = Ezagent.SliceChange.subscribe_unverified(self_uri)
      %{subscribed_to: Ezagent.URI.stable_key(self_uri), subscriber: self()}
    catch
      kind, reason ->
        Logger.warning(
          "Ezagent.ActionSet.Publisher.SessionImpl.activate: SliceChange.subscribe " <>
            "failed (#{inspect(kind)}, #{inspect(reason)}) for " <>
            "#{URI.to_string(self_uri)}; this incarnation will not mirror slice changes"
        )

        %{subscribed_to: Ezagent.URI.stable_key(self_uri), subscriber: self()}
    end
  end

  @doc """
  `activated/2` (SPEC §9 OQ-5 / §10-R1, post-`:ready`) — successor to the
  engine's `on_ready/2`. Broadcast the `:publisher_alive` lifecycle event
  AFTER `Ezagent.ReadyGate.mark_ready/1` has flipped this Session to
  `:ready` and the PendingDelivery buffer has drained.

  This MUST be post-`:ready`, NOT in `activate/2`. Cold-spawn flow if it
  fired pre-`:ready`:

      activate → broadcast :publisher_alive
               → Worker receives event
               → Worker calls subscribe_to_session_publisher (mode :call)
               → Router.dispatch sees Session ReadyGate :not_ready
               → returns {:error, :not_ready}
               → Worker logs + discards (no retry)
               → SILENT FAIL on cold-spawn — the exact case this mechanism
                 was meant to fix (task #49 codex round-1 FAIL #6).

  Running it in `activated/2` (which compiles to `on_ready/2`, post-flip)
  ensures the Worker's re-subscribe `:call` finds the Session `:ready`.
  The Worker also carries a defence-in-depth retry on `{:error,
  :not_ready}` (`Ezagent.ActionSet.ExternalMirrorWorker` `:publisher_alive`
  clause) — primary fix is the ordering; the retry is belt-and-braces.
  """
  @impl Ezagent.Lifecycle
  def activated(_state, %{self_uri: self_uri}) do
    :ok = Ezagent.PublisherLifecycle.broadcast_alive(self_uri)
  end

  # ----- Signal hook (non-action GenServer messages) --------------------

  @doc """
  `handle_signal/2` (SPEC §9 OQ-3) — the Lifecycle successor to the
  engine's `handle_kind_message/3`. Returns the SAME effect grammar a
  `handle_<action>/2` does; the macro reduces it into the two-container
  slice (`:set` → state, `:set_transient` → transients).

  Receives `{:slice_changed, event}` from `Ezagent.SliceChange` (our
  own topic — we subscribed in `activate/2`) and
  `{:DOWN, ref, :process, pid, reason}` from `Process.monitor/1` of
  subscriber pids.

  Slice-changed events are filtered to those whose `self_uri` matches
  the Kind's own URI (defence-in-depth — the topic IS per-URI but a
  caller error could broadcast to the wrong topic and we don't want
  to mirror foreign data).

  Importantly, slice changes to the `:publisher` slice itself are
  IGNORED (they would re-trigger an emit-loop: a subscriber being added
  mutates `:publisher.subscribers`, which becomes its own slice-change
  event, which would add an entry to the ring). The Publisher mirrors
  slice changes from OTHER slices (`:chat` etc).

  `ring` + `cursor` are PERSISTENT — written via `{:set, ...}`. The
  `fan_out` (`send/2` to specific subscriber pids) stays imperative
  in-handler — it targets pids, not a topic, so it is not a `:notify`
  effect. `subscribers` is read from `ctx.transients` (the macro injects
  `ctx.transients` + a `ctx.read` over `:state` for the signal path —
  see `Ezagent.Lifecycle.__run_signal__/4`).
  """
  @impl Ezagent.Lifecycle
  def handle_signal({:slice_changed, %{} = event}, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)

    cond do
      not is_publisher_target?(event, self_uri) ->
        :ignore

      Map.get(event, :slice_key) == :publisher ->
        # Don't mirror our own bookkeeping mutations.
        :ignore

      true ->
        cursor = ctx[:read].(:cursor, 0)
        ring = ctx[:read].(:ring, [])
        retention = ctx[:read].(:retention, @default_retention)
        subscribers = (ctx[:transients] || %{})[:subscribers] || %{}

        new_cursor = cursor + 1

        publisher_event = %Event{
          cursor: new_cursor,
          publisher_uri: self_uri,
          slice_key: Map.get(event, :slice_key),
          # PR-N3 codex r2 HIGH-1: envelope field renamed `:at` -> `:event_at`.
          event_at: Map.get(event, :event_at) || DateTime.utc_now(),
          payload: build_payload(event, ctx)
        }

        new_ring = append_with_retention(ring, publisher_event, retention)

        fan_out(publisher_event, subscribers)

        # `ring` + `cursor` are PERSISTENT state.
        {:ok,
         [
           {:set, :ring, new_ring},
           {:set, :cursor, new_cursor}
         ]}
    end
  end

  def handle_signal({:DOWN, ref, :process, _pid, _reason}, ctx) do
    # `subscribers` + `monitors` are TRANSIENTS (BEAM-local handles) —
    # read from ctx.transients, written via `{:set_transient, ...}`.
    transients = ctx[:transients] || %{}
    monitors = transients[:monitors] || %{}
    subscribers = transients[:subscribers] || %{}

    case Map.pop(monitors, ref) do
      {nil, _} ->
        # Not one of our refs (could belong to another Behavior on
        # the same Kind — Chat also monitors pids).
        :ignore

      {pid, new_monitors} ->
        new_subscribers = Map.delete(subscribers, pid)

        {:ok,
         [
           {:set_transient, :subscribers, new_subscribers},
           {:set_transient, :monitors, new_monitors}
         ]}
    end
  end

  def handle_signal(_other, _ctx), do: :ignore

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
          # V5 use-side B2 — the subscriber pid is all this slice stores
          # (bare-pid fallback: no worker URI is keyed here), so the raw
          # send carries the sanctioned envelope; the Kind.Server unwraps
          # it back to `{:publisher_event, ev}` for the subscriber's
          # `handle_signal/2`.
          send(subscriber_pid, %EzagentActor.Signal{
            kind: :signal,
            payload: {:publisher_event, ev}
          })
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

        # `subscribers` + `monitors` are TRANSIENTS (BEAM-local pid/ref
        # handles) — written via `{:set_transient, ...}`, NEVER persisted
        # (SPEC §0.1 / §7 OQ-2). Surgical per-field writes (vs replacing
        # the whole transients map) so the macro's transient reduction is
        # minimal.
        {:ok, %{cursor: current_publisher_slice.cursor},
         [
           {:set_transient, :subscribers, new_publisher_slice.subscribers},
           {:set_transient, :monitors, new_publisher_slice.monitors}
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

  # Reconstruct the current publisher slice from ctx. The new contract
  # doesn't pass the slice as an arg; instead each field is read on
  # demand. PERSISTENT fields (`ring` / `cursor` / `retention`) come from
  # `ctx[:read]`; TRANSIENT fields (`subscribers` / `monitors`,
  # BEAM-local handles) come from `ctx.transients` (SPEC §2.1 / §2.2). We
  # re-materialise the flat map for the internal helpers (window/3,
  # prepare_replay/2, ensure_monitored/2, prune_dead_subscribers/1).
  defp current_slice(ctx) do
    transients = ctx[:transients] || %{}

    %{
      ring: ctx[:read].(:ring, []),
      cursor: ctx[:read].(:cursor, 0),
      retention: ctx[:read].(:retention, @default_retention),
      subscribers: transients[:subscribers] || %{},
      monitors: transients[:monitors] || %{}
    }
  end

  # Default retention used when `init_slice/1` is called without
  # publisher_retention (the Session implementation reads
  # `Ezagent.ActionSet.Publisher.history_retention/0` on Session and
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
      # V5 use-side B2 — bare-pid fallback (subscribers are keyed by pid,
      # no URI is stored): raw send carrying the sanctioned envelope, which
      # the subscriber Kind's envelope clause unwraps back to
      # `{:publisher_event, event}`.
      send(pid, %EzagentActor.Signal{kind: :signal, payload: {:publisher_event, event}})
    end)
  end

  defp ensure_monitored(publisher_slice, pid) do
    case Map.get(publisher_slice.subscribers, pid) do
      nil ->
        # V5 use-side B2 — monitor via the sanctioned relay
        # (`Signal.monitor/1`); the death arrives as `%Signal{kind: :down}`
        # and the Kind.Server envelope clause reconstructs the exact
        # `{:DOWN, ref, :process, pid, reason}` tuple the
        # `handle_signal({:DOWN, …})` clause matches. Ref correlation
        # (subscribers pid→ref, monitors ref→pid) is unchanged.
        {:ok, ref} = EzagentActor.Signal.monitor(pid)

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
  # (V5 use-side B2: refs now belong to the `EzagentActor.Signal.Monitor`
  # relay, so the demonitor is a no-op for this Kind; the relay's
  # re-delivered `%Signal{kind: :down}` for a pruned ref is ignored by
  # `handle_signal({:DOWN, …})` — the ref was already dropped from
  # `:monitors` here.)
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
