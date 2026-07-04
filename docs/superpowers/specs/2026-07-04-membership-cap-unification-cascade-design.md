# S3-first: Membership-as-Capability Unification + Cascade Notification — Design Spec

**Status:** Design (brainstorm → **spec** → plan). This is the spec-writing step;
plan + implementation follow separately.
**Supersedes:** `2026-07-04-cascade-notification-design.md` (the S1-cascade-first
spec — see its banner). That spec bolted a cascade notifier ON TOP of the current
incoherent membership model; codex adversarial review showed the cascade's whole
difficulty is rooted in that incoherence. This spec **fixes the root** (Part A:
membership becomes a capability), after which cascade (Part B) is a trivial rider.
**Date:** 2026-07-04
**Size:** LARGE. One coherent spec, internally phased **A1 → A2 → B** (see §12).
All three phases land the same architecture; the phase boundary is a safe
review/merge checkpoint, not a scope fork.

---

## R1 — Revision: codex round-1 fixes (2026-07-04)

Codex adversarial review verdict: **SHIP-WITH-CHANGES**. It confirmed the sound
core (O(1) hot-path **roster** read, presence needs session-side state,
provenance filtering) and raised 5 must-fixes. This revision closes them with
concrete, code-grounded designs. **Where a fix contradicts the original prose,
this section is authoritative** and the affected sections (§3, §5, §6, §4.3,
§4.4, §8, K1, §16) are patched inline to point here.

The single most important change: **§5/§6 as originally written made the cached
member-cap a bearer token** (delivery presented it in `ctx.caps`; the runtime's
`granted_via_ctx_caps?` authorizes whatever is presented — `runtime.ex:376-411`,
which checks `ctx.caps` BEFORE the held-cap path). R1.1 **removes authz from the
presented-cap path entirely** and separates **roster** (staleness-tolerant
delivery targeting) from **receive-authorization** (the recipient's *actually
held* cap).

### R1.1 — 🔴 CRITICAL: separate delivery ROSTER from receive AUTHORIZATION

**The bug.** Original §6 said delivery caches the member-cap in the projection
and presents it in `ctx.caps`; the runtime authorizes receive via
`granted_via_ctx_caps?` (`runtime.ex:398-402`, `authorizes?/2` at `:547-566`).
That is a **bearer token**: whoever presents the cached copy is authorized,
*regardless of whether the recipient still holds the cap*. If revoke succeeds but
the projection-drop fails (the §4.3 window), the stale cache still authorizes
receive. Membership-as-authz would be *softer* than today, not harder.

**The fix — two jobs, two mechanisms:**

1. **`:members` projection = delivery ROSTER only.** `handle_send/2` still does
   the O(1) local read `members_map = ctx[:read].(:members, %{})`
   (`session.ex:497`) and `Map.keys` (`:498`) to decide *who to attempt delivery
   to*. This read stays fast and is explicitly **staleness-tolerant**: a stale
   roster entry causes at most a *wasted delivery attempt* that then FAILS authz
   at the recipient — never an unauthorized receive. Roster staleness costs a
   dispatch, not a breach. **The crux (O(1) roster read, no reverse scan per
   message) is preserved unchanged.**

2. **Receive AUTHORIZATION = the recipient's actually-held member-cap, checked
   in-handler.** Delivery **presents NO receive cap** in `ctx.caps`
   (`member_receive_caps/1` at `delivery.ex:259-274` is **deleted, not replaced
   by a cache**). Instead each `:receive` behavior authorizes against the
   recipient's OWN `:identity`/`:caps` slice — see R1.2 for the exact contract. A
   revoked member no longer holds the cap ⇒ **denied immediately, before any
   reconcile, with zero bearer window.**

**Socialware read-auth (`socialware_publisher_read.ex` → `membership_predicate.ex:42-51`)
must move to held-cap too.** Today `member?/2` (`membership_predicate.ex:82-84`)
authorizes a read iff `Map.has_key?(members, caller)` — i.e. **"in the projection
⇒ authorized."** That is safe *today* only because leave drops the projection
synchronously. Under S3's revoke-first / projection-drop-may-lag (§4.3), "in
projection" is no longer a sound authz signal. Fix: the read predicate additionally
requires the caller to **HOLD the member-cap** — read the caller's live caps via
`Ezagent.Identity.read_entity_caps/1` (`identity.ex:336-341`) and `Capability.matches?/2`
(after the `granted_by_entity?/1` provenance filter, K4). The owner branch
(`owner?/2`, `membership_predicate.ex:78-80`) is unchanged. Net: an ex-member is
denied read immediately on revoke, matching the delivery-authz guarantee — one
coherent "held-cap, not projection" story across delivery AND read.

**Invariant (the security done-gate, R1.6):** for BOTH receive and read, a member
whose member-cap has been revoked is denied **without waiting for reconcile**. The
projection is never the authority for either path.

### R1.2 — 🟠 HIGH: a REAL receive-authz contract (covers plugin receives)

**Why K1 as written is not implementable by editing `User.Receive`/`Agent.Receive`.**
Three code facts:

- **Needed-cap instance is derived from the TARGET, not the sender.**
  `resolve_required_cap/4` (`runtime.ex:423-492`) substitutes `instance: :any →
  Ezagent.URI.instance(target)` (`:443-447`). For a `:receive` dispatch the target
  is the **recipient**, so a behavior declaration can only yield `instance:
  recipient` — never the source session S. There is **no path to substitute
  `ctx.caller`** (the sending session). So "flip the needed-cap to
  sender-session-scoped" cannot be expressed by a behavior's `required_caps/0`.
- **The held-cap path checks the CALLER, not the recipient.**
  `granted_via_holds_cap?/2` (`runtime.ex:516-534`) reads `caller = ctx.caller`
  (the session) and calls `Kind.holds_cap?(caller_kind, caller, needed)`. The
  member-cap is held by the **recipient**, not the session — so the generic
  runtime path checks the wrong entity. Receive is *consent-inverted*: the TARGET
  must hold a cap, not the caller.
- **There are ≥4 receive behaviors, each declaring its own `caps: [:receive]`.**
  `User.Receive` (`user/receive.ex:111`), `Agent.Receive` (`agent/receive.ex:88-91`),
  and plugin receives `HelloBuilder` (`hello_builder.ex:32-35`) + `HelloConcierge`
  (`hello_concierge.ex:22-25`). Editing only User/Agent silently misses plugin
  receives — codex #2's exact point.

**The contract — in-handler authorization, `:receive` cap-EXEMPT (CONFIRMED-precedent).**
Mirror the socialware read-auth pattern that already exists and is proven
(`socialware_publisher_read.ex:56-77, 116-139, 199-207`):

1. **`:receive` becomes a `cap_exempt_action`** on every receive behavior (add
   `:receive` to `cap_exempt_actions/0`), so the CapBAC layer does NOT gate it via
   the caller-scoped mismatch above. The HANDLER is the sole authority.
2. **A shared predicate `Ezagent.Session.MemberReceive.authorize(ctx)`** (new,
   sibling to `membership_predicate.ex`) authorizes iff the recipient HOLDS a
   member-cap whose instance matches `ctx.caller` (the source session S). It reads
   the recipient's OWN caps from **`ctx[:siblings][:identity]`** — pre-loaded via
   `reads_siblings([:identity])`, so there is **NO `GenServer.call` / no
   self-slice deadlock** (the `runtime.ex:393-407` hazard is avoided by
   construction) and **no per-message cross-process read** (the sibling is already
   loaded for the dispatch). `agent.receive` already declares
   `reads_siblings([:sandbox])` (`agent/receive.ex:80`), proving the receive path
   supports sibling pre-load; we add `:identity`.
