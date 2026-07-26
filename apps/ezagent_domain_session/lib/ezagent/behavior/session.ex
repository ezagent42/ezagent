defmodule Ezagent.ActionSet.Session do
  @moduledoc """
  Chat Behavior — Decision P2-D2 K-path: 4 actions, registered per-Kind
  subset to realize Decision #61 "Ezagent is router not req/resp app".

  ## Action / Kind matrix

      | action    | registered on Kind(s)                  | mode  |
      |-----------|----------------------------------------|-------|
      | :send     | Ezagent.Entity.Session                     | cast  |
      | :join     | Ezagent.Entity.Session                     | call  |
      | :leave    | Ezagent.Entity.Session                     | cast  |

  Session-side actions (`:send / :join / :leave`) mutate the Session's
  `:session` slice (`members` map / `monitors` ref→URI / `last_seen` URI→DateTime).
  When `:send` is invoked, recipients are derived from `msg.mentions` (or
  all `members` if mentions is empty), excluding the sender, and each
  receives a `<entity>.receive` dispatch on its own Kind. The Session also
  broadcasts to `esr:session:<self_uri>:events` so the LV chat stream
  picks up the message.

  ## Receive (split out — PR-2, im/session/agent decomposition)

  `:receive` is NO LONGER handled here. SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §OQ-4 / §3.3 split the old single `:receive` (which branched internally
  on `ctx.kind_module`) into TWO first-class Behaviors, each registered
  for `:receive` on its own Kind:

  - `Ezagent.ActionSet.User.Receive` (`user.receive`, on `Entity.User`) —
    the passive inbox: records `:last_received` + the cursor-ring
    `:recent_messages` slice; the SliceChange hook emits the notification.
  - `Ezagent.ActionSet.Agent.Receive` (`agent.receive`, on `Entity.Agent`)
    — active live-process delivery: builds a flavor-neutral
    `Ezagent.AgentBridge.Payload` and delivers it via
    `Ezagent.AgentBridge` (the shared
    `Ezagent.ActionSet.Session.Delivery.deliver_agent_receive/2` helper).

  The internal `case ctx.kind_module` is RETIRED — dispatch routes
  `:receive` to the right Behavior by Kind via the BehaviorRegistry.

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

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle` (the
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

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.Session` — a domain
  module (`apps/ezagent_domain_session`) naming its own domain concept
  (`Chat`), with five actions whose intent the name closely tracks. NO
  violation; kept as-is (a rename would touch the `:chat` snapshot slice
  key + every call site for no clarity gain).
  """

  # The `:session` slice key is AUTO-DERIVED from `Ezagent.ActionSet.Session`
  # (last module segment "Session" → `:session`), so NO `state_slice:`
  # override is needed. The chat→session rename (Allen 2026-06-12, NO
  # back-compat) renamed the slice key from `:chat` to `:session`
  # system-wide. Existing `:chat`-keyed `kind_snapshots` rows are migrated
  # to `:session` by `mix ezagent.session.migrate_slice` BEFORE the new
  # code serves them (ordered cutover — no dual-read shim).
  use Ezagent.Lifecycle
  reads_siblings([:sandbox])

  require Logger

  alias Ezagent.{KindRegistry, Message, MessageStore}

  alias Ezagent.ActionSet.Session.{
    ConfigActions,
    Delivery,
    Legends,
    Members,
    Membership,
    RoleResolver,
    SelfAdd,
    Teardown
  }

  alias Ezagent.Routing.{Legend, Trace}

  # PR-N3 r4 ring depth + `recent_messages_ring_depth/0` MOVED to
  # `Ezagent.ActionSet.User.Receive` (PR-2 split) — the `:recent_messages`
  # ring is owned by `user.receive` now, so the SPEC-pinned constant
  # lives with it. Session no longer touches the receive slice.

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Session is registered on:
  #   - Session Kind for :send, :join, :leave, :set_working_copy, ...
  # `:receive` is NO LONGER a Session action (PR-2 split → User.Receive /
  # Agent.Receive, registered on their own Kinds).

  action(:send,
    args: %{message: :map},
    returns: %{stored: :boolean},
    caps: [:send],
    modes: [:cast],
    description: "Post a message into the session and fan it out to members"
  )

  action(:join,
    # Allow both — admin User joins via :cast at boot (non-blocking);
    # admin or programmatic callers may :call to observe admission status.
    args: %{member: :uri},
    returns: %{status: :atom, member: :uri},
    caps: [:join],
    modes: [:call, :cast],
    description: "Add a member to the session and replay any missed messages"
  )

  action(:add_self,
    args: %{member: :uri, facets: :map},
    returns: %{status: :atom},
    modes: [:cast],
    description:
      "Mount the authenticated entity into the members projection after an in-handler " <>
        "durable tier-1 member-cap check"
  )

  action(:leave,
    args: %{member: :uri},
    returns: %{},
    caps: [:leave],
    modes: [:cast],
    description: "Remove a member from the session"
  )

  action(:transfer_owner,
    args: %{owner: :uri},
    returns: %{owner: :uri},
    caps: [:transfer_owner],
    modes: [:call],
    description: "Transfer session ownership during durable user offboarding"
  )

  # F7 PR-A — ISOMORPHIC participant-removal (body+doc in Membership, SPEC §3).
  action(:remove_participant,
    args: %{participant: :uri},
    returns: %{
      status: :atom,
      torn_down: :atom,
      deleted_rules: :integer,
      repointed_rules: :integer
    },
    caps: [:remove_participant],
    modes: [:call],
    description: "Remove a participant (user / invited-agent) — owner-gated (F7 PR-A)"
  )

  action(:assign_role,
    args: %{member: :uri, role_name: :string},
    returns: %{member: :uri, role_name: :string},
    caps: [:assign_role],
    modes: [:call],
    description: "Assign an open human socialware role to a joined user member"
  )

  # LV→world parity PR-2b — upload authorization chokepoint. The world composer
  # is a React island under `phx-update="ignore"`, so it cannot use the LiveView
  # uploader (`live_file_input`/`consume_uploaded_entries`); uploads arrive over
  # a decoupled HTTP POST. To keep upload authorization on the SAME path as
  # message send (so they can never drift), the upload controller dispatches this
  # action: the runtime authorizes it at the chokepoint (required `:attach` cap +
  # provenance + workspace-isolation, exactly like `:send`), and `:attach` is
  # co-granted with `:send` in the participation tier (Membership), so a member
  # who may send may upload — and nobody else. The handler is a thin
  # authorize-GATE: merely reaching it means the caller was authorized, so it
  # does NO filesystem I/O (the controller stores the bytes after the `:ok`,
  # keeping I/O out of the session actor) and mutates no slice.
  action(:attach,
    args: %{filename: :string},
    returns: %{ok: :boolean},
    caps: [:attach],
    modes: [:call],
    description:
      "Authorize a file upload into the session (LV→world parity PR-2b). A thin " <>
        "chokepoint gate: success means the caller holds the :attach cap; the " <>
        "controller stores the bytes after this returns. No I/O, no slice change."
  )

  action(:merge_member,
    args: %{from: :uri, to: :uri},
    returns: %{status: :atom, member: :uri},
    caps: [:merge_member],
    modes: [:call],
    description: "Atomically relabel one session member URI to another"
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

  # Membership-cap unification Part C (spec §C.4/§C.5, R4) — the admission
  # approve/deny/withdraw actions. Each is CAP-EXEMPT at the CapBAC layer
  # (`cap_exempt_actions/0` below) and authorized IN-HANDLER: the member's
  # owner/manager holds NO session cap on B's session, so a session-scoped
  # CapBAC gate could never let A approve. Authority is the `manages?/2`
  # predicate (approve/deny) or `requested_by` (withdraw) — the `:receive` /
  # `:cascade_notify_managers` cap-exempt precedent (in-handler live authz).
  action(:approve_admission,
    args: %{member: :uri},
    returns: %{status: :atom, member: :uri, approved: :uri},
    caps: [:approve_admission],
    modes: [:call],
    description:
      "Approve a pending cross-owner admission (spec §C.4) — manage-authority " <>
        "gated in-handler; grants the member-cap + mounts, drops the pending entry"
  )

  action(:deny_admission,
    args: %{member: :uri},
    returns: %{denied: :uri},
    caps: [:deny_admission],
    modes: [:call],
    description:
      "Deny a pending admission (spec §C.5) — a manager of the member drops the " <>
        "pending entry (pure state-drop; no cap was ever granted)"
  )

  action(:withdraw_admission,
    args: %{member: :uri},
    returns: %{withdrawn: :uri},
    caps: [:withdraw_admission],
    modes: [:call],
    description:
      "Withdraw a pending admission request (spec §C.5) — the requester (B) " <>
        "drops its own pending entry (authz: requested_by == caller)"
  )

  action(:composition_consent,
    args: %{
      binding_id: :string,
      side: :atom,
      command: :atom,
      idempotency_key: :string
    },
    returns: %{request_id: :string, target_approval: :atom, source_approval: :atom},
    caps: [:composition_consent],
    modes: [:call],
    description:
      "Approve, deny, or revoke one exact composition binding as its live target/source owner"
  )

  @doc """
  Membership cap-exempt actions. Admission approve/deny/withdraw and composition
  consent have their existing in-handler authority predicates. `:add_self`
  ignores presented caps and independently loads the authenticated holder's
  durable tier-1 cap in `Session.SelfAdd`. Keeps
  `keys(required_caps) ∪ cap_exempt_actions == actions`.
  """
  def cap_exempt_actions,
    do: [
      :approve_admission,
      :deny_admission,
      :withdraw_admission,
      :composition_consent,
      :add_self
    ]

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
       # Membership-cap unification Part C admission gate (spec §C.1/§C.2, R4).
       # A CROSS-OWNER add (a real, non-system caller who does NOT manage the
       # member) records a PENDING admission request here — DISTINCT from
       # `:members`, holds NO member-cap, is NOT mounted — until the member's
       # owner/manager approves. Shape (spec §C.2):
       #   %{member_uri => %{requested_by, requested_at, request_ref}}
       # Persistent (survives restart, never silently lost). Legacy snapshots
       # lack this key; readers MUST default via `ctx[:read].(:pending_members, %{})`.
       pending_members: %{},
       # M-4 — per-member durable replay floor captured at membership-grant
       # intent. The later self-add projects this cursor into member metadata
       # in the same commit as the roster mount.
       join_cursors: %{},
       # M-5 — non-authority routing facets captured with the grant intent and
       # consumed by the holder's later add_self projection.
       join_facets: %{},
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
  def activate(state, ctx) do
    # Membership-cap unification A1.3 (spec §4.4) — SEED/HEAL the `:members`
    # projection from the authoritative member-cap holder set BEFORE rebuilding
    # the monitors, so a cap-only drift (member granted the cap but missing from
    # the projection) is healed and immediately monitored. UNION semantics keep
    # A1 additive/behavior-preserving (never evicts an existing member — eviction
    # is an A2 concern). The reconcile never raises (§13); a scan failure returns
    # the persisted projection unchanged, so `activate/2` cannot crash on it.
    persisted_members = Map.get(state, :members, %{})

    reconciled_members =
      case ctx do
        %{self_uri: %URI{} = session_uri} ->
          # Runtime-mount survival (socialware): a mount's key lives in the
          # grantee's self-store cap slice, which is rebuilt on restart WITHOUT
          # re-minting — so on every (re)start we re-issue the keys for every
          # durable `MountRow` of this session. Best-effort + never raises (it
          # rescues internally and returns `{:ok, _}`), so it cannot crash the
          # Kind boot; a dead/ownerless target degrades that one mount only.
          Ezagent.Socialware.Mount.reconcile_session_mounts(session_uri)

          Ezagent.ActionSet.Session.Reconcile.reconcile_after_load(
            session_uri,
            persisted_members
          )

        _ ->
          persisted_members
      end

    monitors =
      reconciled_members
      |> Map.keys()
      |> Enum.flat_map(fn %URI{} = uri ->
        case KindRegistry.lookup(uri) do
          {:ok, pid} when is_pid(pid) -> [{Process.monitor(pid), uri}]
          _ -> []
        end
      end)
      |> Map.new()

    {:ok, %{monitors: monitors, members: reconciled_members}}
  end

  @doc """
  The empty/default `template_working_copy` shape (Phase 7 completion
  SPEC §1.3 / §1.6). Thin delegator to
  `Ezagent.ActionSet.Session.ConfigActions.default_template_working_copy/0`.
  """
  @spec default_template_working_copy() :: map()
  defdelegate default_template_working_copy, to: ConfigActions

  @doc """
  Read the durable `template_working_copy` field from a `:chat` slice,
  defaulting to `default_template_working_copy/0` when the key is
  absent. Thin delegator to
  `Ezagent.ActionSet.Session.ConfigActions.template_working_copy/1`.
  """
  @spec template_working_copy(map()) :: map()
  defdelegate template_working_copy(chat_slice), to: ConfigActions

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

        if msg.hops <= 0 do
          record_routing_trace(msg, workspace_uri, "no_match", [], :hop_exhausted)
          send_success(msg, session_uri, ctx, %{stored: true, dropped: :hop_exhausted}, [])
        else
          # team-routing-unification §3.4/§3.5 (PR-4b): resolve WITH matched-rule
          # ctx so the per-recipient delivery can render that rule's prompt
          # template. The bare URI list (for notify_dropped_mentions) is mapped
          # off; ctx is threaded into the dispatch loop below.
          provision_key = {__MODULE__, :route_time_provision_effects}
          Process.put(provision_key, [])

          {recipients_with_ctx, provision_effects} =
            try do
              recipients =
                Ezagent.Routing.Resolver.resolve_with_ctx(
                  msg,
                  session_uri,
                  in_session_members,
                  workspace_uri: workspace_uri,
                  members_snapshot: members_map,
                  role_resolver: fn role_name, _route_ctx ->
                    RoleResolver.resolve(role_name, workspace_uri, ctx, provision_key, __MODULE__)
                  end,
                  # RF-6: inject the passive-actor predicate (parallel to
                  # `role_resolver`) so the resolver's universal final-output gate
                  # drops any PASSIVE data actor a rule resolved to (any rule type).
                  passive?: &Members.passive_actor?/1
                )

              {recipients, Process.get(provision_key, [])}
            after
              Process.delete(provision_key)
            end

          recipients = Enum.map(recipients_with_ctx, fn {uri, _ctx} -> uri end)
          prompt_templates = ctx[:read].(:prompt_templates, %{})
          record_routing_traces(msg, workspace_uri, recipients_with_ctx)

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
          Delivery.notify_dropped_mentions(msg, recipients, session_uri, ctx, __MODULE__)

          # send-echo-decouple (2026-07-08) — fan each recipient's delivery OFF
          # this hot path into `Ezagent.Session.DeliveryQueue` via
          # `deliver_async/5` (per-recipient FIFO, ONE in-flight job per key,
          # each job an UNLINKED supervised Task), so `handle_send` returns
          # immediately after persist + route. Three properties fall out:
          #   Prong A — `Kind.Runtime` applies `send_success/5`'s
          #     `{:notify, :chat_message}` feed broadcast WITHOUT waiting on any
          #     member delivery, so the sender's echo is fast regardless of a
          #     dead member. Feed ORDER is preserved: the Session Kind processes
          #     sends serially and returns each notify effect before the next.
          #   Per-recipient ORDER (codex HIGH-1) — this loop enqueues in send
          #     order and the queue runs one job per recipient at a time, so a
          #     recipient observes messages in send order (`last_received` /
          #     `recent_messages` / ReadMarker's monotonic cursor stay
          #     msg1-before-msg2 even when msg1's delivery is slow).
          #   Prong B — one dead/slow member (e.g. a cold np-flavor agent whose
          #     `ensure_live` spawn blocks ~5s) backs up its OWN key only and
          #     can never delay another member, the pipeline, or the next send.
          # The per-recipient §3.4 Path-A prompt-template render + the Read
          # Receipts PR-3 delivered-mark (dispatch result gates the mark, so it
          # lives WITH the dispatch in `dispatch_receive_call/3`) both run
          # inside the delivery job. `{:dispatch_after_commit, cmd}` was NOT
          # used: its deferred cmds run sequentially on the Session Kind's own
          # `handle_info` turn (`DeferredDispatch.run/1` `Enum.each`), so a
          # slow member would still block siblings + the next send (Prong B
          # fails) — and it bypasses the `ensure_live` cold-member revival that
          # fan-out delivery needs.
          for {recipient, rule_ctx} <- recipients_with_ctx do
            forwarded_msg = decrement_hops(msg)

            Delivery.deliver_async(
              recipient,
              rule_ctx,
              forwarded_msg,
              prompt_templates,
              session_uri
            )
          end

          send_success(msg, session_uri, ctx, %{stored: true}, provision_effects)
        end

      {:error, reason} ->
        {:error, {:message_store_write_failed, reason}}
    end
  end

  defp send_success(%Message{} = msg, session_uri, ctx, result, provision_effects) do
    # PR-EM-6-PRE (Allen 2026-05-25) — mutate the slice so the
    # SliceChange hook in `Kind.Runtime` fires for every send.
    prev_cursor = ctx[:read].(:send_cursor, 0)
    canonical_session_uri = Ezagent.URI.new!(URI.to_string(session_uri))

    {:ok, result,
     provision_effects ++
       [
         {:set, :last_message_id, msg.id},
         {:set, :last_message, msg},
         {:set, :send_cursor, prev_cursor + 1},
         {:notify, session_events_topic(session_uri), {:chat_message, canonical_session_uri, msg}}
       ]}
  end

  defp decrement_hops(%Message{hops: hops} = msg) when is_integer(hops) and hops > 0 do
    %{msg | hops: hops - 1}
  end

  defp decrement_hops(%Message{} = msg), do: %{msg | hops: 0}

  defp record_routing_traces(%Message{} = msg, workspace_uri, []) do
    record_routing_trace(msg, workspace_uri, "no_match", [], :no_match)
  end

  defp record_routing_traces(%Message{} = msg, workspace_uri, recipients_with_ctx) do
    recipients_with_ctx
    |> Enum.group_by(fn {_uri, ctx} -> rule_id(ctx) end, fn {uri, _ctx} -> uri end)
    |> Enum.each(fn {rule_id, receivers} ->
      record_routing_trace(msg, workspace_uri, rule_id, receivers, nil)
    end)
  end

  defp record_routing_trace(%Message{} = msg, workspace_uri, rule_id, receivers, drop_reason) do
    workspace_uri = workspace_uri || msg.workspace_uri || Ezagent.URI.workspace(:system)

    case Trace.record(%{
           message_id: msg.id,
           workspace_uri: workspace_uri,
           rule_id: rule_id,
           receivers: receivers,
           hop: msg.hops,
           drop_reason: drop_reason
         }) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("routing trace write failed: #{inspect(changeset.errors)}")
    end
  end

  defp rule_id(%{rule_id: nil}), do: "no_match"
  defp rule_id(%{rule_id: id}), do: id
  defp rule_id(_), do: "no_match"

  # --- :receive ----------------------------------------------------------
  #
  # SPLIT OUT (PR-2, im/session/agent decomposition §OQ-4 / §3.3). The old
  # `handle_receive/2` branched internally on `ctx.kind_module`:
  #   - `Entity.User` → inbox slice → now `Ezagent.ActionSet.User.Receive`.
  #   - `Entity.Agent` → AgentBridge → now `Ezagent.ActionSet.Agent.Receive`.
  # The Agent branch's delivery mechanics remain in the shared
  # `Ezagent.ActionSet.Session.Delivery.deliver_agent_receive/2` helper
  # (reused by `Agent.Receive`). The internal `case kind_module` is gone —
  # dispatch routes `:receive` to the right Behavior by Kind.

  # --- :join -------------------------------------------------------------

  @doc false
  def handle_add_self(args, ctx), do: SelfAdd.handle_add_self(args, ctx, __MODULE__)

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
      |> Members.sanitize_facets()

    # RF-6 gate (`:join`): reject a PASSIVE data actor BEFORE lookup/monitor so it
    # never becomes a session MEMBER. Shares `passive_actor?/1` with the routing gate.
    if Members.passive_actor?(member_uri),
      do: {:error, {:passive_actor_cannot_join, member_uri}},
      else: do_handle_join(member_uri, facets, ctx)
  end

  defp do_handle_join(%URI{} = member_uri, facets, ctx) do
    # M-10: roster/monitor state is projection, never entitlement and never a
    # reason to skip the tier-0 -> tier-1 seam. Every authorized join reaches
    # do_join/4 so it consumes its single-use join grant and either confirms or
    # restores current tier-1. do_join preserves :already_member as an output
    # status when the projection was already present.
    Membership.do_join(member_uri, ctx, facets, __MODULE__)
  end

  @doc """
  team-routing-unification §3.1 — resolve a member `role_name` (stable
  per-session alias) to its member URI within a `members` map, or `nil` when
  no member carries that role_name. role_name is enforced unique per session
  at join (`role_name_conflict/3`), so at most one member matches.
  """
  @spec role_name_to_uri(map(), String.t()) :: URI.t() | nil
  def role_name_to_uri(members, role_name) when is_map(members) and is_binary(role_name) do
    Members.role_name_to_uri(members, role_name)
  end

  # --- :leave / :remove_participant (F7 PR-A) — bodies in Membership -------
  def handle_leave(%{member: %URI{} = member_uri}, ctx) do
    with :ok <-
           Ezagent.Socialware.CompositionCaps.deactivate_member(
             ctx[:self_uri],
             member_uri,
             :role_departure
           ) do
      {:ok, %{}, Membership.leave_effects(member_uri, ctx)}
    end
  end

  @doc false
  def handle_transfer_owner(%{owner: %URI{} = new_owner}, ctx) do
    prior_owner = ctx[:read].(:owner_uri, nil)
    members = ctx[:read].(:members, %{})
    last_seen = ctx[:read].(:last_seen, %{})

    updated_members =
      members
      |> then(fn current ->
        if match?(%URI{}, prior_owner), do: Map.delete(current, prior_owner), else: current
      end)
      |> Map.put_new(new_owner, %{online: false})

    updated_last_seen =
      if match?(%URI{}, prior_owner), do: Map.delete(last_seen, prior_owner), else: last_seen

    {:ok, %{owner: new_owner},
     [
       {:set, :owner_uri, new_owner},
       {:set, :members, updated_members},
       {:set, :last_seen, updated_last_seen}
     ]}
  end

  def handle_remove_participant(%{participant: %URI{} = participant_uri}, ctx) do
    Membership.handle_remove_participant(participant_uri, ctx)
  end

  @doc false
  def handle_assign_role(%{member: %URI{} = member_uri, role_name: role_name}, ctx)
      when is_binary(role_name) do
    with :ok <- require_user_member(member_uri),
         :ok <- require_declared_human_role(ctx, role_name),
         members <- ctx[:read].(:members, %{}),
         :ok <- require_joined_member(members, member_uri),
         :ok <- Members.role_name_conflict(members, member_uri, role_name) do
      updated_members =
        Map.update!(members, member_uri, fn meta ->
          Members.put_member_facets(meta, %{role_name: role_name})
        end)

      {:ok, %{member: member_uri, role_name: role_name}, [{:set, :members, updated_members}]}
    end
  end

  def handle_assign_role(%{member: %URI{} = member_uri}, _ctx) do
    with :ok <- require_user_member(member_uri) do
      {:error, :invalid_role_name}
    end
  end

  defp require_user_member(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :user), do: :ok, else: {:error, :assign_role_requires_user_uri}
  end

  defp require_user_member(_), do: {:error, :assign_role_requires_user_uri}

  defp require_joined_member(members, %URI{} = member_uri) when is_map(members) do
    if Map.has_key?(members, member_uri), do: :ok, else: {:error, :member_not_joined}
  end

  defp require_declared_human_role(ctx, role_name) when is_binary(role_name) do
    session_uri = ctx[:self_uri]

    declared? =
      case session_uri do
        %URI{} ->
          session_uri
          |> Ezagent.Socialware.Installation.installed_definitions()
          |> Enum.any?(fn definition ->
            Enum.any?(definition.roles, fn
              %{role_name: ^role_name, fill: :human} -> true
              _ -> false
            end)
          end)

        _ ->
          false
      end

    if declared?, do: :ok, else: {:error, {:human_role_not_declared, role_name}}
  end

  # --- :attach -----------------------------------------------------------

  @doc """
  Thin upload-authorization gate (LV→world parity PR-2b). The runtime authorizes
  this action at the chokepoint (required `:attach` cap + provenance +
  workspace-isolation) BEFORE calling the handler, so reaching here means the
  caller is allowed to upload into this session. It performs NO filesystem I/O
  (the upload controller stores the bytes after this `:ok`, keeping I/O off the
  session actor) and mutates no slice — it simply acknowledges authorization.
  """
  def handle_attach(_args, _ctx) do
    {:ok, %{ok: true}, []}
  end

  # --- :merge_member ------------------------------------------------------

  @doc false
  def handle_merge_member(%{from: %URI{} = from_uri, to: %URI{} = to_uri}, ctx) do
    Membership.do_merge_member(from_uri, to_uri, ctx, __MODULE__)
  end

  # --- Part C admission actions (approve / deny / withdraw) ----------------
  # Bodies + authz in `Membership` (spec §C.4/§C.5). Cap-exempt (see
  # `cap_exempt_actions/0`) — authorized in-handler by `manages?`/`requested_by`.

  @doc false
  def handle_approve_admission(%{member: %URI{} = member_uri}, ctx) do
    Membership.approve_admission(member_uri, ctx, __MODULE__)
  end

  @doc false
  def handle_deny_admission(%{member: %URI{} = member_uri}, ctx) do
    Membership.deny_admission(member_uri, ctx)
  end

  @doc false
  def handle_withdraw_admission(%{member: %URI{} = member_uri}, ctx) do
    Membership.withdraw_admission(member_uri, ctx)
  end

  @doc false
  def handle_composition_consent(
        %{
          binding_id: binding_id,
          side: side,
          command: command,
          idempotency_key: idempotency_key
        },
        %{caller: %URI{} = caller, self_uri: %URI{} = session_uri}
      ) do
    case Ezagent.Socialware.CompositionConsent.command(
           binding_id,
           session_uri,
           side,
           command,
           caller,
           idempotency_key
         ) do
      {:ok, consent} ->
        {:ok,
         %{
           request_id: consent.id,
           target_approval: consent.target_approval,
           source_approval: consent.source_approval
         }, []}

      {:error, _} = error ->
        error
    end
  end

  def handle_composition_consent(_args, _ctx), do: {:error, :invalid_consent_command}

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
  def handle_set_working_copy(%{template_working_copy: wc}, _ctx)
      when is_map(wc) do
    {:ok, %{template_working_copy: wc}, [{:set, :template_working_copy, wc}]}
  end

  @doc """
  System-internal path to write the durable `template_working_copy`
  field (HIGH-2 hardening). Thin delegator to
  `Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy/2`.
  """
  @spec system_set_working_copy(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate system_set_working_copy(session_uri, working_copy), to: ConfigActions

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
  #   - be the session ITSELF — `ctx.caller == ctx.self_uri` (#154,
  #     2026-06-20: `system://session-internal` was eliminated; the
  #     `system_set_legends/2` path now dispatches with `caller = the session`
  #     and this gate recognizes session-self authority. An external caller
  #     cannot forge `caller == self_uri` — `ctx.caller` is the authenticated
  #     entity, and `Entity.authenticate` never succeeds for a `session://`
  #     URI), OR
  #   - be the session's orchestrator — hold the exact `{:within_session,
  #     self_uri}` delegated cap (cap #1, granted only by the Generator).
  #
  # The `system_internal`-ctx-flag is NO LONGER consulted for legends.
  def handle_set_legends(%{legends: legends}, _ctx) when is_map(legends) do
    {:ok, %{legends: legends}, [{:set, :legends, legends}]}
  end

  @doc """
  Read the session-scoped legend registry from a `:chat` slice. Thin
  delegator to `Ezagent.ActionSet.Session.Legends.legends_of/1`.
  """
  @spec legends_of(map()) :: Legend.registry()
  defdelegate legends_of(chat_slice), to: Legends

  @doc """
  Resolve a legend NAME against a `:chat` slice's registry to its entry. Thin
  delegator to `Ezagent.ActionSet.Session.Legends.resolve_legend/2`.
  """
  @spec resolve_legend(map(), String.t()) :: {:ok, Legend.entry()} | :error
  defdelegate resolve_legend(chat_slice, name), to: Legends

  @doc """
  Member-list rows with folded legends collapsed (team-routing-unification
  §3.6 fold, PR-6, GATE c). Thin delegator to
  `Ezagent.ActionSet.Session.Legends.fold_members/1`.
  """
  @spec fold_members(map()) :: [
          {:legend, String.t(), [URI.t()]} | {:member, URI.t(), map()}
        ]
  defdelegate fold_members(chat_slice), to: Legends

  @doc """
  System-internal path to install the legend registry. Thin delegator to
  `Ezagent.ActionSet.Session.Legends.system_set_legends/2`.
  """
  @spec system_set_legends(URI.t(), Legend.registry()) :: {:ok, map()} | {:error, term()}
  defdelegate system_set_legends(session_uri, legends), to: Legends

  # --- :set_prompt_templates (team-routing-unification §3.4/§3.7, PR-7) ---

  # Install/overwrite the session-scoped named prompt-template map on the :chat
  # slice. Authorization mirrors `:set_legends` EXACTLY (codex 2026-06-01 HIGH
  # #2 — gate on a TRUSTED IDENTITY, not a ctx boolean): the caller must EITHER
  # be a trusted system principal (`set_legends` allowlist) OR be the session's
  # orchestrator (the `{:within_session, self_uri}` delegated cap). A
  # prompt-template fronts a team's delivery transform — the same
  # orchestrator/system-config authority class a legend has.
  def handle_set_prompt_templates(%{prompt_templates: pts}, _ctx) when is_map(pts) do
    {:ok, %{prompt_templates: pts}, [{:set, :prompt_templates, pts}]}
  end

  @doc """
  System-internal path to install the session-scoped named prompt-template map.
  Thin delegator to
  `Ezagent.ActionSet.Session.ConfigActions.system_set_prompt_templates/2`.
  """
  @spec system_set_prompt_templates(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate system_set_prompt_templates(session_uri, prompt_templates), to: ConfigActions

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
        Delivery.broadcast_membership_direct(ctx[:self_uri], {:member_offline, member_uri, now})

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

  # PERMANENT session deletion (`Lifecycle.destroy` / `manage.delete`, NOT a
  # graceful deactivate). Runs while the Kind is still LIVE, so the members slice
  # + durable working copy are readable from `state`. Delegates to the shared
  # `Teardown.cascade_teardown/2` (F7 PR-B, SPEC §4.1) — so EVERY delete path
  # cascades: it reaps every spawned worker + the orchestrator (owner durable-
  # lineage cap, dead-orchestrator-safe), prunes ALL session routing, forgets
  # lineage, AND stops the per-orchestrator `SessionManager` executor (the prior
  # Transport #53 behavior). Best-effort + idempotent.
  @impl Ezagent.Lifecycle
  def destroy(_reason, ctx) do
    Teardown.cascade_teardown(ctx[:self_uri], ctx[:state] || %{})
  end

  # --- Topic helpers (public — Ezagent.Kind.Server / LV subscribe via these) -

  @doc "PubSub topic for in-session events (chat stream feed)."
  @spec session_events_topic(URI.t() | String.t()) :: String.t()
  def session_events_topic(%URI{} = uri), do: session_events_topic(URI.to_string(uri))

  def session_events_topic(uri_str) when is_binary(uri_str),
    do: Delivery.session_events_topic(uri_str)

  @doc "PubSub topic for a User's personal receive notifications."
  @spec user_events_topic(URI.t() | String.t()) :: String.t()
  def user_events_topic(%URI{} = uri), do: user_events_topic(URI.to_string(uri))
  def user_events_topic(uri_str) when is_binary(uri_str), do: Delivery.user_events_topic(uri_str)

  # --- Delivery helpers --------------------------------------------------
  @doc false
  # team-routing-unification §3.4 (PR-4b): render the matched rule's prompt
  # template (carried in `ctx.prompt_template_ref` from
  # `Resolver.resolve_with_ctx/4`) over the message, using the session's
  # `prompt_templates` map. No ref / no such template / nil ctx → the message
  # is returned UNCHANGED (behaviour-preserving when no rule names a template).
  @spec render_for_delivery(Message.t(), map() | nil, map(), URI.t()) :: Message.t()
  def render_for_delivery(%Message{} = msg, ctx, templates, %URI{} = session_uri)
      when is_map(templates) do
    Delivery.render_for_delivery(msg, ctx, templates, session_uri)
  end

  @doc false
  # The fixed v1 template variable set, extracted from the delivered message +
  # current session (team-routing-unification §3.2/§3.4). `flavor` is "" for
  # now (the sender's agent flavor needs a lookup — deferred).
  @spec message_vars(Message.t(), URI.t()) :: map()
  def message_vars(%Message{} = msg, %URI{} = session_uri) do
    Delivery.message_vars(msg, session_uri)
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
