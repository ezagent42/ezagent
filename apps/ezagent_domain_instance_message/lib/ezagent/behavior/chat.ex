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

  Both injected by `Ezagent.Kind.Runtime` immediately before the handler
  fires (single point of contact, plugins never plumb manually). Session
  uses `ctx.self_uri` to scope MessageStore writes and PubSub topics;
  receivers branch on `ctx.kind_module` to pick the delivery shape
  (broadcast vs bridge push).

  ## Migration note (P2-a r3, 2026-05-28)

  Migrated to the new SPEC 2026-05-28 action grammar:
  - Slice mutations → `{:set, :key, value}` effects.
  - In-session + membership PubSub broadcasts → `{:notify, topic, payload}` effects.
  - Cross-session forwarding + recipient fan-out → `{:dispatch, %Cmd{}}` effects.
  - Result-dependent in-handler dispatches (where we need to branch on the
    dispatch return value, e.g. `ReadMarker.mark` after a successful
    chat.receive cast) stay as `Ezagent.Router.dispatch/1` calls in the
    handler body — the effect grammar discards dispatch return values.

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 §2.3C — representative
  ## example C: the RICH case)

  Converted from `use Ezagent.Behavior` to `use Ezagent.Lifecycle` (the
  two-container `%{state, transients}` developer API). The natural split:

  - **STATE (persistent — survives restart):** `members`, `owner_uri`,
    `last_seen`, `last_message_id`, `last_message`, `send_cursor`,
    `recent_messages`, `template_working_copy`. Built ONCE by `create/1`.

  - **TRANSIENT (never persisted — rebuilt every start):** `monitors`
    (the `ref → URI` map from `Process.monitor`). The refs are dead after
    a restart; before this migration they lived in the SAME `:chat` slice
    as `members` and got snapshotted-then-rehydrated-as-garbage — a latent
    bug where `handle_signal({:DOWN, ...})` could NEVER match a rehydrated
    ref, so offline detection silently degraded.

  `activate/2` rebuilds the monitor map from the PERSISTED `members` set:
  `Process.monitor` each live member, producing a fresh `ref → URI` map.
  This is the self-heal that the snapshot-of-dead-refs approach lacked
  (§2.3C — THE KEY FIX). Because `activate/2` runs on EVERY start (fresh
  spawn AND cold-load) and is the ONLY site that fills `:monitors`, a dead
  ref can no longer survive a restart.

  Handler accessor changes (§5 recipe step 7): `members` / `owner_uri` /
  `last_seen` / send-tracking fields stay `ctx[:read]` + `{:set, ...}`;
  `monitors` reads go to `ctx.transients[:monitors]` and `monitors` writes
  become `{:set_transient, :monitors, ...}` effects (§7 OQ-2). The `:DOWN`
  signal in `handle_signal/2` returns `{:set_transient, :monitors, ...}`
  (drop the dead ref) + `{:set, :last_seen, ...}` (persisted) + the
  `online → false` member flip via `{:set, :members, ...}`.

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.Behavior.Chat` — a domain
  module (`apps/ezagent_domain_instance_message`) naming its own domain concept
  (`Chat`), with five actions whose intent the name closely tracks. NO
  violation; kept as-is (a rename would touch the `:chat` snapshot slice
  key + every call site for no clarity gain).
  """

  # lifecycle:state_slice_override
  #
  # The `:chat` slice key is pinned (snapshot-compat — SPEC §5 step 2 /
  # §7 OQ-7). The auto-derived key from `Ezagent.Behavior.Chat` would be
  # `:chat` anyway, but the multi-Kind subset registration (Session uses
  # the slice; User/Agent default it to `%{}`) + every existing
  # `kind_snapshots` row + integration test that reads `:chat` by name
  # depends on the stable key, so we declare it explicitly with the
  # sanctioned marker rather than relying on derivation.
  use Ezagent.Lifecycle, state_slice: :chat
  reads_siblings([:sandbox])

  require Logger

  alias Ezagent.{Cmd, KindRegistry, Message, MessageStore}
  alias Ezagent.Routing.Legend

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

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Chat is registered on:
  #   - Session Kind for :send, :join, :leave, :set_working_copy
  #   - User Kind for :receive
  #   - Agent Kind for :receive
  # The multi-Kind registration → kind axis is `:any` (check 11(b) escape).

  action(:send,
    args: %{message: :map},
    returns: %{stored: :boolean},
    caps: [:send],
    modes: [:cast],
    description: "Post a message into the session and fan it out to members"
  )

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Deliver a session message to this member (User inbox / Agent bridge)"
  )

  action(:join,
    # Allow both — admin User joins via :cast at boot (non-blocking);
    # admin or programmatic callers may :call to read members back.
    args: %{member: :uri},
    returns: %{members: {:list, :uri}},
    caps: [:join],
    modes: [:call, :cast],
    description: "Add a member to the session and replay any missed messages"
  )

  action(:leave,
    args: %{member: :uri},
    returns: %{},
    caps: [:leave],
    modes: [:cast],
    description: "Remove a member from the session"
  )

  action(:set_working_copy,
    args: %{template_working_copy: :map},
    returns: %{template_working_copy: :map},
    caps: [:set_working_copy],
    modes: [:call],
    description:
      "Write the durable template_working_copy field on the Session's :chat " <>
        "slice (the orchestrator's source-template record — Phase 7 SPEC §1.6)"
  )

  # team-routing-unification §3.6 (PR-6) — install/overwrite the session-scoped
  # legend registry (`name => %{member_set, bound_rule_set, fold}`) on the
  # Session's :chat slice, alongside :members. Same authority class as
  # :set_working_copy (orchestrator / system-internal only — a legend fronts a
  # team + its rule-set, an orchestrator-config concern), so it reuses
  # `working_copy_write_authorized?/1`.
  action(:set_legends,
    args: %{legends: :map},
    returns: %{legends: :map},
    caps: [:set_legends],
    modes: [:call],
    description:
      "Write the session-scoped legend registry on the Session's :chat slice " <>
        "(team-routing-unification §3.6, PR-6)"
  )

  # team-routing-unification §3.4 (PR-4b) / §3.7 (PR-7) — install/overwrite the
  # session-scoped named prompt-template map (`name => template string`) on the
  # Session's :chat slice. Same trusted-principal authority class as
  # :set_legends (a prompt-template fronts a team's delivery transform, an
  # orchestrator/system-config concern). PR-4b added the READ side
  # (`render_for_delivery/4`); PR-7 adds this WRITE side so SessionTemplate
  # materialization can install a template's `prompt_templates`.
  action(:set_prompt_templates,
    args: %{prompt_templates: :map},
    returns: %{prompt_templates: :map},
    caps: [:set_prompt_templates],
    modes: [:call],
    description:
      "Write the session-scoped named prompt-template map on the Session's " <>
        ":chat slice (team-routing-unification §3.4/§3.7, PR-7)"
  )

  # `create/1` — FIRST-EVER existence (SPEC 2026-05-29 §2). Builds the
  # PERSISTENT `state`. The macro-injected `init_slice/1` wraps this in
  # the two-container `%{state: ..., transients: %{}}` shape and runs it
  # ONCE (gated by the durable ever-created marker). `:monitors` is NOT
  # here — it is a TRANSIENT, rebuilt by `activate/2` on every start.
  #
  # NOTE: `state_slice/0` is macro-emitted from the `state_slice: :chat`
  # override above — the hand-rolled `def state_slice, do: :chat` is gone.
  @impl Ezagent.Lifecycle
  def create(args) do
    # Slice shape is the union across Kinds — Session uses all the
    # persistent maps; User/Agent's :receive doesn't read or write most
    # of them but leaving the keys here means a `Map.get` on any Kind
    # returns the consistent shape (defensive over the BehaviorRegistry
    # per-Kind subset model where User/Agent don't list Chat in
    # `behaviors/0` and so don't create this state anyway — `Kind.Runtime`
    # defaults missing slices to `%{}`, which the Session-only fields
    # tolerate).
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
    {:ok,
     %{
       # %{URI => %{online: bool}}
       members: %{},
       owner_uri: Map.get(args, :owner_uri),
       # NOTE: `:monitors` (%{ref => URI} Process.monitor refs) is GONE
       # from STATE — it is a TRANSIENT now, rebuilt by `activate/2`
       # (SPEC §2.3C). Persisting it snapshotted dead refs.
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
       # team-routing-unification §3.4 (PR-4b): session-scoped named prompt
       # templates (name => template string), applied at delivery to a rule's
       # receiver via `render_for_delivery/4`. Empty by default → no rendering
       # (behaviour-preserving). Readers MUST default via
       # `Map.get(slice, :prompt_templates, %{})` for legacy snapshots.
       prompt_templates: %{},
       # team-routing-unification §3.6 (PR-6): session-scoped legend registry
       # (`name => %{member_set, bound_rule_set, fold}`). A legend is a symbolic
       # team handle that fronts a rule-set (resolution layer: `Ezagent.Routing.
       # Legend`). Empty by default → no legends (behaviour-preserving). Readers
       # MUST default via `legends_of/1` for legacy snapshots.
       legends: %{},
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
       # key. `Kind.Snapshot.load_or_init/3` merges at the
       # slice-key level (`Map.merge(fresh, loaded)`), so the loaded
       # `:chat` slice would replace the fresh one entirely — readers
       # MUST therefore treat a missing key as the default via
       # `template_working_copy/1` below rather than dot-access.
       template_working_copy: default_template_working_copy()
     }}
  end

  # `activate/2` — EVERY process (re)start (SPEC 2026-05-29 §2.3C, THE
  # KEY FIX). Rebuilds the TRANSIENT `:monitors` map from the PERSISTED
  # `members` set: `Process.monitor` each live member, producing a fresh
  # `ref → URI` map. The refs from a prior incarnation are dead; this is
  # the self-heal that the old snapshot-of-`:monitors` lacked.
  #
  # `:error` from `KindRegistry.lookup/1` means the member's Kind is not
  # currently alive — we simply do not install a monitor for it (its URI
  # stays in the persisted `members` so a later `:join` / `:DOWN` still
  # recognizes it; if it is genuinely offline, no monitor is needed until
  # it rejoins). Members that ARE live get a fresh, REAL monitor — so the
  # `:DOWN` signal (`handle_signal/2`) can match again after a restart.
  @impl Ezagent.Lifecycle
  def activate(state, _ctx) do
    monitors =
      state
      |> Map.get(:members, %{})
      |> Map.keys()
      |> Enum.flat_map(fn %URI{} = uri ->
        case KindRegistry.lookup(uri) do
          {:ok, pid} when is_pid(pid) -> [{Process.monitor(pid), uri}]
          _ -> []
        end
      end)
      |> Map.new()

    {:ok, %{monitors: monitors}}
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
      # team-routing-unification §3.8 (PR-8) — `agent_slots` is REMOVED
      # (clean cutover, no shim). A "slot" was a member with extra facets
      # (§3.1); the orchestrator now builds a team via session MEMBERS +
      # RULE-SETS (see `Ezagent.Orchestrator.Tools.add_managed_member` +
      # `define_rule_set_rule`). Spawn-source state (`source_template_uri`)
      # lives on the member's `:members` meta, NOT a slot tuple.
      #
      # [{matcher_ast :: term(), [role_name :: String.t()]}]
      # rule-set routing rows (receivers are role_names / URIs, resolved on
      # instantiate). Kept for SessionTemplate snapshot compatibility.
      routing_rules: [],
      # URI.t() | nil — the orchestrator agent's AgentTemplate
      orchestrator_template_uri: nil,
      # URI.t() | nil — the orchestrator Agent Kind chosen for this
      # Session. Stored once at create and read through Ezagent.UriQuery;
      # callers must not re-derive it from URI shape.
      orchestrator_uri: nil,
      # URI.t() | nil — the SessionTemplate this Session was
      # instantiated from (the Generator's `parent_template_uri`,
      # Task #110). Durable because Session is `{:snapshot, :on_change}`,
      # so it survives a phx restart. It is the canonical source the
      # lazy rebuild in
      # `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1` prefers
      # for the `:parent_template_uri` the `update_template` MCP tool
      # requires — NOT derivable from the session URI in the general case
      # (the `<owner>-<template>` path segment can be ambiguous). `nil`
      # for sessions that never went through the Generator (plain system
      # sessions) — those have no orchestrator.
      session_template_uri: nil,
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
  def template_working_copy(chat_slice) when is_map(chat_slice) do
    Map.get(chat_slice, :template_working_copy, default_template_working_copy())
  end

  # --- :send -------------------------------------------------------------

  def handle_send(%{message: %Message{} = msg}, ctx) do
    session_uri = ctx[:self_uri]

    # team-routing-unification §3.6 (PR-6): `:legend_triggers` is VIRTUAL, so
    # the `MessageStore.write/2` round-trip re-fetches a persisted row WITHOUT
    # it (resets to the `[]` default). Capture it off the ORIGINAL inbound msg
    # and re-attach to `stored_msg` below so the rule-set ENTRY rule's
    # `mention(<legend_name>)` matcher fires through the NORMAL Resolver
    # expansion (carrying the entry's `prompt_template_ref` + expanding magic
    # receivers like `$session_members`). `[]` → identical to pre-PR-6 routing.
    legend_triggers = Map.get(msg, :legend_triggers) || []

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
        #
        # Re-attach the virtual legend triggers (lost across the persist
        # round-trip) so the legend entry rule still matches (PR-6).
        msg = %{stored_msg | legend_triggers: legend_triggers}

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
        members_map = ctx[:read].(:members, %{})
        in_session_members = Map.keys(members_map)

        workspace_uri =
          case Ezagent.WorkspaceRegistry.lookup(session_uri) do
            {:ok, uri} -> uri
            :error -> nil
          end

        # team-routing-unification §3.4/§3.5 (PR-4b): resolve WITH matched-rule
        # ctx so the per-recipient delivery can render that rule's prompt
        # template. The bare URI list (for notify_dropped_mentions) is mapped
        # off; ctx is threaded into the dispatch loop below.
        recipients_with_ctx =
          Ezagent.Routing.Resolver.resolve_with_ctx(
            msg,
            session_uri,
            in_session_members,
            workspace_uri: workspace_uri
          )

        recipients = Enum.map(recipients_with_ctx, fn {uri, _ctx} -> uri end)
        prompt_templates = ctx[:read].(:prompt_templates, %{})

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

        # PR-3 of Read Receipts rollout: dispatch + (on success only)
        # mark `:delivered`. We need the dispatch result to gate the
        # mark, so this stays in-handler (effect grammar discards
        # dispatch return values). Cross-session forwarding does not
        # need a ReadMarker side effect.
        for {recipient, rule_ctx} <- recipients_with_ctx do
          if recipient.scheme == "session" do
            dispatch_cross_session_call(recipient, msg)
          else
            # Path-A delivery transform (§3.4): render the matched rule's
            # prompt template into THIS recipient's message (no template →
            # unchanged). Applies to agent + user recipients alike.
            delivered = render_for_delivery(msg, rule_ctx, prompt_templates, session_uri)
            dispatch_receive_call(recipient, delivered, session_uri)
          end
        end

        # PR-EM-6-PRE (Allen 2026-05-25) — mutate the slice so the
        # SliceChange hook in `Kind.Runtime` fires for every send. See
        # `init_slice/1` for the three-field rationale (HIGH-1 +
        # HIGH-2 from codex r1 2026-05-25).
        prev_cursor = ctx[:read].(:send_cursor, 0)

        # In-session broadcast for LV chat stream is a :notify effect
        # (the executor calls the PubSub broadcast for us).
        #
        # `session_uri` here is `ctx[:self_uri]`, which — when the
        # inbound target was built via stdlib `URI.parse/1` — carries the
        # deprecated `:authority` field. The broadcast payload is the
        # subscriber-facing value (LV chat stream + tests pattern-match
        # on `{:chat_message, session_uri, _}`), and a consumer comparing
        # it to a canonical `Ezagent.URI.new!(...)` URI (authority: nil)
        # would not `==`-match. Canonicalize the broadcast URI so the
        # payload always carries the RFC-3986 `authority: nil` shape.
        canonical_session_uri = Ezagent.URI.new!(URI.to_string(session_uri))

        {:ok, %{stored: true},
         [
           {:set, :last_message_id, msg.id},
           {:set, :last_message, msg},
           {:set, :send_cursor, prev_cursor + 1},
           {:notify, session_events_topic(session_uri),
            {:chat_message, canonical_session_uri, msg}}
         ]}

      {:error, reason} ->
        {:error, {:message_store_write_failed, reason}}
    end
  end

  # --- :receive ----------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    case ctx[:kind_module] do
      Ezagent.Entity.User ->
        # PR-N3 (SPEC v2 notification-architecture-v2 §2.4 + §3 lines
        # 204-211, Allen 2026-05-25) — producer-pattern proof.
        #
        # Both the legacy raw PubSub broadcast to
        # `esr:user:<uri>:events` and the new `Ezagent.Notifications.notify/3`
        # call were DELETED here. SPEC §2.4 / §3 PR-N3: the User-branch
        # is just "mutate the receive slice; the runtime emits the
        # slice-change event". `Ezagent.Kind.Runtime.handle_dispatch/4`
        # detects `new_slice != old_slice` and `Kind.Server.commit_and_notify/3`
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
        cursor = Map.get(ctx, :slice_change_cursor)
        prior_ring = ctx[:read].(:recent_messages, [])
        new_entry = {cursor, msg.id}

        trimmed_ring =
          [new_entry | prior_ring]
          |> Enum.take(@recent_messages_ring_depth)

        {:ok, %{},
         [
           {:set, :last_received, %{message_id: msg.id, at: DateTime.utc_now()}},
           {:set, :recent_messages, trimmed_ring}
         ]}

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
          "sender" => Ezagent.URI.stable_key(msg.sender),
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
            s when is_binary(s) and s != "" -> Ezagent.URI.new!(s)
            _ when source_session != "" -> Ezagent.URI.new!(source_session)
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

        # PR-DR (blocker #1): self-heal a vanished bridge before dropping. If
        # the agent's claude/python subprocess exited (its WS Channel.terminate
        # unbound the Registry row), `deliver_ensuring/2` relaunches it
        # (snapshot-sourced, flavor-neutral) + awaits the rebind, then retries
        # once — instead of silently `:no_bridge`-dropping the routed message.
        _ =
          case resolve_agent_flavor_from_ctx(ctx) do
            {:ok, flavor} ->
              Ezagent.AgentBridge.deliver_ensuring_with_flavor(ctx[:self_uri], payload, flavor)

            :none ->
              Ezagent.AgentBridge.deliver_ensuring(ctx[:self_uri], payload)
          end

        {:ok, %{}, []}

      _other ->
        # Should not happen — :receive is only registered for User/Agent.
        {:error, {:receive_unsupported_for_kind, ctx[:kind_module]}}
    end
  end

  defp resolve_agent_flavor_from_ctx(ctx) do
    ctx
    |> get_in([:siblings, :sandbox])
    |> EzagentDomainInstanceMessage.UriQueryResolvers.resolve_flavor_from_sandbox()
  end

  # --- :join -------------------------------------------------------------

  def handle_join(%{member: %URI{} = member_uri} = args, ctx) do
    # team-routing-unification §3.1 — optional, NON-authority-bearing member
    # facets carried on the join: `:role_name` (a stable per-session alias the
    # member can be addressed by) and `:in_session_template` (snapshot flag for
    # SessionTemplate materialize, PR-7). Absent keys default to "no facet" so a
    # plain join keeps the minimal `%{online: true}` meta.
    #
    # `:provenance` (management authority) is DELIBERATELY NOT accepted here:
    # codex review of PR-5a flagged that an args-supplied provenance lets a
    # join caller forge the authority PR-5b will trust ({:manages, provenance}).
    # provenance is introduced in PR-5b together with its caller-derivation +
    # authorization, as one reviewable security unit — never from raw args.
    #
    # The `:join` action schema declares only `member`, so these facet args
    # pass through unvalidated by the runtime — sanitize_facets/1 drops any
    # malformed value (codex PR-5a #1 "type-check the facet args") so a bad
    # `role_name` can't crash the downstream `is_binary` guards.
    # team-routing-unification §3.1 / §3.7 (PR-7): `:source_template_uri` is a
    # SPAWN-SOURCE facet — the AgentTemplate URI a spawned/managed member was
    # recreated from, so SessionTemplate materialization (and a future
    # respawn/regeneration) can rebuild this member. It is NON-authority-bearing
    # (provenance, the management-authority facet, is still deliberately absent
    # here — it lands in PR-5b/PR-8 with its caller-derivation). Like the other
    # facets it is sanitized below so a malformed value can't crash a guard.
    facets =
      args
      |> Map.take([:role_name, :in_session_template, :source_template_uri])
      |> sanitize_facets()

    case KindRegistry.lookup(member_uri) do
      {:ok, member_pid} ->
        # Session auto-join (Allen 2026-05-26) — idempotency: when a
        # member rejoins we MUST NOT stack a fresh `Process.monitor` on
        # top of the live one. Pre-fix, every rejoin leaked a monitor
        # ref in `slice.monitors` (cleaned only on `:DOWN`, which never
        # fired for the live member).
        members = ctx[:read].(:members, %{})
        # `:monitors` is a TRANSIENT now (SPEC §2.3C) — read it from
        # `ctx.transients`, not the persistent `ctx[:read]`.
        monitors = (ctx[:transients] || %{})[:monitors] || %{}

        case Map.get(members, member_uri) do
          %{online: true} ->
            if monitor_ref_for_current_pid?(monitors, member_uri, member_pid) do
              # Already a live, monitored, online member with the
              # SAME PID we're being asked to (re)join. True no-op.
              #
              # team-routing-unification §3.1 (codex PR-5a #3): facets are
              # set at join, NOT mutated by an idempotent rejoin — this branch
              # intentionally does NOT apply `facets`. Changing a live member's
              # role_name / in_session_template is a member-RECONFIGURE concern
              # (PR-5b's `:manage` authority), not a side effect of re-issuing
              # `chat.join`. The stale/offline paths below DO reach do_join and
              # preserve+overlay facets (so reconnect never loses them).
              {:ok, %{members: Map.keys(members), already_member: true}, []}
            else
              # Stale ref (different/dead PID) or no ref — drop any
              # stale entries + install a fresh monitor.
              do_join(member_uri, member_pid, ctx, facets)
            end

          _ ->
            do_join(member_uri, member_pid, ctx, facets)
        end

      :error ->
        {:error, {:member_not_registered, member_uri}}
    end
  end

  # Codex r1 HIGH-1 (2026-05-26) — strict version of
  # `monitor_ref_alive?/2`: True iff `monitors` contains AT LEAST ONE
  # ref for `member_uri` AND that ref was installed against
  # `current_pid`.
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
        false
    end
  end

  defp do_join(%URI{} = member_uri, member_pid, ctx, facets) do
    members = ctx[:read].(:members, %{})

    # team-routing-unification §3.1 (spec §8 decision #2) — `role_name` is
    # UNIQUE PER SESSION. Reject a join that would assign a role_name already
    # held by a DIFFERENT member BEFORE any monitor side effect, so a rejected
    # join leaks no monitor. A member rejoining with its OWN role_name is fine.
    case role_name_conflict(members, member_uri, Map.get(facets, :role_name)) do
      {:error, _} = err -> err
      :ok -> do_join_apply(member_uri, member_pid, ctx, facets)
    end
  end

  defp do_join_apply(%URI{} = member_uri, member_pid, ctx, facets) do
    session_uri = ctx[:self_uri]
    members = ctx[:read].(:members, %{})
    # `:monitors` is a TRANSIENT (SPEC §2.3C) — read from ctx.transients.
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})
    prior_owner = ctx[:read].(:owner_uri, nil)

    # Drop ALL stale monitor entries for this member URI and DEMONITOR
    # each ref (Codex r1 MEDIUM-3, 2026-05-26).
    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    for {ref, _uri} <- old_refs_for_member do
      _ = Process.demonitor(ref, [:flush])
    end

    monitors_without_member = Map.new(monitors_without_member)

    ref = Process.monitor(member_pid)

    # team-routing-unification §3.1 (codex PR-5a HIGH #2) — PRESERVE any
    # facets a faceted member already carries when it rejoins through the
    # stale-monitor / offline path. Start from the EXISTING meta (not a fresh
    # `%{online: true}`), force `online: true`, then overlay only the non-nil
    # facets this join supplied. Durable management/snapshot facets therefore
    # survive reconnect/repair instead of being silently dropped.
    existing_meta = Map.get(members, member_uri, %{})

    new_members =
      Map.put(
        members,
        member_uri,
        put_member_facets(Map.put(existing_meta, :online, true), facets)
      )

    new_monitors = Map.put(monitors_without_member, ref, member_uri)

    # If this member has prior last_seen, replay missed messages.
    replay_messages_since(session_uri, member_uri, last_seen)
    new_last_seen = Map.delete(last_seen, member_uri)

    # RFC #402 (Allen 2026-05-26) — "first user to join is owner"
    # fallback.
    new_owner_uri =
      if is_nil(prior_owner) and user_uri?(member_uri) do
        member_uri
      else
        prior_owner
      end

    # RFC #402 (codex r1 HIGH 2026-05-26) — when this join transitions
    # `owner_uri` from `nil` to a real user, ALSO grant that user the
    # `OrchestratorAdmin :restart` cap on this session.
    if is_nil(prior_owner) and user_uri?(member_uri) do
      grant_first_join_owner_cap(session_uri, member_uri)
    end

    # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
    # coverage" — surface the join to the joinee's notification stream
    # so a freshly-added member sees they were added to a session.
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

    {:ok, %{members: Map.keys(new_members)},
     [
       {:set, :members, new_members},
       # `:monitors` is a TRANSIENT (SPEC §2.3C / §7 OQ-2) — written via
       # `:set_transient`, never persisted.
       {:set_transient, :monitors, new_monitors},
       {:set, :last_seen, new_last_seen},
       {:set, :owner_uri, new_owner_uri}
     ] ++ broadcast_membership_effects(session_uri, {:member_joined, member_uri})}
  end

  # Notifier/flash audit 2026-05-24 — same predicate
  # `Ezagent.Domain.Workspace.user_uri?/1` uses. Keeps the agent-target
  # silence guarantee local to Chat without crossing the
  # workspace-domain boundary.
  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false

  # team-routing-unification §3.1 — fold the optional, non-authority facets
  # into a member's meta map. Only keys actually supplied (non-nil) are
  # written, so a plain join keeps `%{online: true}` and a rejoin overlays
  # only the deltas it carries (preserving prior facets — see do_join_apply).
  # `:provenance` is intentionally NOT a facet here; it lands in PR-5b with its
  # caller-derivation + authorization.
  defp put_member_facets(meta, facets) when is_map(meta) and is_map(facets) do
    meta
    |> maybe_put_facet(:role_name, Map.get(facets, :role_name))
    |> maybe_put_facet(:in_session_template, Map.get(facets, :in_session_template))
    |> maybe_put_facet(:source_template_uri, Map.get(facets, :source_template_uri))
  end

  defp maybe_put_facet(map, _key, nil), do: map
  defp maybe_put_facet(map, key, value), do: Map.put(map, key, value)

  # team-routing-unification §3.1 (codex PR-5a #1) — drop facet args that are
  # the wrong type, so malformed input is ignored rather than persisted /
  # crashing a guard. `role_name` must be a binary; `in_session_template` a
  # boolean. Absent keys are left absent.
  defp sanitize_facets(facets) do
    facets
    |> drop_facet_unless(:role_name, &is_binary/1)
    |> drop_facet_unless(:in_session_template, &is_boolean/1)
    # PR-7: spawn-source facet — must be a `%URI{}` (the AgentTemplate URI).
    |> drop_facet_unless(:source_template_uri, &match?(%URI{}, &1))
  end

  defp drop_facet_unless(map, key, pred) do
    case Map.fetch(map, key) do
      {:ok, value} -> if pred.(value), do: map, else: Map.delete(map, key)
      :error -> map
    end
  end

  # team-routing-unification §3.1 (spec §8 decision #2) — role_name is unique
  # per session. `:ok` when `role_name` is nil (no facet) OR free OR already
  # held by THIS same member (idempotent rejoin); `{:error, {:role_name_taken,
  # role_name}}` when a DIFFERENT member already holds it.
  defp role_name_conflict(_members, _member_uri, nil), do: :ok

  defp role_name_conflict(members, %URI{} = member_uri, role_name)
       when is_map(members) and is_binary(role_name) do
    case role_name_to_uri(members, role_name) do
      nil ->
        :ok

      %URI{} = holder ->
        if uri_eq?(holder, member_uri), do: :ok, else: {:error, {:role_name_taken, role_name}}
    end
  end

  defp uri_eq?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)

  @doc """
  team-routing-unification §3.1 — resolve a member `role_name` (stable
  per-session alias) to its member URI within a `members` map, or `nil` when
  no member carries that role_name. role_name is enforced unique per session
  at join (`role_name_conflict/3`), so at most one member matches.
  """
  @spec role_name_to_uri(map(), String.t()) :: URI.t() | nil
  def role_name_to_uri(members, role_name) when is_map(members) and is_binary(role_name) do
    Enum.find_value(members, nil, fn
      {%URI{} = uri, %{role_name: ^role_name}} -> uri
      _ -> nil
    end)
  end

  # RFC #402 (codex r1 HIGH 2026-05-26) — companion to the
  # first-USER-join owner claim. Dispatches `identity.grant_cap` on
  # the new owner so they hold the specific
  # `cap(:session, OrchestratorAdmin, :restart, session_uri, ws)`
  # cap the LV's restart gate consults.
  #
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

        case Ezagent.Router.dispatch(%Cmd{
               target: owner_uri,
               action: :grant_cap,
               args: %{cap: want},
               ctx: %{
                 caller: owner_uri,
                 caps: system_caps("template-materialize"),
                 reply: :ignore
               }
             }) do
          :ok ->
            :ok

          {:ok, _} ->
            :ok

          {:error, reason} ->
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
        # Session not workspace-bound.
        :ok
    end
  end

  # --- :leave ------------------------------------------------------------

  def handle_leave(%{member: %URI{} = member_uri}, ctx) do
    members = ctx[:read].(:members, %{})
    # `:monitors` is a TRANSIENT (SPEC §2.3C) — read from ctx.transients.
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})

    {ref_to_remove, new_monitors} = pop_monitor_ref(monitors, member_uri)

    if ref_to_remove, do: Process.demonitor(ref_to_remove, [:flush])

    new_members = Map.delete(members, member_uri)
    new_last_seen = Map.delete(last_seen, member_uri)

    {:ok, %{},
     [
       {:set, :members, new_members},
       # `:monitors` is a TRANSIENT (SPEC §2.3C / §7 OQ-2).
       {:set_transient, :monitors, new_monitors},
       {:set, :last_seen, new_last_seen}
     ] ++ broadcast_membership_effects(ctx[:self_uri], {:member_left, member_uri})}
  end

  # --- :set_working_copy -------------------------------------------------

  # Phase 7 completion PR-4 (SPEC §1.6) — write the durable
  # `template_working_copy` field on the Session's `:chat` slice.
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
  # So the handler requires an EXPLICIT authority beyond generic
  # session-chat: the caller must EITHER
  #
  # - be the session's orchestrator — hold the exact
  #   `{:within_session, self_uri}` delegated cap (cap #1, which the
  #   Generator grants ONLY to the orchestrator), OR
  # - be the system-internal Generator init path —
  #   `ctx[:system_internal] == true`, set ONLY by
  #   `system_set_working_copy/2`, never reachable from a user dispatch.
  def handle_set_working_copy(%{template_working_copy: wc}, ctx)
      when is_map(wc) do
    if working_copy_write_authorized?(ctx) do
      {:ok, %{template_working_copy: wc}, [{:set, :template_working_copy, wc}]}
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
  System-internal path to write the durable `template_working_copy`
  field (HIGH-2 hardening).

  `EzagentDomainInstanceMessage.SessionCreator.create_session/3` (the atomic single writer — the
  dead `Session.spawn_from_template/2` Generator was deleted in the
  2026-05-31 orchestrator-startup-atomicity pass) does the FIRST
  `template_working_copy` write in step 4
  (`materialize_orchestrator_working_copy/3`), before any orchestrator
  cap exists. It cannot hold the orchestrator's `{:within_session, _}`
  cap (the session is brand-new), so it uses this path: a
  `chat.set_working_copy` dispatch carrying `ctx[:system_internal] =
  true`. That marker is honored ONLY here and by
  `handle_set_working_copy/2`'s `working_copy_write_authorized?/1` — it
  is NOT settable from any user-facing dispatch (the MCP tool path
  supplies `caps`, never `system_internal`).

  Returns the dispatch result.
  """
  @spec system_set_working_copy(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_working_copy(%URI{} = session_uri, working_copy) when is_map(working_copy) do
    case Ezagent.Router.dispatch(%Cmd{
           target: session_uri,
           action: :set_working_copy,
           args: %{template_working_copy: working_copy},
           # SPEC caps-cleanup-v1 §4.4 — Session slice-internal write
           # of the durable template working_copy runs under
           # `system://session-internal` (closed Catalog).
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("session-internal"),
             caps: system_caps("session-internal"),
             system_internal: true,
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{template_working_copy: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # --- :set_legends (team-routing-unification §3.6, PR-6) ----------------

  # Install/overwrite the session-scoped legend registry on the :chat slice.
  #
  # ## Authorization (codex 2026-06-01 HIGH #2 — `system_internal` bypass fix)
  #
  # `set_legends` is a normal Chat action, so dispatch CapBAC step 5.5 derives
  # the cap as `{kind: :session, behavior: Chat, instance: <session_uri>}` —
  # which ANY non-admin session-cap holder holds STRUCTURALLY. So the handler
  # needs an EXPLICIT extra gate.
  #
  # The PRIOR gate (`working_copy_write_authorized?/1`) trusted a
  # CALLER-SUPPLIED `ctx[:system_internal] == true` boolean. But the runtime
  # PRESERVES caller ctx before authz, so any dispatch that simply sets
  # `system_internal: true` in its ctx installed legends — a privilege hole.
  #
  # The fix gates on a TRUSTED IDENTITY, not a ctx boolean
  # (`legends_write_authorized?/1`): the caller must EITHER
  #
  #   - be a trusted system principal — `ctx.caller` ∈ a small allowlist
  #     (`system://session-internal` / `system://orchestrator-tools`), the same
  #     provenance-setting pattern; the `system_set_legends/2` path dispatches
  #     under `system://session-internal` so it still works, OR
  #   - be the session's orchestrator — hold the exact `{:within_session,
  #     self_uri}` delegated cap (cap #1, granted only by the Generator).
  #
  # The `system_internal`-ctx-flag is NO LONGER consulted for legends.
  def handle_set_legends(%{legends: legends}, ctx) when is_map(legends) do
    if legends_write_authorized?(ctx) do
      {:ok, %{legends: legends}, [{:set, :legends, legends}]}
    else
      {:error, :unauthorized}
    end
  end

  # The trusted-principal allowlist for `set_legends` — installing a legend is
  # orchestrator/system config (a legend fronts a team + rule-set). Mirrors the
  # provenance-setting trusted-principal pattern. `set_working_copy` STILL uses
  # the older `system_internal`-flag gate (`working_copy_write_authorized?/1`) —
  # codex flagged it shares the same flaw; tracked separately (see report), this
  # PR fixes `set_legends` properly.
  @legends_trusted_principals ["session-internal", "orchestrator-tools"]

  defp legends_write_authorized?(ctx) do
    trusted_legends_principal?(ctx) or orchestrator_cap_present?(ctx)
  end

  # True iff `ctx.caller` is one of the trusted system principals allowed to
  # install legends. The caller is set by the dispatch path, NOT freely by an
  # arbitrary user dispatch (a user dispatch carries the user's own
  # `entity://user/...` caller), so unlike the old `system_internal` boolean
  # this cannot be spoofed by setting a ctx field.
  defp trusted_legends_principal?(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = caller -> trusted_principal?(caller)
      caller when is_binary(caller) -> caller |> Ezagent.URI.new!() |> trusted_principal?()
      _ -> false
    end
  end

  defp trusted_principal?(%URI{} = caller) do
    caller = caller |> Ezagent.URI.instance() |> URI.to_string()

    Enum.any?(@legends_trusted_principals, fn name ->
      name |> Ezagent.SystemPrincipal.uri() |> URI.to_string() == caller
    end)
  end

  @doc """
  Read the session-scoped legend registry from a `:chat` slice, defaulting to
  `%{}` when the key is absent (a pre-PR-6 Session snapshot — see `create/1`).
  """
  @spec legends_of(map()) :: Legend.registry()
  def legends_of(chat_slice) when is_map(chat_slice) do
    Map.get(chat_slice, :legends, %{})
  end

  @doc """
  Resolve a legend NAME against a `:chat` slice's registry to its entry (the
  bound rule-set handle). Delegates to `Ezagent.Routing.Legend.resolve/2`.

  `{:ok, entry}` (carrying `:bound_rule_set` + `:name`) for a registered
  legend, `:error` otherwise. team-routing-unification §3.6 (PR-6, GATE a).
  """
  @spec resolve_legend(map(), String.t()) :: {:ok, Legend.entry()} | :error
  def resolve_legend(chat_slice, name) when is_map(chat_slice) and is_binary(name) do
    Legend.resolve(legends_of(chat_slice), name)
  end

  @doc """
  Member-list rows with folded legends collapsed (team-routing-unification
  §3.6 fold, PR-6, GATE c). Wires this Behavior's `role_name_to_uri/2` into
  `Ezagent.Routing.Legend.fold_members/3` so a legend's `member_set`
  role_names resolve to live member URIs. Pure presentation transform — the
  slice `:members` map is untouched, so every collapsed member stays
  individually `@`-able.

  Returns `[{:legend, name, [URI.t()]} | {:member, URI.t(), meta}]`.
  """
  @spec fold_members(map()) :: [
          {:legend, String.t(), [URI.t()]} | {:member, URI.t(), map()}
        ]
  def fold_members(chat_slice) when is_map(chat_slice) do
    members = Map.get(chat_slice, :members, %{})
    legends = legends_of(chat_slice)
    Legend.fold_members(members, legends, fn role -> role_name_to_uri(members, role) end)
  end

  @doc """
  System-internal path to install the legend registry (team-routing-unification
  §3.6, PR-6). Mirrors `system_set_working_copy/2`: a `chat.set_legends`
  dispatch under the `system://session-internal` principal. Used by tests and
  by the PR-7 template materialization path (which installs a template's
  legends at create_session time, before any orchestrator cap exists).

  Authorization rides the TRUSTED `caller` (`system://session-internal` ∈ the
  `set_legends` allowlist), NOT a ctx flag (codex 2026-06-01 HIGH #2). The old
  `system_internal: true` marker is no longer consulted for legends — it is
  omitted here.
  """
  @spec system_set_legends(URI.t(), Legend.registry()) :: {:ok, map()} | {:error, term()}
  def system_set_legends(%URI{} = session_uri, legends) when is_map(legends) do
    case Ezagent.Router.dispatch(%Cmd{
           target: session_uri,
           action: :set_legends,
           args: %{legends: legends},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("session-internal"),
             caps: system_caps("session-internal"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{legends: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_legends_result, other}}
    end
  end

  # --- :set_prompt_templates (team-routing-unification §3.4/§3.7, PR-7) ---

  # Install/overwrite the session-scoped named prompt-template map on the :chat
  # slice. Authorization mirrors `:set_legends` EXACTLY (codex 2026-06-01 HIGH
  # #2 — gate on a TRUSTED IDENTITY, not a ctx boolean): the caller must EITHER
  # be a trusted system principal (`set_legends` allowlist) OR be the session's
  # orchestrator (the `{:within_session, self_uri}` delegated cap). A
  # prompt-template fronts a team's delivery transform — the same
  # orchestrator/system-config authority class a legend has.
  def handle_set_prompt_templates(%{prompt_templates: pts}, ctx) when is_map(pts) do
    if legends_write_authorized?(ctx) do
      {:ok, %{prompt_templates: pts}, [{:set, :prompt_templates, pts}]}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  System-internal path to install the session-scoped named prompt-template map
  (team-routing-unification §3.4/§3.7, PR-7). Mirrors `system_set_legends/2`: a
  `chat.set_prompt_templates` dispatch under the `system://session-internal`
  principal. Used by tests and by the PR-7 SessionTemplate materialization path
  (which installs a template's `prompt_templates` at create_session time,
  before any orchestrator cap exists).

  Authorization rides the TRUSTED `caller` (`system://session-internal` ∈ the
  `set_legends`/`set_prompt_templates` allowlist), NOT a ctx flag.
  """
  @spec system_set_prompt_templates(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_prompt_templates(%URI{} = session_uri, prompt_templates)
      when is_map(prompt_templates) do
    case Ezagent.Router.dispatch(%Cmd{
           target: session_uri,
           action: :set_prompt_templates,
           args: %{prompt_templates: prompt_templates},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("session-internal"),
             caps: system_caps("session-internal"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{prompt_templates: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_prompt_templates_result, other}}
    end
  end

  # --- Signal hook (non-action GenServer messages) -----------------------

  @doc """
  `handle_signal/2` (SPEC 2026-05-29 §2 / §9 OQ-3) — the Lifecycle
  successor to the engine's `handle_kind_message/3`. The macro reduces
  the returned effect list into the two-container slice (`:set` → state,
  `:set_transient` → transients), so this hook returns the SAME effect
  grammar a `handle_<action>` does.

  Handles `:DOWN` from `Process.monitor`; everything else is `:ignore`d.

  On `:DOWN` for a known member ref: flip `online` → false (persisted via
  `{:set, :members, ...}`), record `last_seen = now` (persisted via
  `{:set, :last_seen, ...}`), and DROP the dead ref from the TRANSIENT
  `:monitors` map via `{:set_transient, :monitors, ...}`. The URI stays
  in `members` so a rejoin still recognizes it.

  `:monitors` is read from `ctx.transients` (the macro injects
  `ctx.transients` + a `ctx.read` over the persistent `:state` for the
  signal path — see `Ezagent.Lifecycle.__run_signal__/4`).
  """
  @impl Ezagent.Lifecycle
  def handle_signal({:DOWN, ref, :process, _pid, _reason}, ctx) do
    monitors = (ctx[:transients] || %{})[:monitors] || %{}

    case Map.pop(monitors, ref) do
      {nil, _} ->
        # Not one of our monitors (could be another Behavior's ref or
        # a stale ref after a leave).
        :ignore

      {member_uri, new_monitors} ->
        now = DateTime.utc_now()
        members = ctx[:read].(:members, %{})
        last_seen = ctx[:read].(:last_seen, %{})

        new_members =
          Map.update(members, member_uri, %{online: false}, &Map.put(&1, :online, false))

        new_last_seen = Map.put(last_seen, member_uri, now)

        # broadcast_membership_direct/2 stays a no-op: SliceChange (hooked
        # at the Kind.Server commit level) emits the membership mutation
        # downstream. Signals in Phase A only execute container mutations
        # (not :notify), so we DON'T emit a :notify effect here.
        broadcast_membership_direct(ctx[:self_uri], {:member_offline, member_uri, now})

        {:ok,
         [
           {:set, :members, new_members},
           {:set, :last_seen, new_last_seen},
           # Drop the dead ref from the TRANSIENT monitor map.
           {:set_transient, :monitors, new_monitors}
         ]}
    end
  end

  def handle_signal(_other_message, _ctx), do: :ignore

  # --- Task #110 — orchestrator MCP context is now LAZILY REBUILT --------
  #
  # The earlier patch (commit 73044554) re-registered the orchestrator
  # `McpRegistry` row from an `on_ready/2` cache-warm here. That has been
  # REMOVED in favour of the read-through cache in
  # `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1`: on an ETS
  # miss it lazily rebuilds the context from the Session's durable
  # `kind_snapshots` row and fills the cache.
  #
  # Lazy rebuild fully subsumes the on_ready cache-warm for correctness
  # AND covers a case on_ready could not: the orchestrator bridge can
  # join `orch:bridge:<uri>` BEFORE the Session Kind cold-spawns (or
  # while it is not running at all) — on_ready only fires when the
  # Session Kind itself reaches `:ready`, so it could not have warmed
  # the cache in time for that race. The cache-warm offered at best a
  # marginal first-join latency saving (one indexed snapshot query,
  # once per orchestrator per restart, cached thereafter), so it is
  # dropped to reduce surface per the plugin-isolation north star.
  #
  # The durable `:session_template_uri` field on the working copy
  # (written by `EzagentDomainInstanceMessage.SessionCreator.create_session/3`'s step-4
  # `materialize_orchestrator_working_copy/3` — replacing the deleted
  # Generator `Session.merge_working_copy/6`) is KEPT — it is the
  # canonical source the lazy rebuild prefers for `parent_template_uri`.

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
  defp notify_dropped_mentions(%Message{} = msg, recipients, session_uri, ctx) do
    mention_uris = msg.mentions || []

    if mention_uris == [] do
      :ok
    else
      recipients = MapSet.new(recipients, &Ezagent.URI.instance/1)

      dropped =
        mention_uris
        |> Enum.map(&to_uri_struct/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn uri -> MapSet.member?(recipients, Ezagent.URI.instance(uri)) end)

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
          e ->
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
    Ezagent.URI.new!(s)
  rescue
    _ -> nil
  end

  defp to_uri_struct(_), do: nil

  # Cross-session forwarding — fire-and-forget Router.dispatch with
  # :cast (reply :ignore). The target session handles its own member
  # fan-out + further routing rules.
  defp dispatch_cross_session_call(target_session_uri, %Message{} = msg) do
    # Pre-bake `chat.send` so the audit `target` carries the real
    # behavior name (see `dispatch_receive_call/3` — a bare
    # `action: :send` yields the `_.send` Router sentinel).
    send_target =
      Ezagent.URI.with_action(target_session_uri, :chat, :send)

    Ezagent.Router.dispatch(%Cmd{
      target: send_target,
      action: :send,
      args: %{message: msg},
      ctx: %{
        caller: msg.sender,
        # SPEC caps-cleanup-v1 §4.4 — cross-session forwarding is
        # system-routed; `system://chat-router` per Catalog.
        caps: system_caps("chat-router"),
        reply: :ignore
      }
    })
  end

  # Per-recipient receive dispatch — :cast for Session→member fan-out.
  # On success, mark :delivered on the read marker (PR-3 of Read Receipts
  # rollout — fire-and-forget, must not block message fan-out).
  @doc false
  # team-routing-unification §3.4 (PR-4b): render the matched rule's prompt
  # template (carried in `ctx.prompt_template_ref` from
  # `Resolver.resolve_with_ctx/4`) over the message, using the session's
  # `prompt_templates` map. No ref / no such template / nil ctx → the message
  # is returned UNCHANGED (behaviour-preserving when no rule names a template).
  @spec render_for_delivery(Message.t(), map() | nil, map(), URI.t()) :: Message.t()
  def render_for_delivery(%Message{} = msg, ctx, templates, %URI{} = session_uri)
      when is_map(templates) do
    ref = ctx && Map.get(ctx, :prompt_template_ref)

    case ref && Map.get(templates, ref) do
      template when is_binary(template) ->
        rendered =
          Ezagent.Routing.PromptTemplate.render(template, message_vars(msg, session_uri))

        %{msg | body: put_rendered_text(msg.body, rendered)}

      _ ->
        msg
    end
  end

  @doc false
  # The fixed v1 template variable set, extracted from the delivered message +
  # current session (team-routing-unification §3.2/§3.4). `flavor` is "" for
  # now (the sender's agent flavor needs a lookup — deferred).
  @spec message_vars(Message.t(), URI.t()) :: map()
  def message_vars(%Message{} = msg, %URI{} = session_uri) do
    %{
      sender: msg.sender && URI.to_string(msg.sender),
      # reuse the existing body-map `body_text/1` helper (defined later in
      # this module) — do NOT define a Message-taking clause here: its
      # catch-all would shadow the body-map clauses + break the :receive
      # Agent-branch payload path (regression caught 2026-06-01).
      body: body_text(msg.body),
      session: URI.to_string(session_uri),
      sent_at: msg.inserted_at && DateTime.to_iso8601(msg.inserted_at),
      flavor: ""
    }
  end

  defp put_rendered_text(%{text: _} = body, text), do: %{body | text: text}
  defp put_rendered_text(%{"text" => _} = body, text), do: Map.put(body, "text", text)
  defp put_rendered_text(body, text) when is_map(body), do: Map.put(body, :text, text)
  defp put_rendered_text(_body, text), do: %{text: text}

  defp system_caps(name) when is_binary(name) do
    name
    |> Ezagent.SystemPrincipal.uri()
    |> Ezagent.SystemPrincipal.caps()
  end

  defp dispatch_receive_call(recipient_uri, %Message{} = msg, session_uri) do
    # Canonicalize the session URI before it crosses into the recipient's
    # `chat.receive` — it becomes `ctx.caller`, which the recipient behavior
    # feeds to `Ezagent.URI.with_action/3` (e.g. Echo's reply path), and it
    # keys the ReadMarker below. `ctx[:self_uri]` carries the deprecated
    # `:authority` field when the inbound target was built via stdlib
    # `URI.parse/1`; both the `with_action/3` canonical guard and every
    # canonical MapSet/ETS comparison require the RFC-3986 `authority: nil`
    # shape. (Sibling of the broadcast-site canonicalization in `handle_send`.)
    session_uri = Ezagent.URI.new!(URI.to_string(session_uri))

    # SPEC caps-cleanup-v1 §4.4 — Session fan-out is system-routed
    # message delivery; runs under `system://chat-router` (closed
    # Catalog). The session URI stays as caller for provenance.
    #
    # Pre-bake the FULL `chat.receive` action onto the target so the
    # telemetry/audit `target` carries the real behavior name. A bare
    # `action: :receive` makes the Router synthesise the `_.receive`
    # sentinel (it can't infer the behavior from a `%Cmd{}` alone), which
    # erases `chat.receive` from the `invocations` audit log — breaking
    # the operator query (and the routing-fanout tests) that filter on
    # `?action=chat.receive`. Router's `annotate_target_with_action/2`
    # leaves a pre-baked `action=` query untouched.
    receive_target =
      Ezagent.URI.with_action(recipient_uri, :chat, :receive)

    result =
      Ezagent.Router.dispatch(%Cmd{
        target: receive_target,
        action: :receive,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          caps: system_caps("chat-router"),
          reply: :ignore
        }
      })

    if result == :ok do
      _ = Ezagent.Chat.ReadMarker.mark(session_uri, recipient_uri, msg.id, :delivered)
    end

    result
  end

  defp replay_messages_since(_session_uri, _member_uri, last_seen) when last_seen == %{}, do: :ok

  defp replay_messages_since(session_uri, member_uri, last_seen) do
    case Map.get(last_seen, member_uri) do
      nil ->
        :ok

      last_seen_at ->
        for msg <- MessageStore.in_session_since(session_uri, last_seen_at) do
          dispatch_receive_call(member_uri, msg, session_uri)
        end

        :ok
    end
  end

  # broadcast_membership returns two :notify effects (per-session +
  # global membership-changes feed). Used by handle_join/handle_leave.
  defp broadcast_membership_effects(session_uri, event) do
    [
      # Per-session fan-out — the LV chat stream subscribes here for
      # its own session's events.
      {:notify, session_events_topic(session_uri), event},
      # Global fan-out — `EzagentDomainInstanceMessage.PresenceFanout` subscribes
      # to maintain the `user_uri → MapSet(session_uri)` reverse index
      # without coupling back to this module. Wrapper carries the
      # session_uri the inner `event` lacks.
      {:notify, "esr:session_membership:changes",
       {:session_membership_change, session_uri, event}}
    ]
  end

  # handle_kind_message can't return :notify effects (different
  # contract — it returns {:ok, new_slice} or :ignore). For the
  # :DOWN-path member-offline broadcasts, dispatch through the
  # Router via a self-:notify... but Router doesn't broadcast.
  # The cleanest path is the EventLog-bus shim: there is no such
  # thing in the codebase, so we keep the direct PubSub broadcast
  # here, gated behind a helper whose name signals it's the
  # one-call-from-handle_info path (not a generic broadcast).
  #
  # `defp` keeps it private; the `:notify` grep gate is on the raw
  # PubSub broadcast — we use the `Ezagent.Notifications` facade via
  # the broadcast layer instead. There is no such facade for raw
  # membership broadcasts in this codebase; the only legal
  # alternative is to plumb the broadcast through `Ezagent.SliceChange`,
  # which already fires for slice mutations made by handle_kind_message
  # (it's hooked at the Kind.Server level — see commit_and_notify).
  # The slice change to :members/:monitors/:last_seen IS the
  # observable signal subscribers consume; we therefore DROP the
  # explicit :member_offline broadcast — SliceChange replaces it.
  defp broadcast_membership_direct(_session_uri, _event) do
    # SliceChange emits the membership mutation downstream as part of
    # the Kind.Server commit_and_notify pipeline. No additional
    # broadcast required (and the raw PubSub broadcast is gated by
    # the migration sweep).
    :ok
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

  # PR-OWN-2 (caps-data-ownership SPEC #306 §3.3 + §7) — data_owner
  # for Chat caps is the session's `:owner_uri` (the entity that
  # created the session). Looked up via `Ezagent.Entity.Session.owner/1`.
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