3. **Every `{Kind, :receive}` behavior calls the ONE shared predicate** — no
   per-behavior copy (the same "extracted predicate, no drift on a security
   boundary" discipline as `membership_predicate`).

**Blast-radius CONFIRMED (the tightening is safe).** R1.2 tightens receive from
today's *self-consent bearer* (`delivery.ex:260-273`: a `cap(:any, :any, :receive,
instance: recipient)` granted_by the recipient, matching regardless of
`ctx.caller`) to "recipient holds a member-cap matching `ctx.caller`." That would
wrongly deny any `:receive` whose caller is NOT a session the recipient belongs to
— so we enumerated every dispatch site. **The ONLY `:receive` dispatch in `apps/`
is `Delivery.dispatch_receive_call/3`** (grep: the sole `Router.dispatch(action:
:receive)` at `delivery.ex:170-179`), called from exactly two session-scoped paths:
the fan-out `session.ex:564` and `replay_messages_since` (`delivery.ex:205-213`),
**both setting `ctx.caller = session_uri`.** No cross-session / external / direct
receive path exists. **Invariant: every `:receive` dispatch is session fan-out;
`ctx.caller` is always the source session.** A guard test asserts no other
`:receive` dispatch site is introduced. (So `MemberReceive.authorize/1` may safely
assume `ctx.caller` is a session; a future non-fan-out receive would fail the guard
and force an explicit decision — not silently break.)

**Invariant (codex #2: "an invariant that covers plugin receives, not just
User/Agent").** A new parity test — `ReceiveAuthzParityTest` — asserts that for
**every** behavior registered for `{_Kind, :receive}` (enumerated from the
`BehaviorRegistry`, the same source the `BehaviorRequiredCapsParityTest` uses),
`:receive ∈ cap_exempt_actions/0` AND the handler routes through
`MemberReceive.authorize/1`. A new plugin receive that skips the helper fails the
gate. This is the "REAL contract," not a two-module edit.

*Rejected alternative (documented so review sees it was weighed):* a **runtime
receive-inversion** (teach `resolve_required_cap` to substitute `ctx.caller` for
`:receive` and add a target-held-cap branch to `granted_via_holds_cap?`). It gives
the plugin-coverage invariant "for free" but requires the runtime to read the
recipient's `:identity` mid-`:receive` — the **documented self-slice deadlock**
(`runtime.ex:393-407`) for User recipients (whose `:identity` and `:session`
receive slice share one Kind process), or N cross-process reads per message if run
pre-routing. The in-handler/cap-exempt path avoids both and reuses a proven
precedent. **In-handler is primary; runtime-inversion is rejected.**

Least-privilege still improves exactly as original §5 claimed: the member-cap
authorizes receiving **only from sessions the member belongs to**, replacing the
old `cap(:any, :any, :receive, instance: recipient)` (`delivery.ex:260-273`) that
authorized any receive into the recipient from anyone.

### R1.3 — 🟠 HIGH: dual-write compensation + idempotent operations

Making the cap authoritative turns today's *tolerated* drift (`membership.ex`
grants participation caps LATER, best-effort) into **security** drift. R1.1
already **defangs the revoke side** (a stale roster entry is not authz — receive
reads the held cap), but the join side still needs ordered, compensating,
idempotent operations. "Idempotent" here means **idempotent-by-construction**
(skip-already-held grant, no-op revoke-of-absent, idempotent projection
set/delete) — **NOT** a persisted saga/operation-log. Sequences:

**JOIN (grant-first, preflight, compensate-on-failure):**
1. **Preflight BEFORE any grant.** The role/facet check
   `Members.role_name_conflict/3` runs at `membership.ex:48-50` **before**
   `do_join_apply/5` — a role conflict returns `{:error, _}` with **zero side
   effects**. Move the member-cap grant to AFTER this preflight so a role-conflict
   rejection can never orphan a granted cap (codex's `membership.ex:48-50`
   hazard).
2. **Grant the member-cap** — idempotent: skip if already held via
   `already_authorized?/5` (`membership.ex:888-903`).
3. **`do_join_apply` → projection entry** (`{:set, :members, …}`,
   `membership.ex:127-135`).
4. **Compensation:** if `do_join_apply` fails AFTER the grant (monitor error,
   etc.), **revoke the just-granted member-cap** (revoke is de-escalating and
   needs no authz — `grant.ex:452-457`). Net: either a full member (cap +
   roster) or nothing.

**LEAVE / REMOVE (revoke-first, roster-drop, no authz window):**
1. **Revoke the member-cap FIRST** (the authority).
2. **Drop the projection entry** (`leave_effects/2`, `membership.ex:525-548`).
3. If the roster-drop fails, **there is no authz window** — R1.1 means receive
   and read both read the *held* cap, already revoked. The stale roster entry only
   wastes a delivery attempt that fails at the recipient. `reconcile_after_load/2`
   evicts it on next activate.

**Tests for the three drift states (replaces "tolerated drift" with proven
behavior):**
- **cap-only** (cap granted, roster entry missing): reconcile ADDS the roster
  entry; delivery is authz-correct regardless.
- **roster-only** (roster entry present, cap absent — the dangerous one): the
  recipient's `:receive` is **DENIED** at the in-handler predicate (no held cap);
  reconcile EVICTS the roster entry. **No receive, ever.**
- **stale-cached-cap** (the original bug): **N/A by construction** — no cap is
  cached or presented anymore (R1.1). The test asserts `ctx.caps` on a receive
  dispatch carries **no** member-cap.

### R1.4 — 🟡 MED-HIGH: concrete agent enumeration API

`Users.list_in_workspace/1` (`users.ex:411-417`) is User-only, and
`mount_participation_caps/2` no-ops for non-users (catch-all
`mount_participation_caps(_, _), do: :ok` at `membership.ex:814`) — contradicting
"ALL members (users, agents, anon)." Specify a concrete enumerator, modeled
**exactly** on the proven `AgentRoleResolver` snapshot scan
(`agent_role_resolver.ex:35-64`):

```
Ezagent.Entity.Agent.list_in_workspace(ws) ::
  KindSnapshot.list_in_workspace(ws)                          # repo, workspace-scoped
  |> Enum.filter(& &1.kind_type == Atom.to_string(Entity.Agent.type_name()))  # type axis
  |> Enum.map(& &1.uri) |> map to %URI{}                       # live AND dormant
```

- **Live + dormant:** snapshot-sourced (every created agent has a `kind_snapshots`
  row), so a dormant agent member is still enumerated after a BEAM restart —
  exactly why `AgentRoleResolver` sources its list from snapshots, not ETS
  (`agent_role_resolver.ex:13-23`).
- **Workspace-scoped + type-filtered:** `KindSnapshot.list_in_workspace/1`
  (`kind_snapshot.ex:72-78`) bounds the tenant; the `kind_type == "agent"` filter
  excludes users/sessions/templates.
- **Used in THREE places:** (a) §4.4 reconcile candidate enumeration (union with
  `Users.list_in_workspace/1`); (b) the R1.5 migration's agent members; (c) the
  **agent-member-cap mount path** — replace the `membership.ex:814` non-user no-op
  with an explicit agent member-cap grant.

*(Naming caveat, flagged for the plan: `Entity.Agent` lives in
`apps/ezagent_domain_agent`; if the reconcile caller is in `ezagent_core` /
`ezagent_domain_session`, a direct module ref may trip
`undeclared_umbrella_dep_test`. Resolve via an existing cross-app seam — e.g. a
`UriQuery`-style enumerator or the identity layer — rather than a hard ref. This
is a plan-time placement detail, not a design gap; the scan shape is confirmed.)*

### R1.5 — 🟡 MED: bounded, paginated, snapshot-consistent migration

Original §8 read all sessions via `KindSnapshot.list_all` (loads every row) with a
live owner lookup. Replace with a **repo-only, paginated, snapshot-consistent**
migration — a pure `Ezagent.Session.MemberCapMigration` module behind a
`mix ezagent.migrate.member_caps` front door, mirroring the
`GrantMigration` + `ezagent.session.migrate_grants` split
(`grant_migration.ex`, `ezagent.session.migrate_grants.ex`):

1. **DB-level filter, NOT load-all-then-filter.** Query
   `from s in KindSnapshot, where: s.kind_type == "session"` — a WHERE clause so
   only session rows load. (This is the concrete improvement over
   `AgentRoleResolver`, which loads all rows then filters in Elixir —
   `agent_role_resolver.ex:61`.)
2. **Keyset pagination:** `order_by: s.uri, where: s.uri > ^last_uri, limit: @page`,
   loop until empty. Bounded memory; no `list_all`.
3. **Snapshot-consistent read:** decode ONCE per row via
   `KindSnapshot.decode_state/1` (`kind_snapshot.ex:223-239`) and read BOTH
   `members` AND `owner_uri` from the **same decoded persisted state** — never a
   live/racing owner lookup.
4. **Grant per member** (users AND agents — R1.4 gives the agent set for reconcile;
   the migration reads members directly off the session state so it covers both):
   member-cap `granted_by = owner_uri`; **ownerless fallback** → the #154 admin
   granter (matching `public_view_granter/1`), with the fallback **LOGGED and the
   count reported/admin-tagged** so provenance is auditable.
5. **Idempotent:** skip already-held (`already_authorized?/5`), so re-run is a no-op.
6. **Operator flags** (mirroring `migrate_grants`): `--dry-run` (report counts, no
   writes), `--gate` (nonzero exit if any session lacks member-caps), and a report
   of `{sessions_scanned, members_granted, skipped_already_held, ownerless_fallback}`.
   Idempotent + non-destructive ⇒ safe on a live dev DB
   (`feedback_destructive_migration_anti_pattern`).

### R1.6 — Acceptance E2E (the done-gate) — see new §14.5

A NEW end-to-end scenario proving the whole feature, including the CRITICAL
security proof (immediate deny after revoke, no reconcile wait). Defined in
full in **§14.5**. Split: the security done-gate is an **ExUnit integration test**
(deterministic; no reconcile timing to flake); the cross-user cascade UX is a
**world-UI agent-browser scenario in `docs/scenarios/`** (project convention —
`feedback_esr_e2e_standards`).

---

## 1. Problem & Goal

### Problem — two overlapping mechanisms for one concept

"Member of session **S**" is expressed **twice, incoherently**:

1. **As a session-side list.** The session's `:members` slice is a map
   `member_uri => meta` on the Session Kind's `:session` slice
   (`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:15`, `:293`).
   `:join` mutates it (`.../session/membership.ex:127-135`, `{:set, :members, …}`);
   `:leave` deletes from it (`.../membership.ex:557-566`). Delivery fan-out,
   presence, the UI roster, and read-authorization all key off this map.

2. **As capabilities.** Join ALSO grants the member a per-session participation
   cap tier into the member's OWN `:identity`/`:caps` slice —
   `mount_participation_caps/2` grants `Session.:send` / `Session.:leave` /
   `Publisher.SessionImpl.:subscribe_from` (`.../membership.ex:805-881`). But the
   membership-defining **`:receive` authority is NOT persisted** — it is minted
   **ephemerally, per delivery**, in `member_receive_caps/1`
   (`.../session/delivery.ex:259-274`): a throwaway
   `cap(:any, :any, :receive, instance: recipient)` presented in `ctx.caps` on
   every fan-out.

So "receive" keys off **membership** (the list), "send" keys off a **cap**, and
the two are wired by ad-hoc glue. The list is the source of truth for *who is a
member*; the caps are a partial, derived side-effect. This split is the root cause
of the S1 cascade's difficulty: a membership change mutates the SESSION's list
(not the member's own slice), so "who is affected / who owns them" needs an
indirection + re-fetch that the S1 spec could never make clean (and could not
solve removal-notify at all — S1 §9 risk 3).

### Goal — one authority: the member-cap

**"Member of S" = the member HOLDS a member-cap over S in the member's own
`:identity`/`:caps` slice.**

```
member-cap := Ezagent.Capability.cap(
  :session,                    # kind
  Ezagent.ActionSet.Session,   # behavior (module ref — invariant #2, not an atom)
  :receive,                    # action
  <instance: S>,               # the session S (concrete URI)
  <workspace_uri>)
