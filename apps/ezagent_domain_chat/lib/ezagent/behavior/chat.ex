defmodule Ezagent.Behavior.Chat do
  @moduledoc """
  Chat Behavior — Decision P2-D2 K-path: 4 actions, registered per-Kind
  subset to realize Decision #61 "ESR is router not req/resp app".

  ## Action / Kind matrix

      | action    | registered on Kind(s)                  | mode  |
      |-----------|----------------------------------------|-------|
      | :send     | Ezagent.Entity.Session                     | cast  |
      | :join     | Ezagent.Entity.Session                     | call  |
      | :leave    | Ezagent.Entity.Session                     | cast  |
      | :receive  | Ezagent.Entity.User, Ezagent.Entity.Agent      | cast  |

  Session-side actions (`:send / :join / :leave`) mutate the Session's
  `:chat` slice (`members` map / `monitors` ref→URI / `last_seen` URI→DateTime).
  When `:send` is invoked, recipients are derived from `msg.mentions` (or
  all `members` if mentions is empty), excluding the sender, and each
  receives a `chat/receive` dispatch on its own Kind. The Session also
  broadcasts to `esr:session:<self_uri>:events` so the LV chat stream
  picks up the message.

  ## Receive branching

  `:receive` switches on `ctx.kind_module`:
  - `Ezagent.Entity.User` — broadcast to `esr:user:<self_uri>:events`. LV
    subscribes for admin inbox / mention notifications.
  - `Ezagent.Entity.Agent` — delivers a flavor-neutral
    `Ezagent.AgentBridge.Payload` through `Ezagent.AgentBridge.deliver/2`.
    If no bridge or adapter is bound, AgentBridge logs and emits
    telemetry while chat receive itself remains a best-effort cast.

  ## Offline state machine (P2-D3 failure modes)

  When a member joins, Session `Process.monitor`s the member's Kind pid.
  On `:DOWN`, `handle_kind_message/3` flips that member's `online` flag
  to false and records `last_seen = now` (no member removal). On rejoin
  (`:join` for an already-known member), the Session uses
  `Ezagent.MessageStore.in_session_since/2(self_uri, last_seen)` to replay
  missed messages — bounded by the @replay_cap in MessageStore (1000)
  per DECISIONS failure mode (4).

  ## Why ctx.self_uri and ctx.kind_module

  Both injected by `Ezagent.Kind.Runtime` immediately before invoke (single
  point of contact, plugins never plumb manually). Session uses
  `ctx.self_uri` to scope MessageStore writes and PubSub topics;
  receivers branch on `ctx.kind_module` to pick the delivery shape
  (broadcast vs bridge push).
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}

  # PR-N3 r4 (Allen 2026-05-25) — bounded cursor-indexed ring depth for
  # the User-branch `:receive` `:recent_messages` ring. SPEC-pinned (NOT
  # a runtime config knob — per `feedback_let_it_crash_no_workarounds`
  # config knobs are anti-patterns; structural constants belong here).
  #
  # Why 20: AdminLive's flash bridge re-fetches the slice on each
  # `:slice_changed` event. Between "envelope cursor C broadcast" and
  # "LV process pulls slice", N more :receive events may have committed
  # (LV mailbox under burst). Ring depth caps the worst-case
  # backlog the bridge can resolve — 20 is ~10x typical bursts (single
  # AdminLive instance processing ~2-3 events/sec under load) and well
  # below the cost-of-carry threshold (each entry is `{int, binary}` =
  # ~40 bytes; 20 entries = ~800 bytes added to every persisted
  # Session/User snapshot). Older events fall off the tail; the bridge
  # falls back to the "New chat update on <uri>" generic line for any
  # envelope cursor that's no longer in the ring (graceful skip —
  # observability degradation, not correctness loss).
  @recent_messages_ring_depth 20

  @doc """
  Ring depth for the `:recent_messages` cursor-indexed ring on the
  `:chat` slice (PR-N3 r4 cursor-race fix).

  Exposed as a function (rather than module attr access from outside)
  so tests can assert against the SPEC-pinned constant without coupling
  to compile-time internals. SPEC §2.1.3 documents the rationale; this
  is the canonical reader for the bound.
  """
  @spec recent_messages_ring_depth() :: pos_integer()
  def recent_messages_ring_depth, do: @recent_messages_ring_depth

  @impl Ezagent.Behavior
  def actions, do: [:send, :receive, :join, :leave, :set_working_copy]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Chat is registered on:
  #   - Session Kind for :send, :join, :leave, :set_working_copy
  #   - User Kind for :receive
  #   - Agent Kind for :receive
  # The multi-Kind registration → kind axis is `:any` (check 11(b) escape).
  @impl Ezagent.Behavior
  def required_caps do
    %{
      send: Ezagent.Capability.cap(:any, __MODULE__, :send),
      receive: Ezagent.Capability.cap(:any, __MODULE__, :receive),
      join: Ezagent.Capability.cap(:any, __MODULE__, :join),
      leave: Ezagent.Capability.cap(:any, __MODULE__, :leave),
      set_working_copy: Ezagent.Capability.cap(:any, __MODULE__, :set_working_copy)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:send, "send a chat message to session members"},
      {:receive, "receive a chat message routed to this Kind (User/Agent inbox)"},
      {:join, "join a session as a member (replays missed messages on rejoin)"},
      {:leave, "leave a session (records last_seen for future rejoin replay)"},
      {:set_working_copy,
       "stage SessionTemplate working-copy edits on the Session before instantiate"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :chat

  @impl Ezagent.Behavior
  def init_slice(args) do
    # Slice shape is the union across Kinds — Session uses all three
    # maps; User/Agent's :receive doesn't read or write the slice but
    # leaving the keys here means a `Map.get` on any Kind returns the
    # consistent shape (defensive over the BehaviorRegistry per-Kind
    # subset model where User/Agent don't list Chat in `behaviors/0`
    # and so don't init this slice anyway — `Kind.Runtime` defaults
    # missing slices to `%{}`, which the Session-only fields tolerate).
    #
    # PR-OWN-2 (caps-data-ownership SPEC #306 §7): `:owner_uri` carries
    # the entity URI that "owns" this session (created it). Used by
    # `data_owner/1` so `default_grants_from_data_owner/2` and
    # `Behavior.Identity.grant_cap` §5.2 enforcement can resolve "who's
    # legitimate to grant Chat caps on this session". `nil` for sessions
    # spawned without an `:owner_uri` arg (system sessions, etc) — those
    # fall back to `:no_owner` in `data_owner/1`, so only the bootstrap
    # admin can grant. A pre-PR-2 Session snapshot has no `:owner_uri`;
    # `Kind.Snapshot.load_or_init/3` merges fresh into loaded, so this
    # default fills missing entries.
    %{
      # %{URI => %{online: bool}}
      members: %{},
      owner_uri: Map.get(args, :owner_uri),
      # %{ref => URI} — Process.monitor refs
      monitors: %{},
      # %{URI => DateTime} — when last seen offline (only present for offline)
      last_seen: %{},
      # PR-EM-6-PRE (Allen 2026-05-25) — the architectural seam
      # external-mirror plugins (Feishu / future Slack / etc) ride on
      # after PR-EM-6 deletes `maybe_notify_external/3`. The flow is
      # Chat.send → slice mutation → `Kind.Runtime` step 9.5 builds
      # `slice_change_event` (gated on `new_slice != slice`) →
      # `Kind.Server.commit_and_notify/3` → `SliceChange.emit/1` →
      # Publisher → ExternalMirror Worker → adapter dispatch.
      #
      # Three fields, three jobs (codex r1 2026-05-25 HIGH-1 + HIGH-2):
      #
      # - `:last_message_id` — the id of the most recently persisted
      #   Message. Stable cross-reference for MessageStore + ReadMarker
      #   rows; NOT sufficient on its own because a retried send of the
      #   same msg.id leaves it byte-equal (HIGH-1).
      #
      # - `:last_message` — the full `Ezagent.Message.t()` returned by
      #   `MessageStore.write/2` (has `:session_uri` + `:workspace_uri`
      #   stamped). ExternalMirror adapters convert `Publisher.Event` →
      #   payload as PURE FUNCTIONS (no DB lookup); carrying the
      #   message here lets adapters render sender / body / attachments
      #   / mentions directly from the event without an out-of-band
      #   MessageStore round-trip (HIGH-2).
      #
      # - `:send_cursor` — monotonically-incrementing counter, bumped
      #   on EVERY `:send` that successfully persists, even when
      #   `msg.id` matches an earlier write (MessageStore is idempotent
      #   on `(msg.id, session_uri)` per its `on_conflict: :nothing`).
      #   Without this, a resend of an already-persisted message id
      #   would leave `last_message_id` + `last_message` byte-equal,
      #   SliceChange would short-circuit, and external mirrors would
      #   silently miss the retry while in-session subscribers received
      #   it (HIGH-1).
      #
      # All three start `nil` / `0` on a fresh session; readers must
      # tolerate the legacy shape where the keys are absent entirely
      # (pre-PR-EM-6-PRE snapshots — `Kind.Snapshot.load_or_init/3`
      # merges loaded INTO fresh, so a Session that pre-dates this PR
      # keeps its pre-existing `:chat` slice without these keys until
      # its next `:send`).
      last_message_id: nil,
      last_message: nil,
      send_cursor: 0,
      # PR-N3 r4 (Allen 2026-05-25) — cursor-indexed bounded ring of
      # recent message ids for the User-branch `:receive` action. Each
      # entry is `{slice_change_cursor :: pos_integer(), msg_id ::
      # String.t()}`; the cursor matches the `SliceChange` broadcast
      # envelope cursor (pre-allocated by `Ezagent.Kind.Runtime` and
      # passed via `ctx.slice_change_cursor`), so a flash subscriber
      # that receives envelope cursor C can re-fetch the slice and
      # look up the correct `msg_id` via `List.keyfind(ring, C, 0)`
      # WITHOUT racing the latest pointer.
      #
      # Pre-fix (r3): User-branch :receive wrote a single
      # `:last_received` pointer. Under burst (N events arriving faster
      # than AdminLive's LV process drained its mailbox), every flash
      # re-fetch read the LATEST pointer — so all N flashes rendered
      # the same (most-recent) message, losing N-1 distinct
      # notifications. Codex r3 PR-N3 flagged this as HIGH-1.
      #
      # Ring depth is SPEC-pinned via
      # `recent_messages_ring_depth/0` (NOT a runtime config knob —
      # per `feedback_let_it_crash_no_workarounds`). Entries past the
      # bound fall off the tail; the bridge gracefully degrades to the
      # "New chat update on <uri>" line for any envelope cursor that's
      # no longer in the ring (no crash, no silent wrong-render — the
      # flash still fires, just generic).
      #
      # Newest-first ordering; HEAD is the most recently received
      # message. `List.keyfind/3` is O(N) on N=20 = fine.
      #
      # Legacy slice shape (pre-PR-N3-r4): missing key.
      # `Kind.Snapshot.load_or_init/3` merges loaded INTO fresh, so
      # pre-PR snapshots keep their `:chat` slice without this key
      # until the next `:receive` populates it. Readers MUST default
      # via `Map.get(slice, :recent_messages, [])`.
      recent_messages: [],
      # Phase 7 completion PR-2 (SPEC §1.3 / §1.6) — the durable
      # source-template record for the orchestrator's working copy.
      # `template_working_copy` is template-SHAPED, not live-runtime
      # shaped (codex rev-3 HIGH-3): `agent_slots` carries the
      # `template://agent/<ws>/<name>` AgentTemplate URI each slot was
      # spawned from (the durable `source_agent_template_uri`), NOT a
      # live `entity://agent` instance URI; routing receivers are slot
      # NAMES, not live URIs. Because Session is `{:snapshot,
      # :on_change}` this field persists across restart.
      #
      # A pre-PR-2 Session snapshot has a `:chat` slice WITHOUT this
      # key. `Ezagent.Kind.Snapshot.load_or_init/3` merges at the
      # slice-key level (`Map.merge(fresh, loaded)`), so the loaded
      # `:chat` slice would replace the fresh one entirely — readers
      # MUST therefore treat a missing key as the default via
      # `template_working_copy/1` below rather than dot-access.
      template_working_copy: default_template_working_copy()
    }
  end

  @doc """
  The empty/default `template_working_copy` shape (Phase 7 completion
  SPEC §1.3 / §1.6).

  Used by `init_slice/1` for fresh Sessions and as the safe default
  when reading a pre-PR-2 Session snapshot whose `:chat` slice has no
  `template_working_copy` key.
  """
  @spec default_template_working_copy() :: map()
  def default_template_working_copy do
    %{
      # [{slot_name :: String.t(),
      #   source_agent_template_uri :: URI.t(),
      #   live_worker_uri :: URI.t(),
      #   generation :: non_neg_integer()}]
      #
      # The 4-tuple (CRITICAL + HIGH-6 hardening fix): `slot_name` is
      # the stable template-shaped key; `source_agent_template_uri` is
      # the `template://agent/<ws>/<name>` the slot was spawned from
      # (the durable source); `live_worker_uri` is the CURRENT
      # session-unique live `entity://agent/...` instance URI;
      # `generation` is the swap counter (0 at Generator init,
      # incremented by each `update_agent_template`). Storing the live
      # URI + generation means readers never re-derive a collision-prone
      # URI from `{workspace, flavor, slot_name}`.
      agent_slots: [],
      # [{matcher_ast :: term(), [slot_name :: String.t()]}]
      # receivers are slot NAMES, resolved to URIs only on instantiate.
      routing_rules: [],
      # URI.t() | nil — the orchestrator agent's AgentTemplate
      orchestrator_template_uri: nil,
      # URI.t() | nil — workspace newly-instantiated sessions land in
      default_workspace_uri: nil,
      # String.t() — human description of the team
      description: ""
    }
  end

  @doc """
  Read the durable `template_working_copy` field from a `:chat` slice,
  defaulting to `default_template_working_copy/0` when the key is
  absent (a pre-PR-2 Session snapshot — see `init_slice/1`).
  """
  @spec template_working_copy(map()) :: map()
  def template_working_copy(slice) when is_map(slice) do
    Map.get(slice, :template_working_copy, default_template_working_copy())
  end

  # --- :send -------------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:send, slice, %{message: %Message{} = msg}, ctx) do
    session_uri = ctx.self_uri

    # 1. Persist — write failure means send failure per DECISIONS
    # impl-time §write-failure; let-it-crash on Repo errors rather than
    # silently dropping the message.
    case MessageStore.write(msg, session_uri) do
      {:ok, stored_msg} ->
        # Plan B (2026-05-17): use stored_msg (which has session_uri
        # stamped) for Resolver + downstream dispatch. The original
        # `msg` arg has session_uri=nil at this point, which makes the
        # new `in_session(session_uri)` matcher (introduced for Feishu
        # binding) return false. Without this fix, in_session-scoped
        # routing rules never fire even when the binding is correct.
        msg = stored_msg

        # 2. Broadcast for in-session subscribers (LV chat stream).
        # Phase 3: include session_uri in payload so multi-session LV
        # subscribers can filter by current session.
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          session_events_topic(session_uri),
          {:chat_message, session_uri, msg}
        )

        # Phase 4-completion PR 9: Resolver is the SINGLE source of
        # truth for routing decisions. No hardcoded fan-out here — the
        # in-session-member fan-out is now expressed as a system_default
        # rule with `receivers: ["$session_members"]` that Resolver
        # expands using the passed members list.
        #
        # Phase 7 PR 31 (IMPL-7-1): plumb workspace_uri into Resolver so
        # workspace-scoped routing rules actually filter. Pre-PR-31 this
        # call used 3-arg resolve/3 which forwarded with `opts = []`,
        # making rules with `workspace_uri != nil` never fire — exactly
        # the V4.4 / V3.2 gap. `WorkspaceRegistry.lookup` returns :error
        # for unbound (legacy) sessions; we pass `workspace_uri: nil`
        # in that case, preserving pre-PR-31 global semantics.
        in_session_members = Map.keys(slice.members)

        workspace_uri =
          case Ezagent.WorkspaceRegistry.lookup(session_uri) do
            {:ok, uri} -> uri
            :error -> nil
          end

        recipients =
          Ezagent.Routing.Resolver.resolve(
            msg,
            session_uri,
            in_session_members,
            workspace_uri: workspace_uri
          )

        # Allen 2026-05-26: surface "mention dropped — target not in
        # session" as a notification to the sender. Without this, the
        # operator types `@curl_test_alpha hello` and gets no feedback
        # if curl_test_alpha is not a session member — silent drop.
        #
        # Discriminator: `msg.mentions` is already filtered by the
        # mention parser to URIs that resolve to real entities. The
        # rejected-from-recipients set tells us which resolved entities
        # the Resolver dropped (via `valid_member?` membership filter).
        # Random `@text` (no URI match) never enters `msg.mentions`
        # and is silent — exactly what users want for casual @ usage.
        notify_dropped_mentions(msg, recipients, session_uri, ctx)

        for recipient <- recipients do
          if recipient.scheme == "session" do
            dispatch_cross_session(recipient, msg)
          else
            dispatch_receive(recipient, msg, session_uri)
          end
        end

        # PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
        # §9) — `maybe_notify_external/3` retired. External-mirror
        # fan-out is now the generic ExternalMirror Domain's
        # responsibility: the chat slice update emits a SliceChange,
        # the Session Kind's Publisher records it, every subscribed
        # per-binding Worker receives `{:publisher_event, _}` and
        # self-dispatches `:publish` to its Behavior. Chat no longer
        # touches the BehaviorRegistry-lookup-then-dispatch path —
        # the publish flow is structural (no opportunistic call from
        # here).

        # PR-EM-6-PRE (Allen 2026-05-25) — mutate the slice so the
        # SliceChange hook in `Kind.Runtime` fires for every send. See
        # `init_slice/1` for the three-field rationale (HIGH-1 +
        # HIGH-2 from codex r1 2026-05-25).
        #
        # - `:last_message_id` + `:last_message`: cross-reference id +
        #   the full stamped Message struct (sender / body / mentions /
        #   workspace_uri / session_uri / inserted_at). Adapters
        #   downstream get everything they need from the
        #   `Publisher.Event.new_slice` without a MessageStore lookup.
        #
        # - `:send_cursor`: monotonic per-invocation counter. Bumped
        #   even when `msg.id` matches a prior send (MessageStore is
        #   idempotent on `(id, session_uri)` per `on_conflict:
        #   :nothing` in `Repo.insert/2` at message_store.ex:86). The
        #   cursor delta is what guarantees `new_slice != slice` for
        #   retried sends — without it, external mirrors would miss
        #   any send whose id collides with a previously-persisted
        #   row, while in-session members still receive the dispatch.
        #
        # `Map.get/3` defaults cover the legacy slice shape
        # (pre-PR-EM-6-PRE snapshots lack these keys); `Map.put/3` for
        # the assignment side covers the same.
        prev_cursor = Map.get(slice, :send_cursor, 0)

        new_slice =
          slice
          |> Map.put(:last_message_id, msg.id)
          |> Map.put(:last_message, msg)
          |> Map.put(:send_cursor, prev_cursor + 1)

        {:ok, new_slice, %{stored: true}}

      {:error, reason} ->
        {:error, {:message_store_write_failed, reason}}
    end
  end

  # --- :receive ----------------------------------------------------------

  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    case ctx.kind_module do
      Ezagent.Entity.User ->
        # PR-N3 (SPEC v2 notification-architecture-v2 §2.4 + §3 lines
        # 204-211, Allen 2026-05-25) — producer-pattern proof.
        #
        # Both the legacy raw `Phoenix.PubSub.broadcast` to
        # `esr:user:<uri>:events` and the new `Ezagent.Notifications.notify/3`
        # call were DELETED here. SPEC §2.4 / §3 PR-N3: the User-branch
        # is just "append `msg` to the receive slice; return `{:ok,
        # new_slice}`." `Ezagent.Kind.Runtime.handle_dispatch/4` detects
        # `new_slice != old_slice` and `Kind.Server.commit_and_notify/3`
        # routes the slice-change event through `Ezagent.SliceChange.emit/1`
        # post-commit (PR-N1 wiring + PR-N3 hard-switch flip).
        # AdminLive's PR-N2 subscription on
        # `Ezagent.Notifications.subscribe_slice_change/1` picks it up.
        #
        # The slice mutation we make is the structural notification:
        # `:last_received` records the message id + arrival timestamp.
        # Always-mutating (DateTime.utc_now/0 differs across calls), so
        # the auto-hook fires on every legitimate receive. The User's
        # `:chat` slice is initialized to `%{}` (User Kind does NOT list
        # Chat in `behaviors/0` — SPEC v2 §5.14 + chat.ex `init_slice/1`
        # moduledoc), so `Map.put/3` is safe on a default-empty map.
        #
        # PR-N3 r4 (Allen 2026-05-25) — ALSO push the {cursor, msg_id}
        # tuple into the cursor-indexed `:recent_messages` ring so
        # AdminLive's flash bridge can resolve the correct message even
        # under burst (codex r3 HIGH-1 race fix). Cursor comes from
        # `ctx.slice_change_cursor` — pre-allocated by
        # `Ezagent.Kind.Runtime.handle_dispatch/4` step 9.5 and
        # threaded into ctx so the slice's ring key matches the
        # `SliceChange` broadcast envelope's `:cursor` field exactly.
        #
        # Defaults:
        # - `ctx.slice_change_cursor` may be absent on legacy code
        #   paths that bypass Runtime (e.g. a unit test calling
        #   `invoke/4` directly). In that case `nil` is the cursor
        #   key, the ring still records the entry, and AdminLive's
        #   `List.keyfind/3` returns nil for a numeric cursor — which
        #   degrades to the "New chat update on <uri>" generic
        #   fallback (no crash, no wrong render).
        # - `:recent_messages` may be absent on a pre-PR-N3-r4 slice
        #   snapshot; `Map.get/3` defaults to `[]`.
        cursor = Map.get(ctx, :slice_change_cursor)
        prior_ring = Map.get(slice, :recent_messages, [])
        new_entry = {cursor, msg.id}

        trimmed_ring =
          [new_entry | prior_ring]
          |> Enum.take(@recent_messages_ring_depth)

        new_slice =
          slice
          |> Map.put(:last_received, %{
            message_id: msg.id,
            at: DateTime.utc_now()
          })
          |> Map.put(:recent_messages, trimmed_ring)

        {:ok, new_slice}

      Ezagent.Entity.Agent ->
        # AgentBridge PR-D: keep chat receive flavor-neutral. The
        # bridge domain resolves the bound channel and adapter for the
        # agent URI; missing bridge/adapter remains best-effort for
        # this cast receive path but is logged by AgentBridge.deliver/2.
        source_session =
          case Map.get(ctx, :caller) do
            %URI{} = u -> URI.to_string(u)
            s when is_binary(s) -> s
            _ -> ""
          end

        # Phase 6 PR 14: pass attachments through to claude so it sees
        # what the operator sent, even when the bridge can't render
        # binary content. Format as a text breadcrumb attached after
        # the body text. PR 26 (Allen 2026-05-18): per channels-reference
        # spec `meta: Record<string, string>`, every meta VALUE must be
        # a string — a list value (the old `attachments` key) caused
        # claude TUI to silently drop the entire notification. Keep
        # attachment info in `content` only; structured form is not
        # representable in the channel meta schema.
        attachments = body_attachments(msg.body)
        attachment_hint = attachment_hint_text(attachments)

        text_with_hint =
          case {body_text(msg.body), attachment_hint} do
            {"", ""} -> ""
            {t, ""} -> t
            {"", hint} -> hint
            {t, hint} -> t <> "\n" <> hint
          end

        base_meta = %{
          "sender" => URI.to_string(msg.sender),
          "message_id" => msg.id,
          "session" => source_session
        }

        meta =
          case first_attachment_path(attachments) do
            nil -> base_meta
            path -> Map.put(base_meta, "file_path", path)
          end

        session_uri =
          case msg.session_uri do
            %URI{} = uri -> uri
            s when is_binary(s) and s != "" -> Ezagent.URI.parse!(s)
            _ when source_session != "" -> Ezagent.URI.parse!(source_session)
            _ -> nil
          end

        payload = %Ezagent.AgentBridge.Payload{
          message_id: msg.id,
          session_uri: session_uri,
          sender_uri: msg.sender,
          text: text_with_hint,
          event_type: :chat_send,
          attachments: attachments,
          meta: meta
        }

        _ = Ezagent.AgentBridge.deliver(ctx.self_uri, payload)

        {:ok, slice}

      _other ->
        # Should not happen — :receive is only registered for User/Agent.
        {:error, {:receive_unsupported_for_kind, ctx.kind_module}}
    end
  end

  # --- :join -------------------------------------------------------------

  def invoke(:join, slice, %{member: %URI{} = member_uri}, ctx) do
    case KindRegistry.lookup(member_uri) do
      {:ok, member_pid} ->
        # Session auto-join (Allen 2026-05-26) — idempotency: when a
        # member rejoins (LV remount after warm restart, ensure_orchestrator
        # post-spawn hook re-run, etc.) we MUST NOT stack a fresh
        # `Process.monitor` on top of the live one. Pre-fix, every rejoin
        # leaked a monitor ref in `slice.monitors` (cleaned only on
        # `:DOWN`, which never fired for the live member).
        #
        # Codex r1 HIGH-1 (2026-05-26): the short-circuit MUST verify
        # the monitor we hold points at the SAME PID `KindRegistry`
        # currently resolves the URI to. Otherwise, in the
        # member-died + new-PID-registered + stale-:DOWN-pending
        # window, we'd no-op the rejoin while the queued :DOWN later
        # marks the live member offline (and worse, no monitor exists
        # for the new PID). Short-circuit is correct ONLY when
        # `monitors` contains a ref AND `Process.info(member_pid,
        # :monitored_by)` includes self() — but the cheaper structural
        # check is "the ref we hold for this URI is for THIS PID",
        # which we approximate by asserting both the URI mapping and
        # PID identity via `monitor_ref_for_current_pid/3`.
        case Map.get(slice.members, member_uri) do
          %{online: true} ->
            if monitor_ref_for_current_pid?(slice.monitors, member_uri, member_pid) do
              # Already a live, monitored, online member with the
              # SAME PID we're being asked to (re)join. True no-op.
              {:ok, slice, %{members: Map.keys(slice.members), already_member: true}}
            else
              # Stale ref (different/dead PID) or no ref — drop any
              # stale entries + install a fresh monitor.
              do_join(slice, member_uri, member_pid, ctx)
            end

          _ ->
            do_join(slice, member_uri, member_pid, ctx)
        end

      :error ->
        {:error, {:member_not_registered, member_uri}}
    end
  end

  # Codex r1 HIGH-1 (2026-05-26) — strict version of
  # `monitor_ref_alive?/2`: True iff `monitors` contains AT LEAST ONE
  # ref for `member_uri` AND that ref was installed against
  # `current_pid`. We can't introspect the ref's underlying pid
  # directly from the ref, but we can ask the VM: `Process.info(
  # current_pid, :monitored_by)` returns the list of pids monitoring
  # `current_pid`. If self() (the Session process running this
  # invoke) is in that list, and we have a {ref => member_uri} entry,
  # the ref-and-pid invariant holds.
  #
  # Falls back to `false` (forcing a fresh monitor install via the
  # `do_join` path) if the member pid is dead — KindRegistry returned
  # the pid moments ago but a death between `lookup` and `Process.info`
  # is benign: we'll install a monitor on the (now-dead) pid, which
  # immediately fires :DOWN, which `handle_kind_message` then handles
  # cleanly (offline + last_seen).
  defp monitor_ref_for_current_pid?(monitors, %URI{} = member_uri, current_pid)
       when is_pid(current_pid) do
    has_uri_entry? =
      Enum.any?(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    has_uri_entry? and self_monitors?(current_pid)
  end

  defp self_monitors?(pid) when is_pid(pid) do
    case Process.info(pid, :monitored_by) do
      {:monitored_by, monitors_list} when is_list(monitors_list) ->
        self() in monitors_list

      _ ->
        # Process died between KindRegistry.lookup and here — fall
        # through to do_join (will install a fresh monitor that
        # immediately fires :DOWN; handled by `handle_kind_message`).
        false
    end
  end

  defp do_join(slice, %URI{} = member_uri, member_pid, ctx) do
    session_uri = ctx.self_uri

    # Drop ALL stale monitor entries for this member URI and DEMONITOR
    # each ref (Codex r1 MEDIUM-3, 2026-05-26). Pre-fix the refs were
    # removed from the map but the VM monitor stayed armed — when the
    # old PID later died, the resulting :DOWN landed in the Session
    # mailbox with a ref that wasn't in `slice.monitors` (handled by
    # the catch-all `:ignore` branch of `handle_kind_message/3`).
    # Cheap structurally (we're already iterating monitors here),
    # avoids slow leaks of stale VM monitor entries.
    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(slice.monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    for {ref, _uri} <- old_refs_for_member do
      _ = Process.demonitor(ref, [:flush])
    end

    monitors_without_member = Map.new(monitors_without_member)

    ref = Process.monitor(member_pid)

    new_members = Map.put(slice.members, member_uri, %{online: true})
    new_monitors = Map.put(monitors_without_member, ref, member_uri)

    # If this member has prior last_seen, replay missed messages.
    replay_messages_since(session_uri, member_uri, slice.last_seen)
    new_last_seen = Map.delete(slice.last_seen, member_uri)

    # RFC #402 (Allen 2026-05-26) — "first user to join is owner"
    # fallback. The session creator is normally set at session-create
    # time (`create_session/3` + `Session.spawn_from_template/2` both
    # pass `owner_uri` into `init_slice/1`). For sessions that
    # PRE-DATE that wiring (legacy snapshots restored with
    # `owner_uri: nil`) OR were created via a system-internal path
    # without a user creator, the FIRST user member to join takes
    # ownership.
    #
    # Discipline: only USER URIs (`entity://user/...`) can claim
    # ownership. Agents joined via `auto_join_session_members`
    # (orchestrator + workers) MUST NEVER become owner — they have
    # no inbox + no UI surface to exercise the restart authority.
    # `user_uri?/1` (same predicate used for join-notify gating) is
    # the structural check.
    prior_owner = Map.get(slice, :owner_uri)

    new_owner_uri =
      if is_nil(prior_owner) and user_uri?(member_uri) do
        member_uri
      else
        prior_owner
      end

    new_slice = %{
      slice
      | members: new_members,
        monitors: new_monitors,
        last_seen: new_last_seen
    }

    new_slice = Map.put(new_slice, :owner_uri, new_owner_uri)

    # RFC #402 (codex r1 HIGH 2026-05-26) — when this join transitions
    # `owner_uri` from `nil` to a real user, ALSO grant that user the
    # `OrchestratorAdmin :restart` cap on this session. Without this
    # the LV's restart gate (`caller_can_restart_orchestrator?/2`)
    # checks actual held caps — and the first-USER-join fallback
    # without a paired grant means the legacy/system-created path
    # never lets the owner exercise their authority.
    #
    # The two non-fallback paths (`create_session/3` and
    # `Session.spawn_from_template/2`) already grant this cap at
    # session-create time; this branch covers ONLY the
    # legacy-snapshot / system-created path where `owner_uri` was
    # `nil` at init.
    if is_nil(prior_owner) and user_uri?(member_uri) do
      grant_first_join_owner_cap(session_uri, member_uri)
    end

    broadcast_membership(session_uri, {:member_joined, member_uri})

    # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
    # coverage" — surface the join to the joinee's notification stream
    # so a freshly-added member sees they were added to a session.
    # Gated by `user_uri?/1`: agents don't have inboxes (per the same
    # convention `Workspace.add_member` uses).
    if user_uri?(member_uri) do
      _ =
        Ezagent.Notifications.notify(member_uri, %{
          type: :session_member_joined,
          body: %{
            text: "You joined session #{URI.to_string(session_uri)}.",
            session_uri: session_uri
          },
          source: __MODULE__
        })
    end

    {:ok, new_slice, %{members: Map.keys(new_members)}}
  end

  # Notifier/flash audit 2026-05-24 — same predicate
  # `Ezagent.Domain.Workspace.user_uri?/1` uses. Keeps the agent-target
  # silence guarantee local to Chat without crossing the
  # workspace-domain boundary.
  defp user_uri?(%URI{scheme: "entity", host: "user"}), do: true
  defp user_uri?(_), do: false

  # RFC #402 (codex r1 HIGH 2026-05-26) — companion to the
  # first-USER-join owner claim. Dispatches `identity.grant_cap` on
  # the new owner so they hold the specific
  # `cap(:session, OrchestratorAdmin, :restart, session_uri, ws)`
  # cap the LV's restart gate consults.
  #
  # System-principal dispatch (`system://template-materialize`) for
  # the same reason `EzagentDomainChat.grant_owner_orchestrator_admin_cap/3`
  # does: no human caller is on stack here — Chat.do_join runs under
  # whatever ctx invoked `chat.join`, which for `auto_join_session_members`
  # and the LV remount path is `system://session-internal`. We
  # escalate to template-materialize for the cap grant itself
  # (same closed Catalog principal the create-path uses).
  #
  # Workspace_uri resolution: look up the session's binding via
  # `WorkspaceRegistry`. If the session isn't workspace-bound yet
  # (boot-order edge), the grant is skipped — the next time the
  # owner navigates to /sessions, AdminLive's session-context
  # assigns re-trigger and the next join-or-create touch will
  # observe the binding. `feedback_let_it_crash_no_workarounds`:
  # we don't silently grant under a `:any` workspace — that would
  # be the cross-workspace escape hatch the cap struct forbids.
  defp grant_first_join_owner_cap(%URI{} = session_uri, %URI{} = owner_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} ->
        want = %Ezagent.Capability{
          kind: :session,
          behavior: Ezagent.Behavior.OrchestratorAdmin,
          # SPEC 2026-05-27 capability-action-axis — OrchestratorAdmin
          # actions/0 == [:restart].
          action: :restart,
          instance: session_uri,
          workspace_uri: workspace_uri,
          granted_by: owner_uri,
          granted_at: DateTime.utc_now()
        }

        target = URI.new!("#{URI.to_string(owner_uri)}?action=identity.grant_cap")

        # `mode: :cast` is REQUIRED here (NOT :call). We're currently
        # executing inside the Session Kind's `GenServer.call` (the
        # `chat.join` invocation), and `identity.grant_cap` dispatches
        # to the IdentityAdmin Behavior which runs
        # `check_grant_authorized` → `data_owner_of(OrchestratorAdmin,
        # session_uri)` → `OrchestratorAdmin.data_owner` →
        # `Chat.data_owner` → `Session.owner(session_uri)` →
        # `Ezagent.Kind.get_slice(session_uri, :chat)` which is itself
        # a `GenServer.call` to this very Session. A `:call`-mode
        # grant_cap dispatch therefore deadlocks (5-sec timeout, then
        # `:join` crashes with `:exit`).
        #
        # `:cast` enqueues the grant_cap dispatch to the User Kind's
        # mailbox and returns immediately; by the time IdentityAdmin
        # gets around to calling `Session.owner`, this Session has
        # already returned from `chat.join` and is ready for the next
        # message. Eventually-consistent: a tight LV remount + restart
        # within the cast latency window MIGHT see the cap not yet
        # granted; the gap is bounded by the User Kind mailbox queue
        # depth + one `get_slice` round-trip (sub-ms in practice).
        # Acceptable per RFC #402 — the legacy fallback path is rare.
        #
        # Best-effort: if the user Kind isn't currently alive (e.g.
        # unit tests calling `Chat.invoke(:join, ...)` directly
        # without spawning the member Kind first), `dispatch` returns
        # `{:error, :no_such_actor}`. We log + telemeter; the next
        # navigation/reconcile pass re-attempts (`do_join` re-enters
        # with `prior_owner` still nil if the slice mutation also
        # rolled back, OR with the owner already set and this branch
        # short-circuits — either way no permanent corruption).
        case Invocation.dispatch(%Invocation{
               target: target,
               mode: :cast,
               args: %{cap: want},
               ctx: %{
                 caller: owner_uri,
                 caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
                 reply: :ignore
               }
             }) do
          :ok ->
            :ok

          {:ok, _} ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "Chat.grant_first_join_owner_cap: cast dispatch failed for " <>
                "owner=#{URI.to_string(owner_uri)} on session=" <>
                "#{URI.to_string(session_uri)}: #{inspect(reason)}. " <>
                "Restart UX will be re-attempted on the next navigation."
            )

            :telemetry.execute(
              [:ezagent, :chat, :first_join_owner_cap, :failed],
              %{count: 1},
              %{session_uri: session_uri, owner_uri: owner_uri, reason: reason}
            )

            :ok
        end

      :error ->
        # Session not workspace-bound — see helper doc above.
        :ok
    end
  end

  # --- :leave ------------------------------------------------------------

  def invoke(:leave, slice, %{member: %URI{} = member_uri}, ctx) do
    {ref_to_remove, new_monitors} = pop_monitor_ref(slice.monitors, member_uri)

    if ref_to_remove, do: Process.demonitor(ref_to_remove, [:flush])

    new_slice = %{
      slice
      | members: Map.delete(slice.members, member_uri),
        monitors: new_monitors,
        last_seen: Map.delete(slice.last_seen, member_uri)
    }

    broadcast_membership(ctx.self_uri, {:member_left, member_uri})

    {:ok, new_slice}
  end

  # --- :set_working_copy -------------------------------------------------

  # Phase 7 completion PR-4 (SPEC §1.6) — write the durable
  # `template_working_copy` field on the Session's `:chat` slice. The
  # Generator (`Session.spawn_from_template/2`) populates `agent_slots`
  # + `routing_rules` + `orchestrator_template_uri` + `default_workspace_uri`
  # + `description` from the SessionTemplate; PR-5's orchestrator slot
  # tools maintain `agent_slots` mid-session through this same action.
  #
  # ## HIGH-2 hardening — orchestrator-only authorization
  #
  # `set_working_copy` is a normal Chat action, so dispatch CapBAC step
  # 5.5 derives the needed cap as `{kind: :session, behavior: Chat,
  # instance: <session_uri>}` — which a non-admin user holds
  # STRUCTURALLY (`{:session, :any, :any}` in their workspace). Without
  # an extra gate ANY session-cap holder could blindly overwrite the
  # working copy that `update_template` later hashes.
  #
  # So `invoke` requires an EXPLICIT authority beyond generic
  # session-chat: the caller must EITHER
  #
  # - be the session's orchestrator — hold the exact
  #   `{:within_session, self_uri}` delegated cap (cap #1, which the
  #   Generator grants ONLY to the orchestrator), OR
  # - be the system-internal Generator init path —
  #   `ctx[:system_internal] == true`, set ONLY by
  #   `system_set_working_copy/2`, never reachable from a user dispatch.
  #
  # A normal user holding only default session caps is denied here even
  # though step 5.5 passed.
  def invoke(:set_working_copy, slice, %{template_working_copy: wc}, ctx)
      when is_map(wc) do
    if working_copy_write_authorized?(ctx) do
      new_slice = Map.put(slice, :template_working_copy, wc)
      {:ok, new_slice, %{template_working_copy: wc}}
    else
      {:error, :unauthorized}
    end
  end

  # The HIGH-2 orchestrator-only gate. `ctx.self_uri` is the Session
  # Kind's own URI (injected by `Kind.Runtime` step 5).
  defp working_copy_write_authorized?(ctx) do
    Map.get(ctx, :system_internal) == true or
      orchestrator_cap_present?(ctx)
  end

  # True iff `ctx.caps` carries a `{:within_session, self_uri}` cap on
  # the `:session` kind — i.e. the caller IS this session's orchestrator
  # (cap #1, granted only by the Generator to the orchestrator agent).
  defp orchestrator_cap_present?(ctx) do
    self_uri = Map.get(ctx, :self_uri)
    caps = Map.get(ctx, :caps, MapSet.new())

    case self_uri do
      %URI{} = sess_uri ->
        self_str = URI.to_string(sess_uri)

        Enum.any?(caps, fn
          %Ezagent.Capability{kind: :session, instance: {:within_session, %URI{} = s}} ->
            URI.to_string(s) == self_str

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  @doc """
  Generator-only internal path to write the durable
  `template_working_copy` field (HIGH-2 hardening).

  `Ezagent.Entity.Session.spawn_from_template/2` is the privileged
  bootstrap program that does the FIRST `template_working_copy` write,
  before any orchestrator cap exists. It cannot hold the orchestrator's
  `{:within_session, _}` cap (the session is brand-new), so it uses
  this path: a `chat.set_working_copy` dispatch carrying
  `ctx[:system_internal] = true`. That marker is honored ONLY here and
  by `invoke/4`'s `working_copy_write_authorized?/1` — it is NOT
  settable from any user-facing dispatch (the MCP tool path supplies
  `caps`, never `system_internal`).

  Returns the dispatch result.
  """
  @spec system_set_working_copy(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_working_copy(%URI{} = session_uri, working_copy) when is_map(working_copy) do
    target = Ezagent.URI.parse!("#{URI.to_string(session_uri)}?action=chat.set_working_copy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{template_working_copy: working_copy},
           # SPEC caps-cleanup-v1 §4.4 — Session slice-internal write
           # of the durable template working_copy runs under
           # `system://session-internal` (closed Catalog).
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("session-internal"),
             caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
             system_internal: true,
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{template_working_copy: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # --- Kind-message hook -------------------------------------------------

  @doc """
  `Ezagent.Kind.Server.handle_info/2` forwards all GenServer messages here.
  Phase 2 handles `:DOWN` from `Process.monitor`; everything else is
  `:ignore`-ed (return value tells the server "slice unchanged").

  On `:DOWN` for a known member ref: flip `online` → false, record
  `last_seen = now`. The monitor ref is removed from `monitors` (no
  point holding a dead ref) but the URI stays in `members` so rejoin
  recognizes it.
  """
  def handle_kind_message({:DOWN, ref, :process, _pid, _reason}, slice, ctx) do
    case Map.pop(slice.monitors, ref) do
      {nil, _} ->
        # Not one of our monitors (could be another Behavior's ref or
        # a stale ref after a leave).
        :ignore

      {member_uri, new_monitors} ->
        now = DateTime.utc_now()

        new_members =
          Map.update(slice.members, member_uri, %{online: false}, &Map.put(&1, :online, false))

        new_last_seen = Map.put(slice.last_seen, member_uri, now)

        new_slice = %{
          slice
          | monitors: new_monitors,
            members: new_members,
            last_seen: new_last_seen
        }

        broadcast_membership(ctx.self_uri, {:member_offline, member_uri, now})

        {:ok, new_slice}
    end
  end

  def handle_kind_message(_other_message, _slice, _ctx), do: :ignore

  # --- Interface schema --------------------------------------------------

  @impl Ezagent.Behavior
  def interface do
    %{
      send: %{
        description: "Post a message into the session and fan it out to members",
        args: %{message: message_schema()},
        returns: %{stored: :boolean},
        modes: [:cast]
      },
      receive: %{
        description: "Deliver a session message to this member (User inbox / Agent bridge)",
        args: %{message: message_schema()},
        returns: %{},
        modes: [:cast]
      },
      join: %{
        description: "Add a member to the session and replay any missed messages",
        args: %{member: :uri},
        returns: %{members: {:list, :uri}},
        # Allow both — admin User joins via :cast at boot (non-blocking);
        # admin or programmatic callers may :call to read members back.
        modes: [:call, :cast]
      },
      leave: %{
        description: "Remove a member from the session",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast]
      },
      set_working_copy: %{
        description:
          "Write the durable template_working_copy field on the Session's :chat " <>
            "slice (the orchestrator's source-template record — Phase 7 SPEC §1.6)",
        args: %{template_working_copy: :map},
        returns: %{template_working_copy: :map},
        modes: [:call]
      }
    }
  end

  # --- Topic helpers (public — Ezagent.Kind.Server / LV subscribe via these) -

  @doc "PubSub topic for in-session events (chat stream feed)."
  @spec session_events_topic(URI.t() | String.t()) :: String.t()
  def session_events_topic(%URI{} = uri), do: session_events_topic(URI.to_string(uri))
  def session_events_topic(uri_str) when is_binary(uri_str), do: "esr:session:#{uri_str}:events"

  @doc "PubSub topic for a User's personal receive notifications."
  @spec user_events_topic(URI.t() | String.t()) :: String.t()
  def user_events_topic(%URI{} = uri), do: user_events_topic(URI.to_string(uri))
  def user_events_topic(uri_str) when is_binary(uri_str), do: "esr:user:#{uri_str}:events"

  # --- Internals ---------------------------------------------------------

  # Allen 2026-05-26: detect mentions that didn't make it to recipients
  # (because the mentioned URI isn't a session member) and emit a
  # `:mention_failed` notification to the sender. This closes the
  # silent-drop UX gap where `@curl_test_alpha hello` produced no
  # response and no error when curl_test_alpha was not a session
  # member.
  #
  # The discriminator is "the mention parser resolved it to a real
  # entity but the Resolver's `valid_member?` filter dropped it" — i.e.
  # `msg.mentions ∖ recipients`. Casual `@text` (no Kind URI match)
  # never enters `msg.mentions` and is silent. Cross-workspace and
  # cross-session targets also surface here (`valid_member?` rejects).
  defp notify_dropped_mentions(%Message{} = msg, recipients, session_uri, ctx) do
    mention_uris = msg.mentions || []

    if mention_uris == [] do
      :ok
    else
      recipient_strs = MapSet.new(recipients, &URI.to_string/1)

      dropped =
        mention_uris
        |> Enum.map(&to_uri_struct/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn uri -> MapSet.member?(recipient_strs, URI.to_string(uri)) end)

      sender_uri = msg.sender

      _ = ctx

      Enum.each(dropped, fn dropped_uri ->
        try do
          # System-level emit — the session Kind is delivering an
          # advisory UX notification about the sender's own message
          # processing; no caller-cap gate needed (default ctx
          # `%{caps: :system}` bypasses `:notify` cap check, which
          # would otherwise require the sender to hold a self-notify
          # cap — too punitive for advisory UX).
          Ezagent.Notifications.notify(
            sender_uri,
            %{
              type: :mention_failed,
              body: %{
                message: "Your @-mention was not delivered (target is not a session member).",
                mentioned_uri: URI.to_string(dropped_uri),
                session_uri: URI.to_string(session_uri)
              },
              source: __MODULE__
            }
          )
        rescue
          # Notifier failures are non-fatal — they're advisory UX. The
          # send itself already succeeded for the resolved recipients.
          e ->
            require Logger

            Logger.warning(
              "Ezagent.Behavior.Chat: notify mention_failed raised for " <>
                "#{URI.to_string(dropped_uri)}: #{Exception.message(e)}"
            )
        end
      end)

      :ok
    end
  end

  defp to_uri_struct(%URI{} = uri), do: uri

  defp to_uri_struct(s) when is_binary(s) do
    Ezagent.URI.parse!(s)
  rescue
    _ -> nil
  end

  defp to_uri_struct(_), do: nil

  defp dispatch_cross_session(target_session_uri, %Message{} = msg) do
    # Recursively dispatch chat/send on the target session — that
    # session handles its own member fan-out + further routing rules.
    target = URI.new!("#{URI.to_string(target_session_uri)}?action=chat.send")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: msg.sender,
        # SPEC caps-cleanup-v1 §4.4 — cross-session forwarding is
        # system-routed; `system://chat-router` per Catalog.
        caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
        reply: :ignore
      }
    })
  end

  defp dispatch_receive(recipient_uri, %Message{} = msg, session_uri) do
    target = URI.new!("#{URI.to_string(recipient_uri)}?action=chat.receive")

    # SPEC caps-cleanup-v1 §4.4 — Session fan-out is system-routed
    # message delivery; runs under `system://chat-router` (closed
    # Catalog). The session URI stays as caller for provenance.
    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
          reply: :ignore
        }
      })

    # PR-3 of Read Receipts rollout (SPEC
    # `docs/superpowers/specs/2026-05-23-read-receipts.md` §10) —
    # mark `:delivered` for the recipient when dispatch succeeds.
    # "Delivered" here = the chat.receive dispatch reached the
    # recipient Kind (cap-checked, queued for invoke). Fire-and-forget
    # — mark failure must not block message fan-out.
    if result == :ok do
      _ = Ezagent.Chat.ReadMarker.mark(session_uri, recipient_uri, msg.id, :delivered)
    end

    result
  end

  # PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  # §9) — `maybe_notify_external/3` retired. External-mirror fan-out
  # moved to the generic ExternalMirror Domain (Session Publisher →
  # per-binding Worker → Adapter+Binding). Chat no longer needs an
  # opportunistic `BehaviorRegistry.lookup` hook here.

  defp replay_messages_since(_session_uri, _member_uri, last_seen) when last_seen == %{}, do: :ok

  defp replay_messages_since(session_uri, member_uri, last_seen) do
    case Map.get(last_seen, member_uri) do
      nil ->
        :ok

      last_seen_at ->
        for msg <- MessageStore.in_session_since(session_uri, last_seen_at) do
          dispatch_receive(member_uri, msg, session_uri)
        end

        :ok
    end
  end

  defp broadcast_membership(session_uri, event) do
    # Per-session fan-out — the LV chat stream subscribes here for
    # its own session's events.
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      session_events_topic(session_uri),
      event
    )

    # Global fan-out — `EzagentDomainChat.PresenceFanout` subscribes
    # to maintain the `user_uri → MapSet(session_uri)` reverse index
    # without coupling back to this module. Wrapper carries the
    # session_uri the inner `event` lacks (events are
    # `{:member_joined | :member_left | :member_offline, member_uri, ...}`).
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      "esr:session_membership:changes",
      {:session_membership_change, session_uri, event}
    )
  end

  defp pop_monitor_ref(monitors, member_uri) do
    Enum.reduce(monitors, {nil, %{}}, fn
      {ref, ^member_uri}, {nil, acc} -> {ref, acc}
      {ref, uri}, {found_ref, acc} -> {found_ref, Map.put(acc, ref, uri)}
    end)
  end

  # Body comes back from MessageStore.load with string keys (Ecto :map
  # column → JSON-decoded via ecto_sqlite3); freshly-constructed bodies
  # in-flight have atom keys. Accept either to be safe across the
  # dispatch boundary.
  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # Phase 6 PR 14 — attachment helpers for bridge payload.
  defp body_attachments(%{attachments: list}) when is_list(list), do: list
  defp body_attachments(%{"attachments" => list}) when is_list(list), do: list
  defp body_attachments(_), do: []

  # Mirror cc-openclaw channel_server convention: at most one `file_path`
  # string in meta per notification; multi-attachment context lives in the
  # text hint already concatenated to `content`.
  defp first_attachment_path([]), do: nil

  defp first_attachment_path([att | _]) do
    case att[:local_path] || att["local_path"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp first_attachment_path(_), do: nil

  defp attachment_hint_text([]), do: ""

  defp attachment_hint_text(list) do
    parts =
      Enum.map(list, fn att ->
        type = att[:type] || att["type"] || "unknown"
        name = att[:name] || att["name"] || "?"
        "[attachment: type=#{type} name=#{name}]"
      end)

    Enum.join(parts, " ")
  end

  defp message_schema do
    %{
      id: :string,
      sender: :uri,
      mentions: {:list, :uri},
      body: :map,
      ref_id: {:option, :string},
      inserted_at: :map
    }
  end

  # PR-OWN-2 (caps-data-ownership SPEC #306 §3.3 + §7) — data_owner
  # for Chat caps is the session's `:owner_uri` (the entity that
  # created the session). Looked up via `Ezagent.Entity.Session.owner/1`.
  #
  # Return shapes:
  #  - `%URI{}` — session has a recorded owner; that URI grants
  #  - `:no_owner` — system session or pre-PR-OWN-2 snapshot without
  #    `:owner_uri`; only the bootstrap admin can grant
  #  - `:any` — input is `:any` (class-wide grant query at the
  #    `CapabilityRegistry` level); workspace admin grants
  #
  # Chat's `data_owner/1` ONLY applies to instances under the Session
  # Kind. Chat is also registered against User + Agent Kinds (for
  # `:receive`), but those Kinds' data ownership is governed by
  # `Behavior.Identity.data_owner/1` (PR-OWN-3) — Chat returning
  # `:no_owner` for non-session URIs leaves Identity to be authoritative.
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
