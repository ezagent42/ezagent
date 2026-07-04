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
  > **⚠️ SUPERSEDED BY R2.3 — this enumeration is wrong; the truth is simpler.**
  > There are exactly **TWO** registered `{Kind, :receive}` behaviors (`User.Receive`,
  > `Agent.Receive`); dispatch is registry-first (`behavior_set.ex:262-272`).
  > `HelloBuilder`/`HelloConcierge` declare `caps: [:receive]` but are role behaviors
  > whose `:receive` **never runs** (`hello/bridge_adapter.ex:8-14`) — plugin agents
  > receive THROUGH `Agent.Receive`. So the shared authz goes at exactly 2 sites, not 4.
  > **See R2.3.**

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
> **⚠️ SUPERSEDED BY R2.1.** "revoke-first" is correct for self-LEAVE but **WRONG
> for REMOVE** — `remove_participant` has a fail-closed teardown BEFORE any mutation
> (`membership.ex:636-645`), so a revoke-first REMOVE would revoke the cap and then
> a teardown rejection would leave the member receive-denied while the removal
> FAILED. R2.1 splits this into THREE sequences (JOIN / LEAVE / REMOVE); for REMOVE
> the revoke is placed AFTER all fail-closed checks pass. **See R2.1.**
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

> **⚠️ WRITE MODEL SUPERSEDED BY R2.2.** The READ shape below (steps 1-3: keyset
> pagination, `where kind_type == "session"`, decode-once) is retained. But a
> **repo-only WRITE** mirroring `GrantMigration` is NOT live-safe — `GrantMigration`
> is explicitly stop-nodes / TEST-DB-only (`grant_migration.ex:31-42`) and a direct
> `kind_snapshots` write does not update a live in-memory `:identity` slice. R2.2
> keeps the repo-only READ but performs the WRITE via the **live grant path**
> (`grant_cap_via_router/4`), idempotent, so nodes may be running. **See R2.2.**

Original §8 read all sessions via `KindSnapshot.list_all` (loads every row) with a
live owner lookup. Replace with a paginated, snapshot-consistent **read** +
live-grant **write** migration — a `Ezagent.Session.MemberCapMigration` module behind
a `mix ezagent.migrate.member_caps` front door, mirroring the
`GrantMigration` + `ezagent.session.migrate_grants` split for the CLI shape
(`grant_migration.ex`, `ezagent.session.migrate_grants.ex`) — but NOT its repo-write
mechanism (R2.2):

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
   Idempotent (skip-already-held) + writes only via the live grant path (R2.2) ⇒
   safe on a running dev node — the writes go through the same
   `grant_cap_via_router/4` path a normal grant uses, keeping the in-memory slice and
   snapshot consistent (`feedback_destructive_migration_anti_pattern`). **The earlier
   "non-destructive repo write ⇒ safe on a live dev DB" claim is WITHDRAWN — a repo
   write is NOT live-safe; see R2.2.**

### R1.6 — Acceptance E2E (the done-gate) — see new §14.5