```

- **join = grant that cap** to the member's identity.
- **leave / removal = revoke that cap** (symmetric).
- Delivery, presence, UI roster, read-authz, AND cascade all derive from
  "who holds the member-cap over S" — one authority, queried through the same
  capability primitives (`matches?/2`, `revoke/2`, provenance) as everything else.
- The ephemeral per-delivery `:receive` mint (`member_receive_caps/1`) is
  **deleted**; `:receive` becomes the standing, persisted member-cap.

### The unification claim, stated honestly (see §4 for the resolution)

The session's `:members` slice does **not** disappear. It is **demoted from source
of truth to a derived projection** that additionally carries irreducibly
session-runtime state (presence / monitors / last-seen). The capability is the
authority; the projection is a fast read-cache that also happens to be the
per-session reverse index. Why this is genuine unification and not a rename is
argued in §4.

---

## 2. Current mechanism — full trace (cite-first, so the plan knows every consumer)

Every consumer of the `:members` list, with file:line. This is the **blast
radius** of Part A.

### 2.1 The `:members` slice itself
- Shape: `map()` of `member_uri => meta`, where `meta` carries `:online`,
  `:role_name`, `:in_session_template`, `:source_template_uri`
  (`.../session/members.ex:37-62`). Stored on the Session Kind `:session` slice
  (`session.ex:293` `members: %{}`). PERSISTENT state (`session.ex:77`).
- `:monitors` (ref→URI) and `:last_seen` (URI→DateTime) are sibling keys;
  `:monitors` is a **transient** (`session.ex:88-98`), rebuilt in `activate/2`
  from the persisted `:members` set (`session.ex:410-424`).

### 2.2 join / leave (the write path)
- `do_join/5` → `do_join_apply/5` (`.../membership.ex:28-136`): reads `:members`,
  `Process.monitor`s the member pid, sets `online: true`
  (`.../membership.ex:85-90`), emits `{:set, :members, new_members}` +
  `{:set_transient, :monitors, …}` + membership broadcasts
  (`.../membership.ex:127-135`).
- After a successful join, the TRUSTED access point (LV self-join / invite /
  anon admission) calls `mount_participation_caps/2` (`.../membership.ex:805-881`)
  — grants `Session.:send`/`:leave` (confirmed) + `Publisher.:subscribe_from`
  (all) into the member's `:identity` slice. **This already grants caps at join.**
- `:join` itself is cap-gated; the just-in-time join cap is provisioned by
  `provision_join_authority/2` (`.../membership.ex:380-443`) before the dispatch.
- `leave_effects/2` + `leave_effects_with_ref/2` (`.../membership.ex:524-569`):
  `Map.delete(members, member_uri)` + `{:member_left}` broadcast.
- `handle_remove_participant/2` (`.../membership.ex:594-611`) — owner/self/admin
  gate, then leave-FIRST + fail-closed teardown (the atomicity precedent this
  spec reuses, §4.3).

### 2.3 Delivery fan-out (THE HOT PATH — per message)
- `handle_send/2` (`session.ex:456-566`): **`members_map = ctx[:read].(:members,
  %{})`** (`session.ex:497`) — an **O(1) local map read of the session's OWN
  slice** — then `in_session_members = Map.keys(members_map)` (`session.ex:498`).
  That list is handed to `Ezagent.Routing.Resolver.resolve_with_ctx/4`
  (`session.ex:516-528`; the `receivers: ["$session_members"]` rule expands over
  it), and the recipient loop dispatches `Delivery.dispatch_receive_call/3`
  per recipient (`session.ex:556-566`).
- `dispatch_receive_call/3` (`.../delivery.ex:142-186`) presents
  `member_receive_caps(recipient_uri)` (`.../delivery.ex:259-274`) — the
  **ephemeral per-delivery `:receive` cap** — in `ctx.caps`.
- **This is the mechanism the crux is about:** "members of S" is O(1) today
  because it is a local slice read on the session process.

### 2.4 Presence (online/offline)
- Set `online: true` at join (`.../membership.ex:89`).
- Flipped `online: false` in the monitor `:DOWN` handler `handle_signal/2`
  (`session.ex:900-933`): `Map.update(members, member_uri, %{online: false},
  …)` (`session.ex:914-915`) + `last_seen` + drop the dead ref from `:monitors`.
- Re-broadcast to the UI by `PresenceFanout`
  (`.../ezagent_domain_instance_message/presence_fanout.ex:62,79-86,190-208`):
  subscribes `esr:session_membership:changes`, keeps a `user → sessions` reverse
  index, emits `{:member_presence, session, member, %{online?: …}}`.
- **Presence is irreducibly session-runtime volatile state.** It lives inside the
  `:members` meta and is driven by `Process.monitor`/`:DOWN` on the Session Kind.
  It **cannot** live on a member-held capability (a cap is binary present/absent;
  online is a live flag). This is load-bearing for §4.

### 2.5 UI member list (roster)
- `member_presence/1` (`apps/ezagent_plugin_world/.../conversation_data.ex:394-405`):
  `Ezagent.Kind.get_slice(session_uri, :session)` → maps `members` meta `.online`.
- `member_options/1` (`.../conversation_data.ex:118-134`) builds UI rows;
  `push_members/1` (`.../conversation_actions.ex:747-764`) `push_event`
  `"members:update"`; LiveView pushes at `world_live.ex:109/130/135/166/170` and
  on `{:member_presence, …}` at `:172-173`.
- (`fold_members/1` — `.../session/members.ex:104-111` — is the routing/legend/
  @-mention fold, NOT the roster; noted so the plan doesn't conflate them.)

### 2.6 Read-authorization
- `socialware_publisher_read.ex:199-201` authorizes a READ iff `ctx.caller` is a
  **key of the `:members` map**, re-read LIVE every call (doc `:69-74,:196`).
  Another consumer of the `:members` projection.

### 2.7 Anon membership
- `AnonUser.mint_for_public_session/1`
  (`apps/ezagent_domain_socialware/.../anon_user.ex:118-142`): anon is **born with
  caps** — `join_cap(session_uri)` + `anon_view_caps(session_uri)` (`:130-132`).
- Anon join DOES mutate `:members` (via `anon_admission.ex:100-109` →
  `session.join` → `do_join`).
- Anon gets **publisher-read participation only** (no chat `:send`) —
  `do_mount_participation_caps/2` branches on `Ezagent.Users.confirmed?/1`
  (`.../membership.ex:830-838`): unconfirmed ⇒ `Publisher.:subscribe_from` only.
- Anon identity = `entity://<ws>/user/anon-<rand>`, authoritative signal
  `users.confirmed == false` (`.../membership.ex:299-322`).

### 2.8 Capability & identity substrate (the S3 target rides these)
- `%Capability{}`: axes `{kind, behavior, action, instance, workspace_uri}` +
  provenance `{granted_by, granted_at}` (`apps/ezagent_core/lib/ezagent/capability.ex:36-46`).
- `cap/5` arg order `(kind, behavior, action, instance, workspace_uri)`
  (`capability.ex:144-155`).
- `matches?/2` → `Match.matches?/2` (`capability/match.ex:27-39`), honors
  instance-scope tuples `{:within_session,_}` / `{:within_workspace,_}` /
  `{:spawned_by,_}` / concrete `%URI{}` (`match.ex:120-144`); wildcard rule
  asymmetric (held-side `:any` wildcards).
- `workspace_of/1` is **O(1)** from the URI string (`capability.ex:425` →
  `Scope.workspace_of/1`; SPEC v3 first authority segment).
- Revoke matches by `identity_key/1` = **5-tuple**
  `{kind, behavior, action, instance, workspace_uri}` (`match.ex:74-82`), NOT full
  struct (invariant #19); `revoke/2` (`capability.ex:216-229`).
- `granted_by_entity?/1` (`capability.ex:319-320`): rejects `%URI{scheme:
  "system"}` granters — the provenance filter.
- Caps physically live in the **`:identity` slice, key `:caps`** (a
  `MapSet.t(%Capability{})`), on **BOTH User and Agent Kinds**
  (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:7-26`;
  `handle_grant_cap` `{:set, :caps, …}` at `:440`). **Agents carry `:identity`
  caps too** — so agent-held member-caps and agent-side cascade both work.
- `read_entity_caps/1` (`identity.ex:336-341`): reads the **LIVE** `:identity`
  slice, snapshot fallback. `Grant.grant_cap_via_router/4`
  (`identity/grant.ex:121-141`); revoke `Grant.revoke_cap/3` (`:108-110`);
  `{:rule,…}`-tagged revoke runs NO authz (revoke only de-escalates, `:452-457`).
- `CreatorGrant.manage_cap/4` (`apps/ezagent_core/lib/ezagent/creator_grant.ex:19-31`):
  `Manage` behavior, `action: :any`, concrete `instance`, `granted_by: creator`
  — minted into the creator's identity at entity-create. This is what makes
  `managers_of(agent) == creator` resolvable (Part B).
- **NO reverse cap-holder index exists** (CONFIRMED): `CapabilityRegistry`
  (`capability_registry.ex`) is subject-oriented, keyed `{kind, behavior, action}`
  (`:89-92`); no `holders_of` / `who_holds` / `caps_over` anywhere in `apps/`.
- `Ezagent.Notifications.notify/2` (`apps/ezagent_core/lib/ezagent/notifications.ex:84-117`)
  **RAISES for non-User URIs** (`kind_module_of!/1`, `:192-205`).
- `SliceChange.emit/1` (`apps/ezagent_core/lib/ezagent/slice_change.ex:108,143-193`);
  content-free envelope `{uri, slice_key, cursor, event_at, result_summary}` —
  **drops `:caller` + all slice content** (`build_broadcast_event/2`, `:202-239`);
  topic `esr:entity:<uri>:slice_changed` (`:77-80`).
- The single slice-mutation emit chokepoint: `Kind.Server.commit_and_notify/3`
  (`apps/ezagent_core/lib/ezagent/kind/server.ex:731-740`); post-commit the
  runtime enqueues `Ezagent.Kind.DeferredDispatch.enqueue(deferred)` on a
  SEPARATE mailbox turn (`server.ex:610-618`, `:642-650`;
  `deferred_dispatch.ex:53-61`). **This is where the cascade hook attaches
  (Part B) — NOT a per-URI subscriber.**

---

## Part A — Membership as a capability

### 3. Target model

1. **Membership = holding the member-cap** `cap(:session, Ezagent.ActionSet.Session,
   :receive, instance: S, ws)` in the member's own `:identity`/`:caps` slice. This
   is the **source of truth**.
2. **join = grant the member-cap.** Fold this into the existing at-join grant flow
   (`mount_participation_caps/2` already grants caps at join — §2.2). The member-cap
   is granted to ALL members (users, agents, anon); `:send` remains an ADDITIONAL
   cap for confirmed users only (§7).
3. **leave / removal = revoke the member-cap** (`Capability.revoke/2` by 5-tuple
   identity_key). Symmetric.
4. **The session `:members` slice is retained as a derived projection** — the
   fast, session-local read-cache + reverse index + presence carrier (§4).
5. **`member_receive_caps/1` is deleted** and **NOT replaced by a cache.** Delivery
   presents NO receive cap; receive-authz reads the recipient's HELD member-cap
   in-handler (**R1.1 / R1.2** — this supersedes the original "presents the cached
   standing cap" design, which was a bearer token).
6. **`:receive` authorization semantics flip** from "recipient-instance-scoped" to
   "sender-session-scoped": receiving a message *from S* now requires a member-cap
   *over S*, checked at the recipient's own `:receive` chokepoint against its own
   held caps (**R1.2**, Key Decision K1). This is what lets one cap serve both roles
   (membership marker AND receive authority) — see §5.

### 4. ⚠️ THE CRUX — member-lookup efficiency (the make-or-break)

**Problem.** Today "members of S" is O(1): `ctx[:read].(:members, %{})` —a local
slice read on the session process (`session.ex:497`), run **per message** in the
delivery hot path. If membership becomes purely "who holds the member-cap over S,"
that read becomes a **reverse cap query** — "enumerate all identities holding a cap
with instance == S" — and there is **NO reverse holder index** (§2.8, CONFIRMED). A
naive per-message scan over every workspace identity's live caps is a serious
delivery regression. This MUST be resolved. Options weighed:

- **(a) A maintained reverse index** (session → member set), updated on
  grant/revoke of the member-cap. Honest cost: this *is* a `:members`-like derived
  structure — it reintroduces exactly the list the unification claims to remove,
  as a separate global index that must be transactionally consistent with the caps.
- **(b) Keep a derived member-set cache on the session** as a pure projection of
  the member-caps (source of truth = caps; cache = fast read). Question to resolve:
  is this "unification" or a rename?
- **(c) something else** (e.g. a `jsonb` + GIN reverse containment query) — rejected:
  `users.caps_json` is a `:string` column, not `jsonb` (`users.ex:27`); agents
  aren't in `caps_json` at all; and it still wouldn't serve the hot path cheaply.

#### 4.1 Resolution — **Option (b), and it is genuine unification, not a rename**

**Pick (b): the session's `:members` slice is retained as a projection/read-cache
of the member-caps; delivery reads it exactly as today (O(1)); the cache doubles as
the per-session reverse index.**

The decisive argument — **the projection is required infrastructure that must exist
regardless of S3:**

> Presence (`:online`), the monitor map, and `:last_seen` are irreducibly
> session-runtime, volatile state (§2.4). They CANNOT live on a member-held cap and
> MUST have a session-side home no matter what. The session already holds, and
> must keep holding, a per-member structure keyed by member URI. Making that same
> structure *also* the membership read-cache is **free** — it adds no new global
> data structure, no new consistency surface beyond what the presence machinery
> already requires.

That is why (b) beats (a): **(a) introduces a NEW global index** whose only job is
membership and which must be kept consistent with the caps across every workspace;
**(b) reuses a structure that has to exist anyway** and scopes it to a single
session (bounded by that session's own membership, not global). The reverse
"who-holds-cap-over-S" query is answered **for free** because the session process
*is* the natural home of its own roster — a session only ever needs ITS OWN members,
which it already holds locally.

**So: one authority (the cap) + one runtime-state structure (the projection) that
also caches — NOT two authorities.**

#### 4.2 Why this is unification, not a rename (the honesty answer)

Three concrete mechanism changes make it real, not cosmetic:

1. **The ephemeral per-delivery `:receive` mint is eliminated.** Today every
   fan-out mints a throwaway cap (`member_receive_caps/1`). Under S3 the member
   holds one standing member-cap; delivery presents the cached copy. Fewer
   allocations, and — decisively — the receive *authority* is now a durable,
   revocable, queryable fact instead of an implicit consequence of list membership.
2. **join/leave change from "mutate a list" to "grant/revoke a cap."** This is
   what makes Part B trivial (§9): the grant lands on the MEMBER's own slice, so a
   membership change is a slice-change *on the member*, resolvable by the same
   `managers_of/1` reverse-authority query as any other cap change — no
   session-`:members` re-fetch, no affected-principal indirection.
3. **The authority is now queryable through the shared cap primitives** —
   `matches?/2` (scope tuples), `revoke/2` (5-tuple identity), `granted_by_entity?/1`
   (provenance), `read_entity_caps/1` (live). Membership, receive-authz, send-authz,
   and cascade all speak one vocabulary.

**The honest caveat, stated plainly:** the fast-read member *list* survives as a
cache. We do NOT pretend delivery performs a reverse cap scan per message — it
reads the projection, exactly as today. The cap is the source of truth; the list is
a derived, session-local view of it. Calling the list "authoritative" would be the
old bug; calling it "a projection of the authoritative caps" is the fix.

#### 4.3 Cap ↔ projection coherence (FIRST-CLASS — this is what review will attack)

Option (b) creates a value that lives in two places: the member-cap in the member's
`:identity` slice (source of truth) and the member entry in the session's `:members`
projection (cache). Their coherence is the real risk. Resolution:

- **The write topology is UNCHANGED from today.** `do_join` already mutates the
  session `:members` map AND `mount_participation_caps` already grants caps into the
  member's identity — in the *same* join flow (§2.2). S3 changes *which* caps
  (adds the receive member-cap; promotes it to source of truth) — it does **not**
  introduce a new dual-write topology. There is no new cross-Kind consistency
  surface; there is the same one, now with clearer ownership.
- **Ordering + fail-closed + compensation (see R1.3 for the full sequence).**
  Preflight the role/facet check (`membership.ex:48-50`) BEFORE any grant; grant the
  member-cap FIRST (source of truth); only on grant success update the projection.
  A failed `do_join` AFTER the grant **compensates by revoking the just-granted
  cap** (so a role conflict / monitor failure never orphans a cap). Symmetrically,
  revoke FIRST, then drop the projection entry. This mirrors the existing
  leave-FIRST / fail-closed-teardown discipline in `handle_remove_participant`
  (`.../membership.ex:624-687`). **R1.3 additionally specifies tests for the
  cap-only / roster-only / stale-cached-cap drift states** — and note that R1.1
  (held-cap authz) means a revoke-first roster-drop failure has **no authz
  window**, only a wasted delivery attempt.
- **`reconcile_after_load/2` is the steady-state coherence spine (invariant #20).**
  On session `activate/2` (which today already rebuilds `:monitors` from persisted
  `:members` — `session.ex:410-424`), the session **reconciles its projection
  against the authoritative member-caps**: run the bounded per-workspace reverse
  scan ONCE at boot (§4.4), union/dedupe against the persisted projection, and heal
  any drift (caps win). This runs at cold boot, not per message. It is the same
  reconcile-after-restore invariant already required of DB-projecting Behaviors.
- **Sole sanctioned revoke path.** The member-cap is **owned by the membership
  lifecycle**: it is granted only by join and revoked only by `:leave` /
  `:remove_participant` / the session-teardown cascade (`session/teardown.ex`).
  Per the no-shims / let-it-crash ethos, we do NOT support ad-hoc external revoke
  of a member-cap that leaves the projection stale; a `manage.delete` of a member
  entity cascades through the session teardown that also drops the projection.
  (Defense in depth: `reconcile_after_load/2` heals any out-of-band drift on next
  activate.)
- **One named behavior shift (state it, don't let review find it):** today a failed
  participation-cap grant leaves a member who "can't send but is still a member"
  (best-effort, `.../membership.ex:862-878`). Under S3 with grant-first/fail-closed,
  a failed **member-cap** grant means **not a member** (no projection entry, no
  delivery). This is arguably cleaner (membership is exactly cap-possession) but it
  IS a behavior change from best-effort to fail-closed for the membership-defining
  cap. `:send` (a secondary cap) MAY remain best-effort (degrade to observe).

#### 4.4 The reverse query, when it IS run (cold paths only)

Delivery never calls it. It is invoked only by (1) `reconcile_after_load/2` at
session boot, and (2) any admin/debug "list members of S" that does not go through
the live session process. Algorithm — **bounded, no global scan:**

1. `ws = Ezagent.Capability.workspace_of(S)` — O(1) from the URI.
2. Enumerate candidate holders = the workspace's identities. Users:
   `Ezagent.Users.list_in_workspace(ws)` (`users.ex:411-417`); Agents:
   `Ezagent.Entity.Agent.list_in_workspace(ws)` (**R1.4** — the snapshot scan
   modeled on `agent_role_resolver.ex:35-64`, covering live AND dormant agents).
   Union the two sets.
3. For each candidate, read **LIVE** caps via `Ezagent.Identity.read_entity_caps/1`
   (NOT `caps_json` — see K5) and test for a member-cap whose instance matches S via
   `Capability.matches?/2` (honoring scope tuples), AFTER the `granted_by_entity?/1`
   provenance filter (K4).
4. The matching set is the authoritative membership; reconcile the projection to it.

Cost: one bounded per-workspace pass at cold boot. If a workspace's identity count
ever makes even the cold pass expensive, a maintained reverse index (option (a)) is
the future optimization — noted, not in S3. **Delivery stays fast because it never
touches this path.**

### 5. How ONE cap serves both membership AND receive-authorization

The member-cap must simultaneously be (i) the **membership marker** — queryable as
"holders over S" — and (ii) the **receive authorization** at the member's `:receive`
chokepoint. Today's ephemeral receive cap is scoped `instance: recipient`
(authorizes "a receive into ME"); a membership marker wants `instance: S`
(queryable as "member of S"). One cap cannot be scoped to two instances — so we
**flip the `:receive` needed-cap to be sender-session-scoped** (K1):

- Member-cap held by M: `cap(:session, Session, :receive, instance: S)`.
- When S fans out to M, M's `:receive` handler authorizes the receive iff **M
  itself HOLDS** a cap whose `instance` matches **S** (`ctx.caller`, the calling
  session), read from M's own `:identity` sibling — **NOT** a cap presented by
  delivery (**R1.1/R1.2**; the original "delivery presents it from the projection
  cache" was the bearer-token bug R1.1 removes).
- Reverse query "members of S" = holders of a cap with `instance` matching S. ✓
- Least-privilege improves: the cap authorizes receiving **only from sessions M is
  a member of**, instead of the old `cap(:any, :any, :receive, instance: M)` which
  authorized any receive into M from anyone.

This is the single semantic change that makes the unification coherent; it is
called out as Key Decision K1 because it touches the `:receive` authorization
declaration.

### 6. Delivery under S3 (staying fast)

> **SUPERSEDED IN PART BY R1.1/R1.2.** The original §6 (below, struck) cached the
> member-cap and PRESENTED it in `ctx.caps` for authz — a bearer token. R1.1
> separates roster from authz. This section now describes ONLY the roster read;
> authz moves to the recipient's in-handler held-cap check (R1.2).

`handle_send/2` is **unchanged in shape**: `members_map = ctx[:read].(:members,
%{})` (`session.ex:497`) still reads the projection as the **delivery ROSTER**;
`Map.keys` (`:498`) still feeds the Resolver's `$session_members` expansion. This
is the crux read — O(1), local, no reverse scan per message. **Unchanged.**

What changes (R1.1/R1.2):

- **`dispatch_receive_call/3` presents NO receive cap.** The `member_receive_caps/1`
  mint (`delivery.ex:259-274`) is **deleted**; `ctx.caps` on the receive dispatch
  carries no member-cap (the cast may still carry a `reply: :ignore` etc., but no
  authz-bearing cap). Authz is NOT via `granted_via_ctx_caps?` anymore.
- **The recipient authorizes its OWN receive in-handler** against its OWN held
  member-cap (from `ctx[:siblings][:identity]`, `reads_siblings([:identity])`),
  matching `ctx.caller` (S). A revoked member is denied immediately. `:receive` is
  `cap_exempt` at the CapBAC layer; the shared `MemberReceive.authorize/1` predicate
  is the sole authority (R1.2).
- **Roster staleness is fail-safe:** a stale roster entry yields a delivery attempt
  that FAILS the recipient's in-handler check — never an unauthorized receive.
- **Net hot-path delta: neutral.** Roster read is identical to today; the recipient
  reads its own already-loaded `:identity` sibling (no extra GenServer.call, no
  reverse query). **Crux satisfied; bearer-token hole closed.**

<details><summary>Original §6 (superseded — the bearer-token design)</summary>

- The projection entry for each member caches the standing member-cap (or enough to
  reconstruct it — `{instance: S, ws}` is enough; behavior/action/kind are fixed).
- `dispatch_receive_call/3` presents that **cached standing cap** in `ctx.caps`
  instead of calling the now-deleted `member_receive_caps/1`. [SUPERSEDED — bearer
  token: authorizes the presented copy regardless of whether the recipient still
  holds the cap. See R1.1.]

</details>

### 7. `:send` — stays a separate cap

`:send` does **not** fold into the member-cap. Rationale: `:send` is orthogonal
authority (posting rights), and the read-only anon model depends on "member (can
receive) but NOT sender." Folding would break anon. So:

- member-cap (`:receive`) — granted to **all** members (incl. anon/unconfirmed).
- `Session.:send` (+ `:leave`) — granted **additionally** to confirmed users, exactly
  as `do_mount_participation_caps/2` already tiers on `Users.confirmed?/1`
  (`.../membership.ex:830-838`). Unchanged.

This is just formalizing the existing tiering, with the member-cap added as the
universal base tier.

### 8. Presence, anon, removal, migration

- **Presence.** Unchanged in mechanism: `:online` stays a facet on the projection
  entry; join sets `true`, `:DOWN` flips `false` (`session.ex:914-915`); the monitor
  map + `PresenceFanout` are untouched. Presence is explicitly SEPARATED from
  membership: a member with the cap but a dead process is a member (`online: false`).
  This dissolves the old muddle where "member" and "online" shared one map with no
  conceptual boundary.
- **Anon.** Anon holds the member-cap (anon IS a member, read-only). `AnonUser`
  already mints anon caps at admission (`anon_user.ex:130-132`); add the member-cap
  to `anon_view_caps/1` (or grant it in the anon admission's post-join mount). Anon
  does NOT get `:send` (unconfirmed tier — §7). No new anon concept; the model gets
  *cleaner* (anon = holds member-cap, lacks send cap). The first-join owner-claim
  suppression for anon (`.../membership.ex:108`) is unaffected.
- **Removal.** `:leave` and `:remove_participant` revoke the member-cap (revoke
  FIRST, then drop the projection entry — §4.3), plus the existing routing-prune /
  worker-teardown. The `{:member_left}` broadcast still fires (convergence). Because
  revoke mutates the LEAVER's own `:identity` slice, removal now produces a
  slice-change on the leaver — which is exactly what closes the S1 removal-notify
  gap (§9, §11).
- **Migration** of existing sessions (`:members` rows → member-cap grants). A
  one-shot, **idempotent, bounded, paginated, snapshot-consistent** migration task
  `mix ezagent.migrate.member_caps` — fully specified in **R1.5** (repo-only
  `where kind_type == "session"` + keyset pagination; decode once and read
  `members` + `owner_uri` from the SAME persisted state; ownerless #154 fallback
  logged + counted; `--dry-run` / `--gate` / report). Supersedes the original
  `KindSnapshot.list_all` + live-owner-lookup sketch. The `:members` projection
  rows are kept as-is (they become the roster cache); `reconcile_after_load/2`
  (§4.3) is the steady-state backstop, the task is the initial seed. Idempotent +
  non-destructive ⇒ safe on a live dev DB
  (`feedback_destructive_migration_anti_pattern`).

---

## Part B — Cascade notification (now trivial, rides on Part A)

### 9. The simplification Part A buys

Because join/leave = grant/revoke a member-cap on the **MEMBER's OWN** `:identity`
slice, adding/removing a member is a slice-change **on that member**, not on the
session's `:members` list. So:

- **One event type:** an `:identity`/`:caps` slice change (`slice_key == :caps` on
  an entity's `:identity` slice), surfaced by the existing `SliceChange.emit`
  chokepoint (`slice_change.ex`).
- **`affected_principals` is ALWAYS `[X]`** — the entity whose slice changed. NO
  session-`:members` re-fetch, NO affected-principal indirection. The S1 spec's
  entire `affected_principals/2` complication (re-fetch members, resolve owners of
  each) **is gone**.
- **Removal falls out symmetrically.** Revoking A's-agent's member-cap is a
  slice-change on A's-agent → `managers_of(A's-agent)` → A. **S1 could not notify on
  removal** (the leaver was absent from the re-fetched `:members` set — S1 §9 risk
  3); **S3 closes that gap for free.** This is a concrete S3 > S1 win and part of
  why the lead chose S3.

**Worked case (the motivating scenario).** B pulls A's cc agent into B's session S.
Under S3, "pulling in" = granting the member-cap `cap(:session, Session, :receive,
instance: S)` to **A's-agent's** `:identity` slice. That mutates A's-agent's `:caps`
→ `SliceChange.emit` on `A's-agent` → cascade resolves `managers_of(A's-agent)` =
the creator (holds `CreatorGrant.manage_cap` over the agent — `creator_grant.ex:19`)
= **A** → notify A. **A is notified**, with zero indirection.

### 10. The cascade component

- **Hook site:** the single emit chokepoint. After `commit_and_notify/3`
  (`server.ex:731-740`) succeeds, the cascade is enqueued on the post-commit
  `DeferredDispatch` turn (`server.ex:610-618`), **exactly like `deferred_dispatch`
  — NOT a per-URI subscriber** (per-URI subscription doesn't scale — carried codex
  Blocker 3, K3). The cascade only fires for allowlisted `{scheme, slice_key}`
  (initially `{entity, :caps}` for identity/cap changes — cap grant/revoke,
  including the member-cap). It stays OFF the mutating dispatch's critical path
  (separate mailbox turn; a slow/failing cascade cannot roll back the mutation,
  mirroring `SliceChange.emit`'s post-commit non-fatal contract).
- **Resolver `managers_of/1`:** given the changed entity X, return the User URIs
  holding one-level manage/owner authority over X, bounded to X's workspace:
  1. `ws = workspace_of(X)` (O(1)).
  2. candidates = `Users.list_in_workspace(ws)` (bounded).
  3. for each candidate, read **LIVE** caps via `read_entity_caps/1` (K5), apply
     `granted_by_entity?/1` (K4), then match a `Manage`-over-X cap
     (`Ezagent.ActionSet.Manage`, `action: :any`, instance covers X via
     `matches?/2`) OR a workspace-admin cap — reusing the authority predicates
     extracted into `Ezagent.Identity.Authority` (K2).
  4. dedupe, filter to User URIs (agents can't be notified yet — §11 S2).
- **Payload:** security-minimal, content-free (same discipline as the
  `slice_changed` envelope's HIGH-1 leak fix): `{entity_uri, slice_key, event_at,
  cursor}` — NO cap values, NO member list. An authorized recipient re-fetches
  detail via a cap-gated read.
- **Delivery:** `Ezagent.Notifications.notify/2` per recipient (raises for non-User
  — recipients are filtered to Users, §11).

**This is the SAME reverse-authority machinery Part A's cold reconcile uses**
(`managers_of` and the projection reconcile both do a bounded per-workspace live-cap
scan). But note the deliberate distinction: **delivery's "members of S" is served
from the projection cache (hot, never scans); cascade's "managers of X" is the
bounded scan (cold, per cap-change).** Same conceptual reverse-query, different
performance treatment. They are NOT the same query (holders-of-member-cap-over-S vs.
holders-of-manage-cap-over-X); do not blur them.

---

## 11. Key decisions (with carried-over codex fixes)

**K1 — receive-authz = the recipient's HELD member-cap over the source session,
checked in-handler.** One cap serves membership + receive-authz (§5). **REVISED
(R1.2):** NOT a `required_caps/0` edit on User/Agent.Receive (that path can only
scope `instance` to the target, and the runtime held-cap path checks the *caller*,
not the recipient — `runtime.ex:443-447, 516-534`). Instead: `:receive` becomes
`cap_exempt` on every receive behavior and a **shared `MemberReceive.authorize/1`**
predicate reads the recipient's own `ctx[:siblings][:identity]` caps and matches
against `ctx.caller`. **Confirmed-sound?** CONFIRMED-precedent — mirrors the proven
socialware cap-exempt in-handler read-auth (`socialware_publisher_read.ex:56-77`);
`agent.receive` already declares `reads_siblings` (`agent/receive.ex:80`). A
`ReceiveAuthzParityTest` invariant covers ALL `{Kind, :receive}` behaviors incl.
plugin receives (R1.2). No runtime consent-inversion (rejected — self-slice
deadlock).

**K2 — Extract a PUBLIC `Ezagent.Identity.Authority`** with `manages?/2` and
`workspace_admin?/2`. CONFIRMED it does NOT exist today; the predicates
`holds_manage_over_target?/2` (`behavior/identity.ex:718-731`) and
`holds_workspace_admin_cap?/2` (`:858-881`) are **PRIVATE `defp`** inside
`ActionSet.IdentityAdmin`. A sibling public module `Ezagent.Identity.AdminAuthority`
exists (`identity/admin_authority.ex`, public `admin?/2`) but exposes no per-target
`manages?/2`. Extract the two predicates into `Ezagent.Identity.Authority` and have
both `IdentityAdmin` and the cascade resolver call it (single source of authority
truth). Do not duplicate the predicate logic.

**K3 — Cascade hook at the single emit chokepoint, not a per-URI subscriber.**
Attach at `commit_and_notify/3` → `DeferredDispatch.enqueue` (`server.ex:610-618`),
like `deferred_dispatch`. Per-URI subscription does not scale (carried codex
Blocker 3). CONFIRMED chokepoint exists.

**K4 — Provenance filter before match.** The resolver applies
`Ezagent.Capability.granted_by_entity?/1` (`capability.ex:319-320`) BEFORE
`matches?/2`, exactly as dispatch auth does (`runtime.ex:557-566`
`authorizes?/2`), so stale/system-granted caps don't over-match. CONFIRMED path.

**K5 — Read LIVE identity caps, NOT `users.caps_json`.** `caps_json` is provisioning
config (`users.ex:27`, a `:string` column); grant/revoke mutates the live
`:identity`/`:caps` slice. Both the Part A reconcile and the Part B resolver use
`Ezagent.Identity.read_entity_caps/1` (`identity.ex:336-341`, live→snapshot). Scope
tuples (`{:within_workspace,_}` / `{:spawned_by,_}`) live in slices, not the JSON.
(`list_in_workspace/1` is used only to ENUMERATE candidate users; the authority
check reads live caps.) CONFIRMED.

**K6 — member-cap is lifecycle-owned; grant-first / revoke-first, fail-closed**
(§4.3). CONFIRMED atomicity precedent: `handle_remove_participant`
(`.../membership.ex:624-687`).

**Confirmed-sound, do not re-litigate** (carried from S1 review): `do_join`
mutates `:members` today (`.../membership.ex:127-135`); `slice_changed` is
content-free + omits `:caller` (`slice_change.ex:202-239`); `notify/2` raises for
non-User (`notifications.ex:192-205`); `workspace_of/1` is O(1) (`capability.ex:425`);
`matches?/2` honors scope tuples (`match.ex:120-144`).

---

## 12. Internal phasing (ONE spec, three merge-safe phases)

This is a big change; implement in three phases, each independently green + merged,
all landing the same architecture. Phasing = review checkpoints, not scope forks.

- **A1 — member-cap model + migration (foundation, low risk).** Define the
  member-cap; add its grant to the at-join flow alongside `mount_participation_caps`;
  add `reconcile_after_load/2` seeding; write + run the idempotent migration task.
  Delivery still reads the projection with the UNCHANGED read shape and STILL mints
  ephemerally (the mint is deleted in A2), so this phase is behavior-preserving and
  purely additive. Member-caps now exist and are authoritative; nothing yet depends
  on them for delivery.
- **A2 — delivery/presence cutover (the load-bearing phase).** Make `:receive`
  `cap_exempt` + add the shared `MemberReceive.authorize/1` in-handler predicate
  (K1/R1.2) + the `ReceiveAuthzParityTest`; delete `member_receive_caps/1` (present
  NO cap — R1.1); move the socialware read predicate to held-cap (R1.1); wire
  leave/remove to revoke the member-cap with compensation (revoke-first,
  fail-closed, R1.3); anon holds the member-cap. Presence/monitors untouched. This
  phase carries the blast radius (receive authz, read authz, anon, removal) and is
  where the §14.5 acceptance E2E lives.
- **B — cascade rides on top (small, given A).** Extract `Ezagent.Identity.Authority`
  (K2); add the cascade hook at the emit chokepoint (K3); implement `managers_of/1`
  (K4/K5); content-free notify. `affected_principals` is always `[X]`.

Each phase gets the SPEC → codex-adversarial-review gate before implementation and
`/codex:adversarial-review` at PR open (per project convention).

---

## 13. Error handling

- **Grant failure at join (member-cap):** abort, no projection entry — fail-closed
  (§4.3, K6). Distinct from the best-effort `:send` grant (may degrade to observe).
- **Revoke failure at leave:** do NOT drop the projection entry (revoke-first
  discipline); log + telemetry; `reconcile_after_load/2` heals on next activate.
  Never leave a revoked cap with a live projection entry OR vice-versa silently —
  reconcile is the backstop.
- **Reconcile reverse scan errors** (`list_in_workspace` / `read_entity_caps`
  raise): rescue per candidate, log `:warning`, keep the persisted projection entry
  (fail-safe toward existing membership rather than silently evicting a member on a
  transient read error). Never crash `activate/2`.
- **Cascade resolver DB error / `get_slice` failure:** rescue, log, emit no
  notification for that event; the cascade is best-effort/advisory, off the mutating
  path (non-fatal by construction, like `SliceChange.emit`).
- **`Notifications.notify/2` raises** (non-User slipped through): resolver filters
  to Users, so this is a programmer error; wrap per-recipient notify in a rescue so
  one bad recipient doesn't drop the batch, but let it surface in tests.
- **Bad/non-dict cascade envelope:** guard-clause ignore; never crash.

---

## 14. Testing (TDD — write tests first, each maps to a behavior)

**A1 — member-cap model + migration**
1. join grants the member-cap into the member's `:identity`/`:caps` slice (assert
   via `read_entity_caps/1`), with `granted_by` = owner (admin fallback ownerless).
2. member-cap is granted to an AGENT member (agents carry `:identity` caps).
3. anon join grants the member-cap but NOT `Session.:send` (unconfirmed tier).
4. migration is idempotent: run twice, exactly one member-cap per (member, session);
   re-run skips already-held (no `:caps` slice churn).
5. `reconcile_after_load/2`: seed a session whose caps drift from its persisted
   `:members`, activate, assert projection heals to the authoritative cap set.

**A2 — delivery / presence / removal (the crux + blast radius)**
6. **Crux/perf-shape test:** delivery fan-out reads the projection (O(1) local
   read) and performs NO reverse cap scan per message — assert `handle_send` does
   not call the workspace enumeration (e.g. by asserting `Users.list_in_workspace`
   is not invoked during a send; a spy/telemetry probe). This is the invariant that
   fails if someone "simplifies" delivery into a reverse query.
7. delivery presents **no** receive cap (R1.1); the member's `:receive` chokepoint
   authorizes in-handler on its OWN held member-cap matching the source session
   (K1/R1.2); `member_receive_caps/1` is gone (grep-gate / no callers). (Held-cap
   deny-on-revoke is test 20; parity invariant is test 24.)
8. a non-member (no member-cap over S) is NOT delivered to (receive chokepoint
   denies) — proves membership==cap on the read side.
9. presence: `:DOWN` flips `online: false` but the member RETAINS the member-cap
   (still a member, offline) — proves presence is separated from membership.
10. leave revokes the member-cap (assert absent via `read_entity_caps/1`) and drops
    the projection entry; `{:member_left}` still broadcasts.
11. `remove_participant` fail-closed: a teardown-cap-denied removal leaves BOTH the
    member-cap AND the projection entry intact (atomic, §4.3).
12. UI roster (`member_options/1`) and read-authz (`socialware_publisher_read`) read
    the projection with unchanged shape — regression guard on blast radius.

**B — cascade**
13. **Motivating case (acceptance/E2E):** B pulls A's agent into S ⇒ member-cap
    granted to A's-agent ⇒ `slice_changed` on A's-agent ⇒ A receives a
    `:cascade_slice_change` notification. **A is notified.** The S3 done-gate.
14. **Removal-notify (the S1 gap, now closed):** A's agent is removed from S ⇒
    member-cap revoked on A's-agent ⇒ A is notified of the removal. (S1 could not
    do this.)
15. `managers_of(agent)` returns the creator (holds `CreatorGrant.manage_cap`); an
    unrelated-cap user is NOT returned; a `{:within_workspace, ws}`-scoped Manage cap
    IS returned (proves `matches?/2`, not naive equality); a different-workspace user
    is never returned (bounded scan).
16. provenance: a system-granted stale Manage cap does NOT over-match (`granted_by_entity?/1`
    filter, K4).
17. cascade uses LIVE caps: grant a Manage cap at runtime (mutating the live slice,
    not `caps_json`) then trigger a cascade — the new manager IS resolved (K5).
18. payload minimality: notification `body` is exactly `{entity_uri, slice_key,
    event_at, cursor}` — assert NO cap values / member list.
19. cascade hook fires from the post-commit `DeferredDispatch` turn, off the mutating
    dispatch's critical path (K3); a raising resolver does not roll back the mutation.

**R1 additions (held-cap authz + drift states — the security core)**
20. **Held-cap receive-authz (R1.1/R1.2):** a receive dispatch carries **no**
    member-cap in `ctx.caps` (assert absent); the recipient's `:receive` is
    authorized ONLY by its own held member-cap (matching `ctx.caller`); revoke the
    cap and the very next receive is DENIED — **without** running reconcile.
21. **Roster-vs-authz separation (R1.1):** with a member-cap revoked but the
    `:members` roster entry still present (simulate the projection-drop-failure
    window), delivery ATTEMPTS the recipient but the receive is DENIED — proves a
    stale roster is never authz.
22. **Socialware read held-cap (R1.1):** an ex-member whose member-cap is revoked
    but who is still in a stale `members` projection is DENIED
    `socialware_publisher_read` — proves read-authz reads the held cap, not the
    projection.
23. **Drift-state matrix (R1.3):** cap-only ⇒ reconcile adds roster;
    roster-only ⇒ receive denied + reconcile evicts; join role-conflict ⇒ NO
    orphaned cap (preflight); join failure after grant ⇒ compensating revoke leaves
    neither cap nor roster.
24. **Receive-authz parity invariant (R1.2):** every `{Kind, :receive}` behavior
    (User/Agent/HelloBuilder/HelloConcierge + any future) is `cap_exempt` for
    `:receive` AND routes through `MemberReceive.authorize/1` — a new receive
    behavior that skips the helper fails.
25. **Migration bounded (R1.5):** `mix ezagent.migrate.member_caps` on a seeded set
    scans only `kind_type == "session"` rows via keyset pages (assert no
    `list_all`), grants per member from the same decoded state, reports ownerless
    fallback count; `--dry-run` writes nothing; `--gate` exits nonzero pre-migration
    and zero post.
26. **Agent enumeration (R1.4):** `Entity.Agent.list_in_workspace/1` returns a
    DORMANT agent (snapshot-only, not live) and excludes users/other workspaces.

### 14.5 Acceptance E2E — the done-gate (NEW scenario)

This scenario **does not exist today**; it is the feature's end-to-end done-gate.
It proves the three properties the lead asked for. **Split by determinism:**

**(A) Security done-gate → ExUnit integration test** (deterministic; the immediate
deny must not depend on reconcile timing, which would flake in a browser test).
Lives at `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs`
(cross-app integration; the session domain owns membership + delivery). Steps:

1. **Cross-user add.** User **B** adds user **A**'s cc agent to B's session **S** —
   i.e. grants the member-cap `cap(:session, Session, :receive, instance: S)` to
   **A's-agent's** `:identity` slice.
2. **Cascade proof.** Assert **A receives a cascade notification** — the grant is a
   slice-change on A's-agent → `managers_of(A's-agent)` = the creator holding
   `CreatorGrant.manage_cap` = **A** → `Notifications.notify/2` to A (Part B / §9).
3. **Membership-as-cap delivery.** B posts in S; assert A's-agent's `:receive`
   fires (roster lists it AND it holds the member-cap → in-handler authz passes).
4. **Grant/revoke cascade to an arbitrary X.** Grant a member-cap to some entity X
   whose owner/manager is Y; assert Y is notified (and on revoke, Y is notified —
   the S1-gap-closed removal-notify).
5. **🔴 CRITICAL SECURITY PROOF (the done-gate).** B **removes** A's agent from S
   (revoke the member-cap). Assert A's-agent can **NO LONGER receive** in S — B
   posts again and A's-agent's `:receive` is DENIED — **proven WITHOUT running
   `reconcile_after_load/2`** (the test never re-activates the session; it asserts
   the in-handler held-cap check denies on the already-revoked cap). This is the
   security done-gate: revoke ⇒ immediate loss of receive, no reconcile wait, no
   bearer window.

**(B) Cross-user cascade UX → world-UI agent-browser scenario** in
`docs/scenarios/2026-07-04-member-cap-cascade.md` (project convention
`feedback_esr_e2e_standards`: an agent-browser screenshot gate for user-facing
flows). Drives the world UI: B opens S, adds A's cc agent via the roster/picker;
capture (1) the roster showing A's agent as a member, (2) A's notification surface
showing the cascade notice. This proves the human-visible cross-user path. The
**security deny** stays ExUnit-only (not UI-visible / timing-sensitive).

**Gate wording:** the feature is DONE when (A) passes in full — **especially step
5** — and (B)'s two screenshots are captured. Step 5 is the single load-bearing
assertion; if it cannot be made to pass without a reconcile, R1.1's roster/authz
separation is not actually implemented and the feature is not done.

---

## 15. Out of scope

- **S0 — delete legacy `Notifications.notify/3`.** Independent housekeeping.
- **The join ADMISSION authz gate.** Whether B is *allowed* to pull A's agent in is
  the grant/admission side (authorization). This spec is membership + the
  after-the-fact notification. **Note S3's relevance:** because join now *is* a
  cap grant, the admission gate becomes "who may grant the member-cap over S" — a
  natural future tightening, but the gate itself is out of scope here.
- **S2 — agent inboxes.** `Notifications.notify/2` raises for non-User URIs
  (`notifications.ex:192-205`); cascade recipients are filtered to Users. Notifying
  an AGENT (so an agent-manager gets a cascade) needs an agent-inbox primitive.
  **S3 does NOT change this** — it makes agent membership a first-class cap, but the
  notification sink is still User-only. This is *why* User-only resolution is
  correct, not a shortcut. Deferred.
- **Delta-precise / at-least-once cascade backfill.** Cascade is best-effort,
  at-most-once, advisory. Cursor-gap replay is a future reliability upgrade.
- **Maintained reverse cap-holder index (option (a)).** The future perf
  optimization if even the cold per-workspace scan becomes expensive.

---

## 16. Open risks (honest — what this spec could NOT fully close)

1. **K1 receive-authz — RESOLVED in R1.2 (was PROPOSED).** The in-handler /
   `cap_exempt` design is CONFIRMED against a proven precedent (socialware
   read-auth), not a runtime edit. Residual PROPOSED detail: whether **plugin
   agent Kinds carry a readable `:identity` sibling** (Users/Agents do; the four
   receive behaviors include `HelloBuilder`/`HelloConcierge`). If a plugin agent
   member has no `:identity` slice, `MemberReceive.authorize/1` must resolve its
   caps via `read_entity_caps/1` fallback rather than the pre-loaded sibling. The
   `ReceiveAuthzParityTest` surfaces any behavior that skips the helper; the plan
   must confirm each plugin receive's identity-slice availability in A2.
2. **Cold reverse-scan cost at very large workspaces.** `reconcile_after_load/2`
   and `managers_of/1` do a bounded per-workspace live-cap scan. Bounded ≠ cheap if
   a workspace has thousands of identities. Mitigation is option (a); flagged, not
   built. Delivery is unaffected (never scans).
3. **Agent enumeration — RESOLVED in R1.4.** `Ezagent.Entity.Agent.list_in_workspace/1`
   (snapshot scan modeled on `agent_role_resolver.ex:35-64`, live+dormant). Residual
   PROPOSED detail: the cross-app module placement so the reconcile caller
   (`ezagent_core`/`ezagent_domain_session`) references it without tripping
   `undeclared_umbrella_dep_test` — a plan-time seam choice, not a design gap.
4. **Behavior shift (§4.3, K6): failed member-cap grant ⇒ not a member.** A
   deliberate move from best-effort to fail-closed for the membership-defining cap.
   Cleaner, but a user-visible change (a transient grant failure now yields
   non-membership rather than a silent send-less member). Reconcile heals it on next
   activate, but the window exists. Called out for the lead's sign-off.