A NEW end-to-end scenario proving the whole feature. Defined in full in **§14.5**.
**Since R4 the PRIMARY assertion is PREVENTION** (a pending cross-owner add cannot
spend A's credential until A approves); the immediate-deny-after-revoke proof is
RETAINED as defense-in-depth (Phase A2's gate). Split: the security done-gate is an
**ExUnit integration test** (deterministic; no reconcile timing to flake); the
owner-approval-to-mount UX is a **world-UI agent-browser scenario in
`docs/scenarios/`** (project convention — `feedback_esr_e2e_standards`).

---

## R2 — Revision: codex round-2 fixes (2026-07-04)

Codex round-2 verdict: **NO-SHIP** — and it is right. R1's core is CONFIRMED sound
and is **NOT touched** here: roster⟂authz (R1.1), the bearer-token removal, the
single O(1) roster read, `cap_exempt`-preserves-workspace-isolation, the R1.4
snapshot-scan shape. R2 closes five **second-order lifecycle/sequencing** gaps R1
left open. **Precedence: R2 > R1 > original prose.** Where R2 contradicts an R1
sub-section or an original §, R2 is authoritative and the superseded lines are
patched inline to point here.

Each claim below is grounded in code read in this worktree, tagged **CONFIRMED**
(verified against the tree) or **PROPOSED** (design choice for the plan).

### R2.1 — 🔴 BLOCKER: REMOVE is NOT revoke-first — three distinct sequences (supersedes R1.3 LEAVE/REMOVE, §4.3, §8 removal)

> **⚠️ ORDERING SUPERSEDED BY R3.1.** R2.1's ordering — "preflight the fail-closed
> teardown/prune, revoke LAST, cap + roster + worker intact on any failure" — is
> **impossible**: the teardown destructively runs `sandbox.destroy` on its accept
> path *before* the revoke (`teardown.ex:90-94`), and the revoke is itself fallible
> (`grant.ex:107-110`). R3.1 reframes it: the teardown's **authority** half stays in
> the preflight (this is what still preserves test 11), but the **destructive** half
> moves to best-effort *after* a confirmed, abort-safe revoke. New order:
> `authority-preflight → revoke → best-effort destroy → roster-drop`. The
> code-grounded analysis below (destructive teardown, fallible revoke, test-11
> behavior) remains CONFIRMED and correct; only R2.1's *conclusion about ordering* is
> replaced. **See R3.1.**

**The bug in R1.3.** R1.3 wrote a single "LEAVE / REMOVE (revoke-first, roster-drop,
no authz window)" sequence. That is **wrong for REMOVE**. `remove_participant` runs a
**FALLIBLE, fail-closed teardown BEFORE any membership mutation**:
`do_remove_participant/3` calls the `:strict` worker reap
(`membership.ex:636-641`); a teardown-cap-denied removal returns `{:error, _}` with
**zero mutation — member keeps cap + monitor + roster** (`membership.ex:642-645`),
and the `:membership_only` branch additionally fail-closes on a routing-prune error
(`membership.ex:668-685`). The spec's own **test 11** requires exactly this: a
teardown-cap-denied removal leaves **BOTH the member-cap AND the projection entry
intact** (spec §14 test 11). **CONFIRMED.**

Under a naive "revoke-first" REMOVE, the member-cap would be revoked, then the
teardown could reject — leaving the member **receive-denied / roster-dropped while
the removal actually FAILED** (returns `{:error}`, roster untouched). That is a
security-relevant divergence between "cap says removed" and "removal rejected."

**JOIN and REMOVE are NOT symmetric.** Spell out **three** sequences:

**JOIN — grant-first, preflight, compensate (unchanged from R1.3, restated for
symmetry).**
1. Preflight `Members.role_name_conflict/3` (`membership.ex:48-50`) — zero side
   effects on conflict. CONFIRMED.
2. Grant the member-cap — idempotent skip-already-held via `already_authorized?/5`
   (`membership.ex:888`). CONFIRMED it exists.
3. `do_join_apply` → projection `{:set, :members, …}` (`membership.ex:127-135`).
4. Compensation: a commit failure AFTER the grant revokes the just-granted cap
   (de-escalating, no authz — `grant.ex:108`). **See R3.2 (post-commit replay/notify)
   for the pre-commit replay/notify hazard this compensation cannot undo.**

**LEAVE (self-leave) — no fallible follow-up → revoke-then-drop is safe.**
The self-leave path `leave_effects/2` has **NO fallible teardown/prune** — it is a
pure effect computation that demonitors immediately ("The `:leave` path has NO
fallible follow-up step" — `membership.ex:519`, body `525-529`). So revoke the
member-cap, then drop the projection. R1.1 means even a projection-drop failure has
no authz window. LEAVE keeps R1.3's ordering. **CONFIRMED.**

**REMOVE (`remove_participant`) — PREFLIGHT all fail-closed checks, revoke LAST,
then roster-drop.** The revoke is placed **after every check that can reject**, so a
rejected removal leaves cap + roster intact:
1. Authz gate `remove_participant_authorized?/3` (`membership.ex:602-603`). CONFIRMED.
2. Already-removed short-circuit (`membership.ex:605-606`). CONFIRMED.
3. **Fail-closed gate — run FIRST, before any revoke:** the `:strict` teardown reap
   (`membership.ex:636-641`). On `{:error}` return with **no revoke, cap + roster
   intact** (`membership.ex:642-645`). CONFIRMED existing behavior.
4. In the `{:ok, :membership_only}` branch, the routing prune is also fail-closed
   (`membership.ex:668-685`) — still **before any revoke**.
5. **Only after every rejecting check has passed, revoke the member-cap** (the
   final de-escalating, effectively-infallible step: revoke is idempotent /
   no-op-of-absent and needs no authz — `grant.ex:108`).
6. Return the leave effects → runtime drops the projection entry.

Net ordering for REMOVE: **[teardown authority + prune] → revoke → roster-drop.**
Invariant preserved (the correctness proof is test 11): a removal rejected at the
teardown/prune gate never reaches the revoke, so cap + roster are intact.

**Revoke-insertion mechanism — PROPOSED (plan detail; the sequence + invariant is
CONFIRMED).** Two ways to place the revoke after the gates:
- **(primary) inline synchronous** `Ezagent.Identity.Grant.revoke_cap_via_router/4`
  (`grant.ex:108` / `grant.ex:121` for the router form) called inside
  `do_remove_participant` after the teardown/prune succeed, before returning the
  leave effects. This yields the exact **"checks → revoke → drop"** order the fix
  asks for. Cross-Kind revoke from a handler is consistent with the existing at-join
  cross-Kind grant flow (§2.2); this is the cold removal path, never the hot
  delivery path, so the synchronous call is acceptable.
- **(alternative) a deferred `{:dispatch, revoke_cmd}` effect**
  (`Grant.revoke_cap_returning_effect/4`, `grant.ex:175`) appended to the leave
  effects. This still satisfies the **rejection invariant** (the effect is only
  emitted once the gates pass), but inverts intra-commit order to **drop-then-revoke**
  (the own-slice projection `{:set, :members}` commits before the deferred revoke
  runs). Per R1.1 that intra-commit order is **not** security-critical (authz reads
  the held cap, never the roster), so both are acceptable; **inline is primary**
  because it matches the finding's "revoke then roster-drop" ordering exactly.

**§14.5 step 5 (security done-gate) is unaffected.** REMOVE's end state is unchanged
— the member-cap ends **revoked** — so step 5's "B removes A's agent ⇒ immediate
receive-deny, no reconcile" still holds: the removal goes through the teardown path,
the revoke lands (step 5 above), and R1.1's held-cap check denies the next receive.

### R2.2 — 🟠 HIGH: migration enumerates via repo (paginated read), mutates via the LIVE grant path (supersedes R1.5 write model + the "safe on a live dev DB" claim in R1.5/§8)

> **⚠️ MECHANISM DEMOTED BY R3.2.** Round-3 flagged R2.2's naming of the idempotency
> predicate (step 3) and the sync-grant flag (step 2) as over-specified — the wrong
> predicate/flag was cited. The two *requirements* those steps were reaching for
> survive as implementation constraints + acceptance tests in **R3.2** (idempotency
> keyed on the exact member-cap identity; synchronous confirmed grants counted only on
> committed `:ok`). The enumerate-via-repo / mutate-via-live-grant *shape* of R2.2
> stands; the specific predicate/flag naming does not — the implementer picks it. **See
> R3.2.**

**The contradiction in R1.5.** R1.5 wanted the migration to be BOTH a repo-only
write AND safe to run on live nodes. It cannot be both. The `GrantMigration`
precedent it modeled on is explicitly **stop-nodes, TEST/sandbox-DB-only**: "Run
alongside … in the same ordered cutover (**stop nodes → deploy → migrate → start**)"
and "**TEST / sandbox DB only** here. Do NOT run against a live/dev/prod node"
(`grant_migration.ex:31-42`). It writes `users.caps_json` + the `:identity` snapshot
**directly** (`grant_migration.ex:13-17`). A direct `kind_snapshots` write does **not**
update a live node's in-memory `:identity` slice; a later `:on_change` snapshot
overwrites the migrated caps. **CONFIRMED** — the R1.5 "Idempotent + non-destructive
⇒ safe on a live dev DB" line is false as written and is **deleted** (see patch to
R1.5 step 6 and §8).

**Resolution (reconciles R1's "bound the scan" with R2's "don't repo-write"):
enumerate via repo, mutate via live grant.**
1. **Enumerate via a repo-only PAGINATED READ** (unchanged shape from R1.5 steps
   1-3): keyset pagination over `KindSnapshot` `where: s.kind_type == "session"`,
   `order_by: s.uri`, `where: s.uri > ^last_uri`, `limit: @page`; **decode once** per
   row via `KindSnapshot.decode_state/1` and read BOTH `members` AND `owner_uri`
   from the **same decoded persisted state**. This is a pure READ; nodes may be
   running. CONFIRMED the decode/keyset primitives exist (R1.5 cites
   `kind_snapshot.ex`).
2. **Mutate via the LIVE grant path, not a repo write.** For each `(member, session)`
   pair, dispatch the real grant through
   `Ezagent.Identity.Grant.grant_cap_via_router/4` (`grant.ex:121-141` → `:grant_cap`
   dispatched via `Router.dispatch` to the member's identity Kind), which updates the
   **live in-memory slice AND the snapshot** consistently. **CONFIRMED path.**
3. **Idempotent by skip-already-held** via `already_authorized?/5` (`membership.ex:888`)
   so a re-run is a no-op and the live snapshot is never churned. CONFIRMED.
4. **Ownerless #154 fallback** (admin granter), **logged + counted**; `granted_by =
   owner_uri` otherwise — unchanged from R1.5 step 4.
5. **Operator flags unchanged:** `--dry-run` (report only, no grants), `--gate`
   (nonzero exit if any session lacks member-caps), report
   `{sessions_scanned, members_granted, skipped_already_held, ownerless_fallback}`.

**Stated explicitly (drop any repo-write claim): enumerate via repo, mutate via live
grant. Nodes may be running.** Because the write is the idempotent live grant path
(not a raw snapshot write), the migration is genuinely safe on a running dev node —
which is what R1.5 wanted but could not get from a direct repo write. Test 25 (spec
§14, lines 1012-1016) is updated accordingly (see patch): assert keyset enumeration
(no `list_all`) AND that grants go through the router grant path, not a snapshot write.

### R2.3 — 🟠 HIGH: there are exactly TWO receive entry points — the surface SIMPLIFIES (supersedes R1.2 "≥4 receive behaviors", K1, test 24, and §16 risk 1)

**R1.2's enumeration was wrong; the truth is simpler.** The `{Kind, :receive}`
registry has **exactly two** entries, and dispatch is registry-first:
- `{User, :receive}` → `Ezagent.ActionSet.User.Receive`
  (`session_behavior_registration.ex:50`). CONFIRMED.
- `{Agent, :receive}` → `Ezagent.ActionSet.Agent.Receive`
  (`ezagent_domain_agent/application.ex:51`). CONFIRMED.
- `resolve_action/3` is **registry-first** (`behavior_set.ex:262-272`): a registered
  `{Kind, action}` always resolves to its canonical module; only a genuinely
  unregistered action falls back to a per-instance loaded behavior. CONFIRMED.

`HelloBuilder` / `HelloConcierge` declare `caps: [:receive]` (`hello_builder.ex:35`,
`hello_concierge.ex:25`) but those `:receive` handlers **never run**: they are
**role behaviors** on the `:agent` axis, and on the unified `Entity.Agent` "`:receive`
… is hardwired to `Ezagent.ActionSet.Agent.Receive` … a role behavior's own
`:receive` never runs" (`hello/bridge_adapter.ex:8-14`; `hello_builder.ex:42-44`).
Hello/plugin agents receive **through** `Agent.Receive`, which hands down to the
per-flavor bridge adapter. So R1.2's "≥4 receive behaviors, edit each" was chasing
unreachable handlers. **CONFIRMED — this is a genuine simplification: 4 → 2.**

**The corrected, simpler contract:**
1. Place the shared `Ezagent.Session.MemberReceive.authorize/1` call at the **two
   real entry points only**: `User.Receive` and `Agent.Receive`.
2. **At `Agent.Receive`, the hook sits BEFORE the bridge-adapter short-circuit.**
   `Agent.Receive.handle_receive/2` is the **single entry for ALL agent flavors**
   (cc / codex / hello / curl / native). The bridge short-circuit is the
   `Delivery.deliver_agent_receive(msg, ctx)` call at `receive.ex:210`. Placing
   `MemberReceive.authorize/1` at the top of `handle_receive/2` — before that call
   (the self-message loop-guard at `receive.ex:195-205` is a minor plan-detail;
   "before the bridge call" is the invariant, not "before the guard") — gates **every
   plugin agent** through one site. A plugin agent physically **cannot** skip it,
   because there is no separate plugin `{Kind, :receive}` to bypass through. CONFIRMED.
3. `reads_siblings([:sandbox])` at `receive.ex:80` becomes
   `reads_siblings([:sandbox, :identity])` so `MemberReceive.authorize/1` reads the
   recipient's own held caps from the pre-loaded `ctx[:siblings][:identity]` — no
   `GenServer.call`, no self-slice deadlock. CONFIRMED the sibling pre-load mechanism.
4. **`ReceiveAuthzParityTest` enumerates the ACTUAL registered `{Kind, :receive}`
   behaviors** (from the `BehaviorRegistry`, dynamically) and asserts each is
   `cap_exempt` for `:receive` AND routes through `MemberReceive.authorize/1`. It does
   **NOT** attempt to cover the unreachable `HelloBuilder`/`HelloConcierge` role
   `:receive` handlers. Because it reads the registry, a future Kind that registers a
   real `{Kind, :receive}` is caught automatically. Test 24 (spec §14, lines
   1008-1011) is updated accordingly (see patch).

**This dissolves §16 open-risk 1's residual A2.** That residual asked "whether plugin
agent Kinds carry a readable `:identity` sibling." There is **no separate plugin agent
Kind** — every flavor is `Entity.Agent`, which carries `:identity` caps (§2.8: "Agents
carry `:identity` caps too"). So `reads_siblings([:sandbox, :identity])` at the single
`Agent.Receive` entry covers **every** plugin agent, and the "does the plugin Kind have
an `:identity` slice" question is moot. §16 risk 1 is marked **RESOLVED** (see patch).

### R2.4 — 🟡 MED: JOIN's pre-commit replay + notify cannot be compensated (supersedes R1.3 JOIN compensation, closing the leak)

**The gap.** R1.3's JOIN compensation ("a failed `do_join` AFTER the grant revokes
the just-granted cap") cannot undo side effects `do_join_apply` runs **before it
returns its effects**: `Delivery.replay_messages_since/3` (`membership.ex:95`) and
`Ezagent.Notifications.notify/2` (`membership.ex:115-125`) both execute inline,
pre-commit. A compensating revoke can't un-replay a re-delivered message or un-send a
"you joined" notification. **CONFIRMED.**

**Resolution — DEMOTED to R3.2 (post-commit replay/notify as an implementation
constraint).** Round-3 read R2.4's earlier "(acceptable fallback) bound the one-replay
leak" branch as a *documented leak, not a closure* — so it is **DELETED**. The
requirement is now singular and unconditional: replay + notify run **post-commit**,
after BOTH the grant and the join commit, so a pre-commit failure has nothing to
un-replay/un-notify and no replay reaches a member whose join never committed. The
exact effect grammar (deferred dispatch vs inline) is the implementer's choice against
the compiler — R3 does not name it. **See R3.2 (post-commit replay/notify) for the
requirement + acceptance test.**

### R2.5 — 🟢 LOW: delete the stale bearer-token prose in §4.2 (finding #5)

§4.2 point 1 still says the member "holds one standing member-cap; delivery presents
the cached copy" (spec lines 563-567) — the exact **bearer-token wording R1.1
removed**. A writing-plan reading §4.2 in isolation could re-implement it. This is
**deleted / rewritten** to the roster⟂authz model (see patch): delivery presents **no**
receive cap; the receive *authority* is the recipient's own held member-cap, checked
in-handler (R1.1/R1.2). CONFIRMED as a pure prose fix — the correct model already
lives in R1.1/§6.

### R2.6 — carried R1 items CONFIRMED sound, NOT re-litigated

R1.1 core (delete `member_receive_caps/1`, `:receive` `cap_exempt`,
`cap_exempt`-preserves-workspace-isolation), the single `:receive` dispatch site, and
the R1.4 snapshot-scan shape (the session app already deps `ezagent_domain_agent`, so
the placement is fine unless moved to core/identity) are **confirmed sound by codex
round-2 and unchanged by R2.**

---

## R3 — Revision: codex round-3 fixes (2026-07-04)

Codex round-3 confirmed the architecture SOUND — R1.1 core (roster⟂authz) and R2.3
(two receive entry points) are NOT re-litigated and are NOT touched here. R3 does
exactly two things: **(1)** applies the one real design fix round-3 found — the REMOVE
invariant as stated in R2.1 is *impossible*, so it is reframed (R3.1); and **(2)**
DEMOTES two over-specified R2 items to *implementation constraints + acceptance
tests* (R3.2), stating WHAT MUST HOLD and the test that proves it, WITHOUT re-naming a
predicate/flag/API (re-specifying mechanism is precisely what stalled rounds 2–3).
**Precedence: R3 > R2 > R1 > original prose.**

Each claim is tagged **CONFIRMED** (verified against this worktree) or **PROPOSED**
(design choice for the plan).

### R3.1 — 🔴 BLOCKER: the REMOVE invariant in R2.1 is impossible — reframe it (supersedes R2.1's ordering, §4.3 removal ordering, §8 removal, §11 K6, §12, §13)

**Why R2.1 cannot hold.** R2.1 read `teardown_participant_resources/4` as a pure,
fail-closed *authority preflight* and concluded REMOVE could "preflight all checks,
revoke LAST, and leave cap + roster + worker intact on ANY failure." That is false:
the teardown is **not** a pure permission check — it **destructively dispatches
`sandbox.destroy` (irreversible worker termination)** on the accept path.
`teardown_participant_resources/4` → `reap_spawned_worker/3` calls
`owner_destroy_dispatch` and only *then* returns `{:ok, :worker}`
(`teardown.ex:90-94`; the destroy + `config_dir` GC is documented at
`teardown.ex:75-87`); it is invoked from the `:strict` remove path
(`membership.ex:636-641`). And the revoke itself is **fallible**: `revoke_cap/3`
returns `:ok | {:error, reason}` (`grant.ex:107-110`) and the commit can fail
(`{:persistence_failed}`, `server.ex:620-630`). So on the accept path the worker is
**already destroyed BEFORE the revoke runs**, and the revoke can then fail — which
leaves *worker-dead + cap-held*. "Atomic remove; cap + roster + worker all intact on
any failure" is therefore unachievable. **CONFIRMED** (fused destroy-before-revoke:
`teardown.ex:90-94`; revoke fallible: `grant.ex:107-110`; commit fallible:
`server.ex:620-630`).

**The reframed REMOVE invariant (PROPOSED design; dissolves BOTH round-2's
"revoke-first vs fail-closed teardown" AND round-3's "teardown is destructive" in one
move).** Split the teardown's two fused concerns onto opposite sides of the revoke:

- **teardown-AUTHORITY = a preflight** — a *pure permission check* (may this remover
  tear this participant down?). On reject: **everything intact, zero mutation** (no
  destroy, no revoke, no roster-drop). The current code **MIXES authority +
  destruction** inside `teardown_participant_resources/4`; the requirement is that the
  **authority check is separated OUT as a preflight** — the exact extraction (which
  lines, what the pure check is named) is left to the implementer. This is what
  **preserves test 11**: a teardown-cap-**denied** removal aborts *in the preflight,
  before the revoke*, so cap + roster stay intact — exactly test 11's assertion.
  (Authority/execution split: **PROPOSED**; currently fused: **CONFIRMED**.)
- **security-critical member-cap REVOKE = synchronous, checked, ABORT-SAFE.** If the
  revoke fails, the removal **ABORTS and the member is left FULLY INTACT** — a loud
  error, never a silent partial proceed. This is let-it-crash aligned (Allen's hard
  constraint: no silent partial state). The requirement is "synchronous + checked +
  abort-on-failure"; do NOT prescribe a specific revoke-effect API. (Requirement:
  **PROPOSED**; that revoke *can* fail and so MUST be checked: **CONFIRMED**,
  `grant.ex:107-110`.)
- **destructive teardown (`sandbox.destroy`) + roster-drop = best-effort, AFTER a
  confirmed revoke,** with an explicitly-DEFINED lingering end-state. Once the cap is
  revoked the member is **SECURE — it cannot receive** (R1.1: authz reads the held
  cap, not the roster). A subsequently-failed worker-destroy or roster-drop is a
  **RESOURCE leak, reconciled later — NOT a security regression.** Named reconcile
  paths: a lingering **roster** entry whose backing cap is absent is dropped by
  `reconcile_after_load/2` on next activate ("caps win", §4.3 / §13 — the coherence
  spine, invariant #20); a lingering **worker** (revoke ok, `sandbox.destroy` failed)
  is a **bounded** leak GC'd at session teardown via the best-effort
  `cascade_teardown` reap plus the dead-orchestrator / junk-session
  `Lifecycle.destroy` safety net (`teardown.ex:82-85, 120-150`) — there is no
  continuous reaper, and R3 does not invent one.

**Explicit ordering:** `authority-preflight → (confirmed) revoke → best-effort
destructive teardown → roster-drop`. (Note this INVERTS R2.1, which placed the
destructive teardown *before* the revoke; the destruction now moves *after* a
confirmed revoke, and only the *authority* half stays in the preflight.)

**§14.5 alignment (make it explicit).** The security done-gate (§14.5 step 5) asserts
**revoke-happened → member cannot receive**, NOT worker-destroyed. So this reframed
invariant is *exactly* what the done-gate already proves: the load-bearing property is
the confirmed revoke (immediate receive-deny, no reconcile wait), and the destructive
teardown is deliberately out of the security assertion. The reframe and the done-gate
are the same claim. (§14.5 needs no assertion change — only a pointer note to R3.1.)

### R3.2 — Implementation Constraints + Acceptance Tests (demotes R2.2 migration + R2.4 replay/notify from mechanism to requirement)

Round-3 flagged three items in R2 as *over-specified* — they named the wrong
predicate/flag/effect-grammar as the mechanism, which is what broke rounds 2–3. They
are demoted here to **what must hold + the test that proves it, one sentence each**.
The implementer picks the mechanism against the compiler; the spec does not.

- **Migration idempotency** (round-3 HIGH; demotes R2.2 step 3). *Requirement:* the
  migration keys on the **exact member-cap identity**, not on general authorization —
  so a session whose owner already holds a broad `:any` cap **still gets its concrete
  member-cap written**. *Test:* a session under an all-`:any` admin cap still receives
  its concrete member-cap after migration.
- **Migration grant confirmation** (round-3 HIGH; demotes R2.2 step 2). *Requirement:*
  the migration uses **synchronous, CONFIRMED grants and counts only committed `:ok`
  results**. *Test:* a grant whose commit fails is NOT counted as migrated.
- **Post-commit replay / notify** (round-3 MED; supersedes R2.4). *Requirement:*
  replay and notify run **POST-COMMIT — after BOTH the grant and the join have
  committed**; no replay fires to a member whose join has not committed. *Test:* a
  join that fails after the grant produces NO replay/notify to that member. (This
  DELETES R2.4's "acceptable fallback / bound the one-replay leak" text — round-3
  correctly read that as a *documented leak*, not a closure. Post-commit ordering is
  now the requirement, not one option among two.)

---

## R4 — Revision: admission gate IN SCOPE (lead decision, 2026-07-04)

**What changed and why.** As shipped through R3 this spec delivered
membership-cap + cascade-notify + revoke-on-remove = **DETECT + REACT**, and
**explicitly deferred the join ADMISSION gate to §15 out-of-scope**. That left the
motivating threat **X still open**: co-tenant **B can pull user A's CREDENTIALED
agent into B's session and spend A's credentials (OAuth) running B's prompts,
silently** — the cascade would merely *notify* A *after* the agent was already
mounted and already receiving. Notify-after-mount is not prevention.

**The lead's decision — owner-approval-to-mount.** "B can *request* to pull A's
agent in, but it requires the OWNER's approval to actually mount." This closes X by
**PREVENTION**, as an **ADDITIVE layer** on the S3 membership-cap model — it invents
almost no new mechanism, it **composes the pieces R1–R3 already built**:

- A cross-owner add (caller lacks manage-authority over the member) no longer
  grants the member-cap; it records a **PENDING** request and does **NOT** mount.
- Because no member-cap is held, **R1.1 (receive reads the HELD cap)** means the
  pending agent **cannot receive → B's message never runs → A's credential is never
  spent.** The security property falls out **for free** — no new authz path.
- The owner (A) is notified via the **Part B cascade machinery** (`managers_of/1` +
  content-free notify), now with the **pending member as the subject**.
- Approve = the **exact R3.1 abort-safe synchronous grant** that join already
  performs. Nothing new on the grant path.

**Where this lands:** the design is **Part C** (new, below, in scope); §14.5's
**primary** done-gate assertion is **rewritten to PREVENTION** (pending-cannot-receive
+ approve-mounts); the old revoke→immediate-deny assertion is **RETAINED as
defense-in-depth** and remains A2's done-gate. §15 no longer defers admission.
**Precedence: R4 > R3 > R2 > R1 > prose** for the admission gate; R4 does **not**
touch R1.1/R2.3/R3.1 (it depends on them unchanged).

Each claim is tagged **CONFIRMED** (verified against this worktree) or **PROPOSED**
(design choice for the plan). The reused primitives —
`provision_invited_join_authority/3` (`membership.ex:393`, **one** of several
member-add paths, NOT the only one — see §C.1: the gate sits at the common
`handle_join` chokepoint, not this function), `CreatorGrant.manage_cap/4`
(`creator_grant.ex:20`) — are **CONFIRMED on main**; `Ezagent.Identity.Authority.manages?/2` + `managers_of/1` are **PLANNED**
(K2/Part B, B.1/B.2); `:pending_members` + the approve/deny/withdraw actions are
**NEW**; "R1.1 gives prevention for free" is **CONFIRMED-by-design once A2 lands**.

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
   holds one standing member-cap; **delivery presents NO receive cap — the receive
   authority is the recipient's OWN held member-cap, checked in-handler (R1.1/R1.2).**
   (The original wording here — "delivery presents the cached copy" — was the
   bearer-token design R1.1 removed and is corrected per R2.5.) Fewer allocations,
   and — decisively — the receive *authority* is now a durable, revocable, queryable
   fact instead of an implicit consequence of list membership.
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
  cap** (so a role conflict / monitor failure never orphans a cap). For removal the
  ordering is NOT symmetric: **self-LEAVE** revokes then drops (no fallible
  follow-up), but **REMOVE** runs a pure teardown-**authority** preflight, then a
  confirmed abort-safe revoke, then best-effort destructive teardown, then roster-drop
  (**R3.1 supersedes R2.1's "revoke LAST after the destructive teardown" ordering** —
  the destructive `sandbox.destroy` runs *after* the revoke, not before; only the
  authority half stays in the preflight, which preserves test 11). This mirrors the
  existing
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
- **Removal.** `:leave` and `:remove_participant` revoke the member-cap, plus the
  existing routing-prune / worker-teardown. **Ordering per R3.1 (NOT uniform
  "revoke-first"):** self-`:leave` revokes then drops the projection (no fallible
  follow-up); `:remove_participant` runs the pure teardown-**authority** preflight
  (reject ⇒ cap + roster intact, test 11), then a confirmed abort-safe revoke (revoke
  fails ⇒ removal ABORTS, member fully intact), then best-effort destructive teardown
  (`sandbox.destroy`) + roster-drop — a post-revoke destroy/drop failure is a resource
  leak reconciled later (`reconcile_after_load/2` / session-teardown reap), never a
  security regression. The `{:member_left}` broadcast still fires (convergence). Because
  revoke mutates the LEAVER's own `:identity` slice, removal now produces a
  slice-change on the leaver — which is exactly what closes the S1 removal-notify
  gap (§9, §11).
- **Migration** of existing sessions (`:members` rows → member-cap grants). A
  one-shot, **idempotent, bounded, paginated** migration task
  `mix ezagent.migrate.member_caps` — fully specified in **R1.5 as revised by R2.2**
  (repo-only paginated READ `where kind_type == "session"` + keyset; decode once and
  read `members` + `owner_uri` from the SAME persisted state; **WRITE via the live
  grant path `grant_cap_via_router/4`, not a repo write** — R2.2; ownerless #154
  fallback logged + counted; `--dry-run` / `--gate` / report). Supersedes the original
  `KindSnapshot.list_all` + live-owner-lookup sketch. The `:members` projection
  rows are kept as-is (they become the roster cache); `reconcile_after_load/2`
  (§4.3) is the steady-state backstop, the task is the initial seed. Idempotent
  (skip-already-held) + live-grant write ⇒ safe on a **running** dev node (R2.2)
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

## Part C — Admission gate: owner-approval-to-mount (R4, PREVENTS X)

**In scope (R4).** Parts A+B make membership a revocable cap and notify managers on
cap-change — that is DETECT+REACT. Part C adds the **PREVENTION** the lead asked for:
a cross-owner add does not mount until the member's owner approves. It is a thin
ADDITIVE layer — it **reuses** R1.1 (held-cap receive-authz), Part B (`managers_of/1`
+ content-free notify), R3.1 (the abort-safe grant), and K2's manage-authority
predicate. What is genuinely new is small (§C.6).

**Distinct from §15's old "who may grant" sketch.** §15 framed the deferred gate as
"*who may grant* the member-cap over S" — a hard allow/deny on the add itself. R4 is
**more permissive and safer**: **B MAY request** the add (no hard deny at B's
boundary), but the add **does not mount** until A approves. The authority to *spend
A's credential* stays with A; B gets a request, not a grant.

### C.1 — The trigger: EVERY member-add path routes a cross-owner add through admission

**The invariant (state it at this altitude):** *any caller-initiated grant of a
member-cap to a member the caller does NOT manage must route through admission.*
Everything else mounts immediately, unchanged.

> **🔴 CORRECTION (completeness review, 2026-07-04): the trigger was scoped too
> narrowly and the PRIMARY user-facing path bypassed it.** The pre-correction text
> scoped the gate to `provision_invited_join_authority/3` (`membership.ex:393`, the
> orchestrator invite-authority path) and asserted "the invite path is the only
> granter-≠-manager mount path." **That is false.** A review found **two** other ways a
> non-managing B gets a member onto A's agent, one of which is the primary attack
> surface. A single-function scope UNDER-FIRES. The trigger must be stated as a
> **requirement over ALL member-add entry paths**, checked at the **common chokepoint**
> they funnel through — NOT at one invite function.

**The two bypass paths the review found:**

1. **🔴 BLOCKER — World `invite_member/3` (the world-UI invite button) bypasses
   `provision_invited_join_authority/3` entirely (CONFIRMED).**
   `Ezagent.World.ConversationActions.invite_member/3`
   (`conversation_actions.ex:395-427`) reads B's own identity + caps
   (`caller = socket.assigns.current_entity_uri`, `caps = …current_caps`, `:396-397`),
   **directly dispatches `session.join` for an arbitrary `member_uri`** using B's
   existing `:join` cap (`:408-413`), and on success calls
   `Membership.mount_participation_caps/2` (`:417`). It **NEVER** calls
   `provision_invited_join_authority/3`. And `handle_join/2` (`session.ex:588`,
   CONFIRMED) checks only registry liveness + membership/monitor state (online / stale
   ref) — **NOT owner/manage authority**. So the scoped trigger completely misses the
   real world-UI invite. This is the primary real attack surface.
2. **🟠 Cross-session routing (`delivery.ex:88`) — COVERED-BY-R1.1, NOT a bypass
   (CONFIRMED).** `dispatch_cross_session_call/3`
   (`session/delivery.ex:71-107`) same-workspace-forwards a message by injecting an
   inline cap into the target session. Verified: `cross_session_send_caps/2`
   (`session/delivery.ex:284-298`) mints **exactly one `session.:send` cap** on the
   target session — **it confers SEND only, never a member-cap / `:receive`, and never
   touches `:members`.** So a non-member A-agent in the target session still **cannot
   RECEIVE** the forwarded message: R1.1 (receive reads the recipient's OWN held
   member-cap) DENIES, so A's credential is not spent. This path is already gated by
   R1.1 — no new admission logic needed, but it earns a regression test (§14 test 34).

**The requirement (verbatim — this is the corrected trigger):**

> **EVERY path that adds a member to a session — World `invite_member/3`,
> `provision_invited_join_authority/3` (the orchestrator invite-authority path), the
> materializer's member-join, and any direct `session.join` / `handle_join` caller —
> MUST route a CROSS-OWNER add (a real, non-system caller who does NOT hold
> `Authority.manages?(caller, member)` over the member, and is not the member itself)
> through admission (PENDING + owner-approval). The check belongs at the COMMON
> chokepoint all these funnel through — the member-cap grant seam in `do_join_apply`,
> reached by `handle_join/2` (`session.ex:588`) from every entry path — keyed on
> `ctx.caller`, NOT at one specific invite function. The implementer MUST verify the
> chosen chokepoint is downstream of ALL member-add entry paths.**

**Why `handle_join/2` is the chokepoint (CONFIRMED downstream of all four dispatchers).**
Every runtime member-add funnels through a `session.join` dispatch → `handle_join/2` →
`Membership.do_join/…` (the grant seam Part A folds the member-cap into):

- World `invite_member/3` → `session.join` dispatch (`conversation_actions.ex:408`),
  `ctx.caller = B` (the inviter). **CONFIRMED.**
- Orchestrator `admit_participant` → `Tools.join_member/5` → `session.join` dispatch
  (`tools.ex:330-337`), `ctx.caller` = the initiating caller. **CONFIRMED.** (This is
  the path `provision_invited_join_authority/3` preflights — but the *mount* still runs
  through `handle_join`, so the gate at the chokepoint covers it too.)
- World `self_join/2` → `session.join` dispatch (`conversation_actions.ex:504-510`),
  `ctx.caller == member`. **CONFIRMED.**
- Materializer member-join → `session.join` dispatch
  (`session_creator/materializer.ex:185-212`), `ctx.caller = admin_uri`. **CONFIRMED.**

At `handle_join`, `ctx.caller` **IS** the inviter for the world path — so the old
"thread `inviter_uri` from `provision_invited_join_authority` to the grant seam"
concern is DISSOLVED: the caller is already in scope at the chokepoint. (The check
must sit on the paths that reach the grant seam, i.e. AFTER the idempotent-rejoin
early-return at `session.ex:630-642`, so a live member's rejoin is never spuriously
pended.)

**The predicate — the ONE gate, keyed on `ctx.caller`:** *fire PENDING iff `ctx.caller`
is a real, non-system entity that is **not** the member and does **not** hold
`Authority.manages?(ctx.caller, member)`.* `manages?/2` (K2 / B.1) := caller holds a
`Manage`-over-member cap OR is a workspace admin — resolving the caller's **durable
identity caps by URI** (backed by `CreatorGrant.manage_cap/4`, `creator_grant.ex:20`,
CONFIRMED: minted into the creator's identity at entity-create, so
`manages?(A, A's-agent)` is true). Everything else mounts immediately.

**The over-fire exemptions (re-verified at the `handle_join` chokepoint — all still
mount, do NOT pend):**

- **(a) caller MANAGES the member** — owner-adds-own-agent (`manages?(A, A's-agent)`,
  CONFIRMED) / workspace admin. Mount.
- **(b) self-join / anon self-admission** — `ctx.caller == member` (CONFIRMED anon
  self-admission sets `caller: anon_uri`, `anon_admission.ex:107`; world `self_join`
  passes `caller == member`, `conversation_actions.ex:508-509`). Mount.
- **(c) system / orchestrator / team-template spawn (materializer).** ⚠️ **CORRECTED:**
  `system://session-internal` was **ELIMINATED** (#154 genesis collapse) — the stale
  "runs under `system://session-internal`" claim is WRONG. The materializer now
  dispatches the member-join under **`ctx.caller = Ezagent.Entity.User.admin_uri()`**
  with a narrow inline `session.:join` cap (`materializer.ex:182-212`, CONFIRMED). Its
  exemption therefore rests **entirely on `manages?(admin_uri, member) = true`** (the
  workspace-admin branch of the K2 predicate). ⚠️ **PROPOSED — implementer MUST verify:**
  `manages?/2` must resolve the caller's **durable identity caps by URI**, not
  `ctx.caps` — the materializer's `ctx.caps` carries only the narrow inline join cap,
  NOT the admin genesis wildcard (`materializer.ex:196-208`), so a predicate that read
  `ctx.caps` would return `false` and **relocate the over-fire** (every team-template
  spawn stalls at PENDING forever). `admin_uri` holds the genesis all-caps wildcard on
  its **identity** (`user.ex:89`, `admin_genesis_cap/0`), which satisfies
  `holds_workspace_admin_cap?/2` (`identity.ex:858-881`, CONFIRMED private predicate
  K2 surfaces) **when read from the caller's identity**. The over-fire guard test
  (§14 test 27) pins this: a **materializer / admin-caller add MOUNTS, not pends**.

> **⚠️ Do NOT put a bare `manages?(caller, member)` check that ignores the
> not-self / non-system carve-outs, and do NOT read `manages?` off `ctx.caps`.** A
> materializer add's `ctx.caps` holds only a narrow inline join cap (not the admin
> wildcard) → a `ctx.caps`-based check would pend **every team-template spawn** forever.
> `manages?` MUST resolve the caller's durable identity caps by URI. The gate keys on
> **a real non-system caller who is neither the member nor a manager of the member**,
> at the grant seam reached from every entry path — NOT on one invite function (which
> misses the world-UI invite, §C.1 bypass 1).

The gate withholds the **member-cap (`:receive`)** only. It is **orthogonal to the
existing join-cap provisioning** (`provision_invited_join_authority` may still grant
the `:join` cap / preflight invite authority at B's boundary) — do not conflate the
two layers: invite-authority answers "may B initiate an add?"; the admission gate
answers "does that add mount now, or wait for A?".

**Scope note — NOT caller-initiated adds (do NOT pend):** the migration task (A1.4)
and `reconcile_after_load/2` seed member-caps under **system authority**, not a caller
adding a member. These are outside "a caller adds a member" and MUST NOT route through
admission (they carry no real non-system inviter and would otherwise stall).

*(Plan-time seam, PROPOSED: the gate sits at the **member-cap grant seam** in
`do_join_apply` (A1.2), reached by `handle_join/2` from all four entry paths, keyed on
`ctx.caller` (already in scope — no `inviter_uri` threading needed). This is placement,
not a design gap.)*

### C.2 — Pending state: recorded, NOT mounted, holds NO member-cap

A cross-owner add records a **pending admission request** in a **`:pending_members`
map on the session's `:session` slice, DISTINCT from `:members`** (PROPOSED shape;
persistent, so a pending request survives a restart and is never silently lost):

```
:pending_members := %{ member_uri => %{
    requested_by:  inviter_uri,     # B
    requested_at:  DateTime,
    request_ref:   <opaque handle>  # what A approves/denies
} }
```

- **NO member-cap is granted** and **NO `:members` projection entry** is created. The
  pending member is not mounted on either axis.
- **Security falls out of R1.1 for free (CONFIRMED-by-design once A2 lands).** Because
  the pending member holds **no member-cap**, its `:receive` chokepoint (R1.2:
  `MemberReceive.authorize/1` reads the recipient's OWN held cap and matches
  `ctx.caller`) **DENIES** — so **B's message never reaches A's agent, A's agent never
  runs, and A's credential (OAuth) is never spent.** This requires **no new authz
  path**: it is precisely R1.1's "receive reads the held cap, roster is not authority."
- **Double barrier, one authority.** The pending member is also absent from `:members`,
  so the delivery ROSTER never even attempts delivery — but that is a *consequence* of
  not-mounting, not the security boundary. The **load-bearing** guarantee is the
  held-cap check (R1.1): even a hand-forged delivery attempt to a pending member is
  denied. Roster-absence and cap-absence agree, exactly as roster⟂authz intends.

### C.3 — Notify the owner: the cascade machinery, pending member as SUBJECT

The owner A is notified using **Part B's machinery** — `managers_of/1` +
content-free notify — but note the **cascade-subject requirement** (this is the one
non-obvious wiring point):

- **Requirement (pin):** a pending request notifies **`managers_of(pending_member)`
  = A** — the managers of the MEMBER, content-free, with an **approvable-request
  envelope** identifying `{pending_member, session, request_ref}` (enough for A to
  act; no message body, no cap values — same content-free discipline as the
  `slice_changed` envelope). It must **NOT** notify managers of the *session* (= B).
- **Why this needs stating.** Part B's generic hook (K3) fires on `{entity, :caps}`
  slice-changes and resolves `managers_of(the entity whose caps changed)`. A pending
  request changes the **session's** `:pending_members`, not any `:caps` — so wiring it
  naively to the generic hook would resolve `managers_of(SESSION) = B`, the **exact
  wrong target**. The "cascade" here is the *machinery* (`managers_of/1` + notify)
  invoked by a **new trigger** carrying the **pending member as the explicit notify
  subject**.
- **DEMOTED — implementer picks the wiring (constraint pinned):** a direct
  `managers_of(pending_member) → notify` call from the admission action, OR generalize
  the cascade hook to carry an explicit notify-subject for a `{session,
  :pending_members}` change. Either satisfies the requirement + test (§14 test 29). Do
  NOT re-specify the effect grammar.
- **The pending request IS the actionable payload.** Content-free per the envelope
  rules; A re-fetches the request detail via a cap-gated read and approves/denies by
  `request_ref`.

### C.4 — Approve → mount (the deferred second half of join)

The member's owner/manager approves; the mount is the **existing grant+mount path**,
unchanged:

- **Approve authz:** the approver MUST hold **manage-authority over the member** —
  `Ezagent.Identity.Authority.manages?(approver, member)` (so A, the creator holding
  `CreatorGrant.manage_cap` over A's-agent, may approve; B may not). A new
  `:approve_admission` session action, cap-gated on this predicate.
- **On approve:** grant `member_cap(S, ws)` via the **exact R3.1 synchronous, checked,
  ABORT-SAFE grant** (the same grant A1.2/A2 already perform — a failed grant ABORTS
  the approval, leaving the request pending, never a half-mounted member), THEN run the
  normal `do_join_apply` mount (projection entry, monitor, presence) — i.e. approve
  re-enters the join tail at exactly the point C.1 withheld. Remove the entry from
  `:pending_members`.
- **Now the agent is a functional member:** it holds the member-cap ⇒ R1.1 authorizes
  its `:receive` ⇒ B's next post is delivered and A's agent runs (with A's consent,
  spending A's credential deliberately).
- **Role-conflict / preflight** (`Members.role_name_conflict/3`, `membership.ex:48`) is
  re-checked at approve time (session state may have drifted since the request), same
  zero-side-effect preflight as join.

### C.5 — Deny / withdraw / timeout

- **Deny (by a manager of the member, A):** drop the `:pending_members` entry. No cap
  was ever granted, so there is nothing to revoke — deny is a pure state-drop.
- **Withdraw (by the requester, B):** the inviter may withdraw its own pending request
  → drop the entry. (Authz: `requested_by == withdrawer`.)
- **Session-end:** all pending requests are dropped with the session (they live on the
  session slice; PROPOSED: reconcile/teardown drops them, same as roster).
- **Timeout — DEFAULT (PROPOSED, recommended):** a pending request **persists until
  approved / denied / withdrawn / session-ends**. **No auto-expiry and — the hard
  rule — NEVER auto-approve.** Auto-approving would re-open X; auto-denying is a
  harmless future option, not adopted now.

### C.6 — What is genuinely NEW vs COMPOSED (the honesty answer)

**NEW (Part C's actual code):**
- the **trigger branch** at the grant seam (`manages?(caller, member)` → mount-now vs
  pending) — reuses the K2 predicate, new call site;
- the **`:pending_members`** session slice + its lifecycle (record / drop);
- the **approve / deny / withdraw** session actions, each authz-gated
  (approve/deny: `manages?(actor, member)`; withdraw: `requested_by`);
- firing the notify with the **pending member as subject** (new trigger/subject; not
  the generic `{entity,:caps}` cascade).

**COMPOSED (reused unchanged — no new mechanism):**
- **R1.1 held-cap receive-authz** → "pending cannot receive → cred not spent," FOR
  FREE (the whole security property);
- **R3.1 abort-safe synchronous grant** → the approve→mount grant IS the join grant;
- **Part B `managers_of/1` + content-free notify** → owner notification;
- **K2 `Authority.manages?/2`** → the manage-authority predicate (trigger + approve
  authz);
- **the existing `do_join_apply` mount** → approve re-enters it.

That the security-critical half is entirely COMPOSED (R1.1 + R3.1) is the point:
Part C adds prevention **without a new security path** — it withholds an existing
grant and lets the existing held-cap authz do the rest.

### C.7 — Coherence with R1.1 / R2.3 / R3.1

- **R1.1 / R2.3:** the pending member's `:receive` is denied at the SAME two entry
  points (`User.Receive`, `Agent.Receive`-before-the-bridge) by the SAME
  `MemberReceive.authorize/1` held-cap check — Part C adds no receive path, it simply
  ensures no cap is held.
- **R3.1:** approve's grant is the confirmed abort-safe grant; a failed approve-grant
  leaves the request pending and the member unmounted (loud, no partial state) —
  identical to R3.1's let-it-crash boundary on the removal revoke.
- **Roster⟂authz:** pending is neither in the roster nor cap-held; the load-bearing
  barrier remains the held cap.

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
`ReceiveAuthzParityTest` invariant covers the actually-registered `{Kind, :receive}`
behaviors — **exactly two: `User.Receive` + `Agent.Receive`** (R2.3 corrects R1.2's
"≥4 incl. plugin receives" — plugin agents receive THROUGH `Agent.Receive`, so gating
those two sites, the `Agent.Receive` one BEFORE the bridge short-circuit
`receive.ex:210`, covers every plugin agent). No runtime consent-inversion (rejected —
self-slice deadlock).

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

**K6 — member-cap is lifecycle-owned; grant-first (JOIN) / fail-closed removal**
(§4.3). **REVISED (R3.1, superseding R2.1):** removal is NOT uniformly "revoke-first" —
self-`:leave` revokes-then-drops, and `:remove_participant` runs a pure teardown-
**authority** preflight (reject ⇒ cap + roster intact, test 11), then a confirmed
abort-safe revoke (revoke fails ⇒ ABORT, member intact), then best-effort destructive
teardown + roster-drop (`membership.ex:636-645, 668-685`; `teardown.ex:90-94`). A
post-revoke destroy/drop failure is a reconciled resource leak, not a security
regression. CONFIRMED atomicity precedent: `handle_remove_participant`
(`.../membership.ex:624-687`). **See R3.1.**

**K7 — admission = owner-approval-to-mount (R4, PREVENTS X).** A cross-owner add
(a real non-system `ctx.caller` that is neither the member nor a manager of it —
`Authority.manages?/2` false) does NOT grant the member-cap; it records a PENDING
request and notifies `managers_of(member)`. The member holds no cap ⇒ R1.1 denies its
receive ⇒ B's prompt never runs, A's credential never spent (prevention, not
detection). Approve (by a manager of the member) performs the R3.1 abort-safe grant +
normal mount. A manage-authorized add (own agent / self-join / admin) mounts
immediately, unchanged. **The trigger is a requirement over ALL member-add entry paths
(World `invite_member/3`, `provision_invited_join_authority/3`, the materializer, any
direct `session.join`), checked at the COMMON chokepoint `handle_join/2`
(`session.ex:588`) — NOT one invite function (which misses the world-UI invite, §C.1
bypass 1).** **CONFIRMED reuse:** `CreatorGrant.manage_cap/4` (`creator_grant.ex:20`)
backs `manages?`; R1.1 gives "pending cannot receive" for free. **NEW:**
`:pending_members` slice + approve/deny/withdraw actions + the pending-member-as-subject
notify. Depends on A2 (R1.1) + Part B (`managers_of`, notify) + K2 (`Authority`).
**See Part C.**

**Confirmed-sound, do not re-litigate** (carried from S1 review): `do_join`
mutates `:members` today (`.../membership.ex:127-135`); `slice_changed` is
content-free + omits `:caller` (`slice_change.ex:202-239`); `notify/2` raises for
non-User (`notifications.ex:192-205`); `workspace_of/1` is O(1) (`capability.ex:425`);
`matches?/2` honors scope tuples (`match.ex:120-144`).

---

## 12. Internal phasing (ONE spec, four merge-safe phases)

This is a big change; implement in four phases, each independently green + merged,
all landing the same architecture. Phasing = review checkpoints, not scope forks.

**The arc closes X in two steps.** A1→A2→B deliver **detect + react** — membership is
a revocable cap and managers are notified on cap-change, but a cross-owner add still
mounts A's agent immediately (X open, as the pre-R4 spec deferred in §15). **Phase C
adds PREVENTION** (owner-approval-to-mount): the cross-owner add goes pending and A's
credential is not spent until A approves. **X is closed when C lands.**

- **A1 — member-cap model + migration (foundation, low risk).** Define the
  member-cap; add its grant to the at-join flow alongside `mount_participation_caps`;
  add `reconcile_after_load/2` seeding; write + run the idempotent migration task
  (repo READ + live-grant WRITE per **R2.2**).
  Delivery still reads the projection with the UNCHANGED read shape and STILL mints
  ephemerally (the mint is deleted in A2), so this phase is behavior-preserving and
  purely additive. Member-caps now exist and are authoritative; nothing yet depends
  on them for delivery.
- **A2 — delivery/presence cutover (the load-bearing phase).** Make `:receive`
  `cap_exempt` + add the shared `MemberReceive.authorize/1` in-handler predicate
  (K1/R1.2) + the `ReceiveAuthzParityTest`; delete `member_receive_caps/1` (present
  NO cap — R1.1); move the socialware read predicate to held-cap (R1.1); wire
  leave/remove to revoke the member-cap with compensation (JOIN grant-first; LEAVE
  revoke-then-drop; REMOVE authority-preflight → abort-safe revoke → best-effort
  destroy → roster-drop per **R3.1**); run JOIN replay+notify post-commit (**R3.2**);
  anon holds the member-cap. The receive-authz
  hook goes at the **two** real entry points, `Agent.Receive` before the bridge
  short-circuit (**R2.3**). Presence/monitors untouched. This
  phase carries the blast radius (receive authz, read authz, anon, removal) and is
  where the §14.5 acceptance E2E lives.
- **B — cascade rides on top (small, given A).** Extract `Ezagent.Identity.Authority`
  (K2); add the cascade hook at the emit chokepoint (K3); implement `managers_of/1`
  (K4/K5); content-free notify. `affected_principals` is always `[X]`.
- **C — admission gate: owner-approval-to-mount (Part C, K7 — closes X by PREVENTION).**
  Rides on A2 (R1.1 held-cap authz) + B (`managers_of/1` + notify) + K2 (`Authority`).
  Interpose the trigger branch at the member-cap grant seam (`manages?(caller, member)`
  → mount-now vs pending); add the `:pending_members` slice; add approve/deny/withdraw
  actions (approve/deny authz = `manages?(actor, member)`); notify
  `managers_of(pending_member)` with the pending member as subject. **This phase owns
  the rewritten §14.5 PRIMARY (prevention) done-gate.** Additive/advisory to A2+B: the
  security half is entirely composed (R1.1 + R3.1).

Each phase gets the SPEC → codex-adversarial-review gate before implementation and
`/codex:adversarial-review` at PR open (per project convention).

---

## 13. Error handling

- **Grant failure at join (member-cap):** abort, no projection entry — fail-closed
  (§4.3, K6). Distinct from the best-effort `:send` grant (may degrade to observe).
- **Revoke failure at self-`:leave`:** do NOT drop the projection entry; log +
  telemetry; `reconcile_after_load/2` heals on next activate (benign — the self-leaver
  keeps access it was trying to shed, no security regression).
- **Revoke failure at `:remove_participant` (security-critical):** per **R3.1** the
  revoke is synchronous, checked, and **abort-safe** — a revoke failure **ABORTS the
  removal, member left FULLY INTACT** (loud error, no partial proceed, no destructive
  teardown run). This is the let-it-crash boundary: never silently proceed past a
  failed security revoke. A destroy/roster-drop failure *after* a confirmed revoke is
  the opposite case — best-effort, a reconciled resource leak, not an abort.
  Never leave a revoked cap with a live projection entry OR vice-versa silently —
  `reconcile_after_load/2` is the backstop.
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
- **Approve-grant failure (Part C, security-critical):** the approve grant is the
  R3.1 synchronous, checked, **abort-safe** grant — a failed grant **ABORTS the
  approval, leaves the request PENDING, mounts nothing** (loud error, no half-mounted
  member). Never silently proceed past a failed approve-grant.
- **Approve/deny by a non-manager:** the action is authz-gated on
  `Authority.manages?(actor, member)`; a non-manager approve/deny returns `{:error, _}`
  with zero mutation (the pending entry is untouched) — same fail-closed discipline as
  `remove_participant` (test 11).
- **Duplicate / racing pending request:** a second cross-owner add for an
  already-pending member is idempotent (no second entry, no second notify); an add for
  an already-MOUNTED member is a no-op (it already holds the cap).
- **Notify failure on a pending request:** the owner-notify is best-effort/advisory
  (Part B contract) — a failed notify does NOT roll back the pending record; the
  request persists and A can still act on it via the roster/pending surface.

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
24. **Receive-authz parity invariant (R1.2, corrected by R2.3):** every
    **registered** `{Kind, :receive}` behavior — enumerated dynamically from the
    `BehaviorRegistry`, which is exactly `User.Receive` + `Agent.Receive` today, plus
    any future registered Kind — is `cap_exempt` for `:receive` AND routes through
    `MemberReceive.authorize/1`. The test does NOT enumerate the unreachable
    `HelloBuilder`/`HelloConcierge` role `:receive` handlers (R2.3); a NEW registered
    receive behavior that skips the helper fails.
25. **Migration bounded (R1.5, write model per R2.2):**
    `mix ezagent.migrate.member_caps` on a seeded set enumerates only
    `kind_type == "session"` rows via keyset pages (assert no `list_all`), and
    **grants per member via the live grant path `grant_cap_via_router/4`, NOT a repo
    snapshot write** (assert the router grant path is used) — reads members from the
    same decoded state, reports ownerless fallback count; `--dry-run` writes nothing;
    `--gate` exits nonzero pre-migration and zero post.
26. **Agent enumeration (R1.4):** `Entity.Agent.list_in_workspace/1` returns a
    DORMANT agent (snapshot-only, not live) and excludes users/other workspaces.

**C — admission gate (owner-approval-to-mount, R4/K7)**
27. **Trigger branch — non-add / manage-authorized mounts immediately (unchanged);
    OVER-FIRE guard (re-verified at the `handle_join` chokepoint):** each of these
    **still MOUNTS, does NOT go pending** — (a) a caller who holds
    `Authority.manages?/2` over the member (own agent / admin); (b) **self-join / anon
    self-admission** (`caller == member`); (c) the **materializer / team-template spawn
    under `caller = admin_uri`** — ⚠️ CORRECTED: `system://session-internal` is
    ELIMINATED (#154); the materializer runs under `Entity.User.admin_uri()` with a
    narrow inline join cap, so this asserts an **admin-caller add MOUNTS** (its
    exemption rests on `manages?(admin_uri, member) = true` resolving admin's DURABLE
    identity caps, NOT `ctx.caps`). Proves the trigger keys on "a real non-system caller
    who is neither the member nor a manager," at the grant seam reached from EVERY entry
    path — not a bare `ctx.caps`-based check (which would stall every team-template
    spawn — §C.1 warning).
28. **Trigger branch — cross-owner add goes PENDING, no cap:** B (no manage-authority
    over A's-agent) adds A's-agent **via the orchestrator/invite-authority path** → a
    `:pending_members` entry is recorded, **NO member-cap is granted** (assert absent
    via `read_entity_caps/1`), and NO `:members` projection entry exists. (The World-UI
    invite bypass is the SEPARATE test 33, so both entry paths are covered.)
29. **Pending notify targets the MEMBER's managers, not the session's:** the pending
    request notifies `managers_of(A's-agent) = A`, content-free (envelope carries
    `{member, session, request_ref}`, no message/cap content); asserts **A** is
    notified and **B is NOT** notified via this path (the cascade-subject trap).
30. **Pending cannot receive (the prevention core, R1.1 reuse):** with A's-agent
    pending, B posts in S → A's-agent's `:receive` is DENIED (holds no member-cap) →
    it does NOT run → A's credential is NOT spent. Deterministic; no reconcile.
    ⚠️ **Credential-non-spend is asserted at the FLAVOR-ADAPTER boundary, NOT process
    liveness (Q3).** `dispatch_receive_call/3` calls `SpawnRegistry.ensure_live/1`
    (`session/delivery.ex:163-165`, CONFIRMED) BEFORE the receive-authz dispatch — so
    the agent process CAN be alive while the receive is still denied. The assertion
    must therefore verify the **flavor adapter / bridge deliver call was never invoked**
    (`AgentBridge.deliver_*` in `agent/delivery.ex:deliver_agent_receive/2` — the credential
    spend), e.g. via a mock/telemetry on the bridge adapter — NOT `Process.alive?`.
31. **Approve → mount:** A (holds manage-authority over A's-agent) approves the
    request → member-cap granted via the R3.1 abort-safe grant + normal mount →
    `:pending_members` entry removed → B's next post is delivered and A's-agent
    receives. A non-manager (B) attempting approve → `{:error, _}`, zero mutation.
32. **Deny / withdraw / abort-safe:** A denies → pending entry dropped, no cap ever
    granted; B withdraws its own request → dropped; an approve whose grant COMMIT
    FAILS aborts and leaves the request PENDING (nothing mounted) — R3.1 abort-safe.
33. **🔴 World `invite_member/3` bypass → PENDING (the primary-surface regression,
    §C.1 bypass 1):** exercise the world-UI invite entry point specifically — B (no
    manage-authority over A's-agent) invites A's-agent through
    `Ezagent.World.ConversationActions.invite_member/3` (which dispatches `session.join`
    directly with B's caps, NOT through `provision_invited_join_authority/3`,
    `conversation_actions.ex:408`). Assert the add goes **PENDING** (a `:pending_members`
    entry, **NO member-cap**, NO `:members` entry) — proving the gate at the
    `handle_join` chokepoint catches the world invite, not only the orchestrator path. A
    future regression that re-scopes the trigger to one invite function fails this test.
    (World-plugin-level test — `invite_member/3` takes a `Phoenix.LiveView.Socket`; the
    session-domain `handle_join` chokepoint may alternatively be asserted at the
    `session.join` dispatch boundary with `caller = inviter`, inviter's caps, no
    manage → PENDING.)
34. **Cross-session routing cannot confer receive (§C.1 bypass 2 — covered by R1.1):**
    a same-workspace cross-session forward (`dispatch_cross_session_call/3`) into a
    target session containing a **non-member A-agent** injects the inline
    `cross_session_send_caps/2` cap (`:send` only). Assert A's-agent (holding no
    member-cap) **cannot RECEIVE** the forwarded message → `:receive` DENIED, credential
    not spent — the inline cap confers SEND on the session, never `:receive` to a
    non-member. Proves the forwarding path is gated by R1.1, not a member-add bypass.

### 14.5 Acceptance E2E — the done-gate (NEW scenario, R4-revised: PREVENTION is primary)

This scenario **does not exist today**; it is the feature's end-to-end done-gate.
Since R4 the PRIMARY, load-bearing assertion is **PREVENTION** — that X is truly
closed because B's cross-owner pull **cannot spend A's credential at all** until A
approves, not merely that A is notified after the fact. The old revoke→immediate-deny
assertion is **RETAINED as defense-in-depth** (it still proves R1.1's held-cap
guarantee, and remains **Phase A2's** done-gate). **Split by determinism.**

**The PRIMARY assertion (verbatim — this is what proves X solved by prevention):**

> **B (holding NO manage-authority over A's agent) adds A's agent to session S → A's
> agent enters PENDING, is NOT mounted; B sends a message → A's agent does NOT receive
> it, does NOT run, A's credential is NOT spent.** Then: **A is notified of the pending
> request; A approves → A's agent mounts and now receives normally.** (Defense-in-depth
> retained: after mount, A removes → revoke → cannot receive, immediate, no reconcile.)

**(A) Security done-gate → ExUnit integration test** (deterministic; neither the
pending-deny nor the revoke-deny may depend on reconcile timing, which would flake in
a browser test). Lives at
`apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs`
(cross-app integration; the session domain owns membership + delivery). Steps, tagged
by owning phase:

1. **[Phase C] Cross-owner add → PENDING, not mounted.** B (no manage-authority over
   A's-agent) adds A's cc agent to B's session **S**. Assert a `:pending_members`
   entry exists and **NO member-cap** was granted to A's-agent (assert absent via
   `read_entity_caps/1`); no `:members` projection entry.
2. **[Phase C] 🔴 PRIMARY PREVENTION PROOF.** B posts in S. Assert A's-agent's
   `:receive` is **DENIED** (it holds no member-cap → R1.1 in-handler check denies) →
   A's-agent **does NOT run**, **A's credential is NOT spent**. Deterministic: the cap
   was never granted, so no reconcile timing is involved.
   ⚠️ **Assert credential-non-spend at the FLAVOR-ADAPTER boundary, NOT process
   liveness (Q3).** `dispatch_receive_call/3` calls `SpawnRegistry.ensure_live/1`
   (`session/delivery.ex:163-165`) BEFORE the receive-authz dispatch, so the agent
   process may be alive even when the receive is denied. The load-bearing assertion is
   that the **flavor adapter / bridge deliver call (`AgentBridge.deliver_*`) was NEVER
   invoked** (mock/telemetry the adapter — that call IS the OAuth spend) — a
   `Process.alive?`/`refute` on the worker is NOT sufficient.
3. **[Phase C] Owner notified of the pending request.** Assert **A** receives the
   pending-admission notification — `managers_of(A's-agent) = A` (the creator holding
   `CreatorGrant.manage_cap`), content-free approvable envelope — and **B is NOT**
   notified via this path (cascade-subject correctness).
4. **[Phase C] Approve → mount → now receives.** A (holds manage-authority over
   A's-agent) approves → member-cap granted via the R3.1 abort-safe grant + normal
   mount; the `:pending_members` entry is removed. B posts again → A's-agent's
   `:receive` now **fires** (holds the member-cap). A non-manager (B) attempting the
   approve → `{:error, _}`, zero mutation.
5. **[Phase A2] Defense-in-depth — revoke ⇒ immediate deny, no reconcile.** With
   A's-agent now a mounted member, B (or A) **removes** it (revoke the member-cap).
   Assert A's-agent can **NO LONGER receive** — B posts again and `:receive` is DENIED,
   **proven WITHOUT running `reconcile_after_load/2`** (the test never re-activates the
   session; the in-handler held-cap check denies on the already-revoked cap). Immediate
   loss of receive, no reconcile wait, no bearer window.
6. **[Phase B] Grant/revoke cascade to an arbitrary X.** Grant a member-cap to some
   entity X whose owner/manager is Y; assert Y is notified (and on revoke, Y is notified
   — the S1-gap-closed removal-notify).

**(B) Cross-owner APPROVE UX → world-UI agent-browser scenario** in
`docs/scenarios/2026-07-04-member-cap-cascade.md` (project convention
`feedback_esr_e2e_standards`: an agent-browser screenshot gate for user-facing
flows). Drives the world UI through the **prevention flow**: B opens S, adds A's cc
agent via the roster/picker → capture (1) A's-agent shown as **PENDING** (awaiting
approval), NOT a live member; (2) A's notification surface showing the **approvable
pending request**; (3) after A approves, the roster showing A's-agent now **mounted**
as a member. This proves the human-visible owner-approval-to-mount path. The
**pending-deny and revoke-deny** stay ExUnit-only (not UI-visible / timing-sensitive).

**Gate wording:** the feature is DONE when (A) passes in full — **especially step 2**
(the PRIMARY prevention proof) **and step 5** (defense-in-depth) — and (B)'s three
screenshots are captured. **Step 2 is the single load-bearing assertion that X is
closed by prevention**: if a cross-owner add mounts (or its message ever reaches
A's-agent) without A's approval, the admission gate is not implemented and the feature
is not done. Step 5 is the retained defense-in-depth (A2's own gate); if it cannot pass
without a reconcile, R1.1's roster/authz separation is not actually implemented.

**Alignment with R3.1 (reframed REMOVE invariant).** Step 5 asserts **revoke-happened
→ member cannot receive**, NOT worker-destroyed. That is *exactly* the load-bearing
property R3.1's reframe protects: the confirmed abort-safe revoke is the security
boundary, and the destructive `sandbox.destroy` teardown is deliberately outside the
assertion (a post-revoke resource concern, reconciled, not security). No assertion
change is needed. **Alignment with R4 (admission):** step 2's prevention rests on the
SAME held-cap authz — the pending member simply never holds the cap; approve (step 4)
is the SAME R3.1 abort-safe grant. Prevention adds no new security path.

---

## 15. Out of scope

- **S0 — delete legacy `Notifications.notify/3`.** Independent housekeeping.
- **~~The join ADMISSION authz gate.~~ NOW IN SCOPE (R4) — see Part C.** Earlier
  revisions deferred this as "whether B is *allowed* to pull A's agent in," leaving X
  open (notify-after-mount is not prevention). The lead's owner-approval-to-mount
  decision brings it in scope as **Part C**: a cross-owner add goes PENDING and does
  not mount (spend A's credential) until A approves. Note this is **not** the old
  "who may grant the member-cap" hard-deny sketch — it is more permissive (B MAY
  request) and safer (nothing mounts without the owner). Part C is Phase C / PR-4.
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

1. **K1 receive-authz — RESOLVED in R1.2, residual A2 DISSOLVED in R2.3.** The
   in-handler / `cap_exempt` design is CONFIRMED against a proven precedent
   (socialware read-auth), not a runtime edit. The former residual — "whether plugin
   agent Kinds carry a readable `:identity` sibling" — **no longer exists**: there is
   no separate plugin agent Kind. Every flavor is `Entity.Agent` (which carries
   `:identity` caps — §2.8), and all flavors receive through the single
   `Agent.Receive.handle_receive/2` (`hello/bridge_adapter.ex:8-14`), so
   `reads_siblings([:sandbox, :identity])` at that one entry covers every plugin agent
   (R2.3). No `read_entity_caps/1` fallback for a missing plugin `:identity` slice is
   needed. RESOLVED.
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
5. **Behavior shift (Part C, K7): cross-owner add now requires owner approval.** 🧑
   **Lead sign-off (parallel to risk 4).** Adds that previously mounted immediately —
   B pulling A's agent into B's session — now go **PENDING** until A approves. This is
   the intended prevention of X, but it is a **user-visible change to existing
   multi-user / add-others'-agent collaboration flows**: any workflow that relied on
   silently mounting another owner's agent now stalls at pending. **Confirm this is
   intended and won't break a needed existing flow.** Inverse (blast-radius bound —
   the trigger fires only on a **cross-owner add**, keyed on `ctx.caller` at the
   `handle_join` chokepoint, §C.1, NOT on every grant): **behavior-preserving, current
   mount path unchanged** for (a) a caller who MANAGES the member (own agent / admin);
   (b) **self-join** (joiner admits itself, incl. anon self-admission, `caller ==
   member`); (c) **system / orchestrator / team-template spawn (materializer)** — ⚠️
   **CORRECTED: `system://session-internal` was ELIMINATED (#154);** the materializer
   now dispatches under `ctx.caller = Entity.User.admin_uri()` with an inline join cap
   (`materializer.ex:182-212`), so its exemption rests on `manages?(admin_uri, member)
   = true` (workspace-admin), which the K2 predicate must resolve from admin's
   **durable identity caps by URI** (NOT `ctx.caps`, which carries only the inline join
   cap — PROPOSED, implementer-verify; see §C.1 (c)). Normal agent spawning is
   untouched. **Only a cross-owner add by a real non-system caller who lacks
   manage-authority changes.** (A `ctx.caps`-based check would wrongly pend materializer
   spawns — see the §C.1 warning; keying on the caller's durable authority at the
   chokepoint is load-bearing, not cosmetic.)
   *Minor, flag-don't-build (one-line open notes for the lead, not designed here):*
   (a) whether the requester **B** is told of the eventual approve/deny outcome;
   (b) whether **B's identity** appears in A's pending-request payload (a mild tension
   with the content-free envelope — an approvable request needs *some* handle).
6. **Pending-request cascade subject (Part C, §C.3).** The pending-request notify must
   target `managers_of(the pending MEMBER)`, NOT the generic `{entity,:caps}` hook's
   `managers_of(the changed entity = the session)`. Called out because wiring it
   naively to the Part B hook resolves the WRONG target (B, not A). The requirement +
   discriminating test (test 29) are pinned; the wiring is DEMOTED (direct call vs
   subject-carrying hook) — implementer's choice, not a design gap.
