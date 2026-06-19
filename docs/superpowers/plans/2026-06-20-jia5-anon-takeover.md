# 甲-5: Anon→login takeover (route B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Expose the *mechanism* (a dispatchable Session Behavior action) by which a **confirmed**
user takes over an anonymous user's session footprint and the anon is retired — completing the
unified anon model so 甲-6 can delete `system://lv-anon-mount` + `system://socialware-gc`.

**Architecture:** One takeover action on `Behavior.Session` orchestrates: (a) the confirmed user
joins (mounts the confirmed tier via 甲-2's `mount_participation_caps`), (b) the anon's footprint
transfers (re-point `Session.ReadMarker` rows + membership `anon_uri → confirmed_user_uri`), (c) the
anon is retired (`Users.delete/1` + `AnonBinding.delete/1`, the already-built §4.4 reap). The
`AnonBinding` row (anon_uri ↔ session_uri) is the handle; possessing the anon's session cookie is
what authorizes the takeover.

**Tech Stack:** Elixir/OTP umbrella, Ecto/SQLite, CapBAC, the Kind/Behavior dispatch runtime.

## Global Constraints
- North star #154: no new `system://` principal; every authority traces to a real entity. The
  takeover mints no ambient principal.
- UX is OUT OF SCOPE (spec 乙). This plan delivers the dispatchable mechanism only.
- `mount_participation_caps/2` (甲-2) is the confirmed-tier mount — reuse, do not reimplement.
- Measure suites from the umbrella ROOT (standalone app runs hit cross-app load artifacts).
- Each PR: implement → subagent adversarial review (codex retired) → FULL gate suite
  (`system_principal_*` + `no_unowned` + `no_admin` + `no_wildcard` + action-audit + acyclic +
  undeclared-umbrella + `arch.scan` + `check_invariants` + `doc.scan`) → admin-merge.

---

## The authority model (the load-bearing security decision)

Spec §3.5 names the mechanism but not the authorizer. By Allen's by-design-security principle
("identify the caller first; keep the chain in trusted objects"):

- **Caller** = the **confirmed user** (authenticated; `ctx.caps` are their real HELD caps, set by
  `api_v1_controller` from `Entity.authenticate` — unforgeable, same gate 甲-4 relied on).
- **What proves the right to take over THIS anon** = possession of the anon's session cookie, which
  resolves via `AnonBinding.get(anon_uri)` to the `{anon_uri, session_uri}` row. The frontend
  (spec 乙) holds the cookie and passes `anon_uri` in the takeover args; the action verifies the
  `AnonBinding` row exists AND its `session_uri` equals the target session. An attacker without the
  cookie cannot name a valid `(anon_uri, session_uri)` pair (the anon name is 128-bit random).
- **Join authority**: the confirmed user joining the session is authorized by session policy via
  `provision_join_authority/2` (甲-2, owner-rooted) — public_view sessions admit the join; private
  sessions require the existing owner/inviter authority. Takeover does NOT bypass this.
- **Anon retire authority**: retiring the anon is authorized by the same cookie-possession handle —
  the takeover is the anon "handing off then exiting". No admin/system principal is needed; the
  anon's own `AnonBinding` is the capability. (Contrast: the GC sweeper retires on TTL under
  `system://socialware-gc`; 甲-5's interactive retire needs NO principal because the caller proves
  possession.)

**Therefore the takeover needs NO new cap axis and NO new principal.** It is gated by: (1) caller is
a confirmed user (`Users.confirmed?(caller)`), (2) caller holds/obtains join authority for the
session, (3) the named anon's `AnonBinding.session_uri == target session`. All three are checks
against trusted state; failing any → `{:error, reason}` (fail closed).

**Surfaced to Allen (proceed unless rejected):** the cookie-possession-as-handle model. The
alternative (require the anon to also present its join cap) is redundant — the binding row IS the
possession proof, and the anon is read-only so it has nothing higher to delegate.

---

## File Structure
- `apps/ezagent_domain_session/lib/ezagent/session/read_marker.ex` — ADD `repoint/3`.
- `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — ADD `action(:takeover, ...)` +
  `handle_takeover/2`.
- `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — ADD
  `do_takeover/4` (orchestrates join + footprint transfer + retire), delegated to from the handler.
- `apps/ezagent_domain_session/test/ezagent/chat/read_marker_test.exs` — ADD repoint tests.
- `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_takeover_test.exs` — NEW end-to-end
  takeover mechanism test (mint anon → anon reads (markers) → confirmed user takeover → assert
  footprint transferred + anon retired + confirmed user is a member with confirmed-tier caps).

> NOTE on app boundary: `do_takeover` lives in the SESSION domain (membership.ex). It must NOT
> compile-reference socialware (`AnonBinding`/`AnonUser`) symbols — that would create an undeclared
> umbrella dep (session does not depend on socialware) AND likely an acyclic violation. RESOLUTION:
> the takeover action receives `anon_uri` + `confirmed_user_uri` as plain URIs; the SOCIALWARE-side
> retire (`AnonBinding.delete` + `Users.delete`) is invoked by the CALLER (the spec-乙 frontend /
> the socialware web layer) AFTER the session-domain transfer returns `:ok`, OR via a thin
> socialware-domain orchestrator that calls the session `:takeover` action then the reap. Verify the
> dep direction during Task 1 and pick the seam that keeps session→socialware acyclic. (This is the
> same cross-domain-literal trap 甲-4 hit with `Behavior.Session` in curl_agent.)

---

## Task 1: Verify the app-dependency direction + pick the orchestration seam

**Files:** read `apps/ezagent_domain_session/mix.exs`, `apps/ezagent_domain_socialware/mix.exs`.

- [ ] **Step 1:** Determine whether `ezagent_domain_socialware` depends on `ezagent_domain_session`
  (expected yes) and confirm session does NOT depend on socialware. Run
  `grep -n "ezagent_domain" apps/ezagent_domain_session/mix.exs apps/ezagent_domain_socialware/mix.exs`.
- [ ] **Step 2:** Decide the seam: the **anon-retire** (`AnonBinding.delete` + `Users.delete`) lives
  in a SOCIALWARE-domain orchestrator (e.g. `Ezagent.Socialware.AnonTakeover.takeover/3`) that (a)
  resolves+validates the `AnonBinding`, (b) dispatches the session `:takeover` action (footprint
  transfer, session-domain), (c) on `:ok`, retires the anon. The session-domain action stays
  socialware-symbol-free. Record the decision inline in the new module's moduledoc.

---

## Task 2: `Session.ReadMarker.repoint/3` (re-key user_uri, collision-safe)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/read_marker.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/chat/read_marker_test.exs`

**Interfaces:**
- Produces: `ReadMarker.repoint(session_uri :: URI.t(), from_user :: URI.t(), to_user :: URI.t()) ::
  {:ok, non_neg_integer()} | {:error, term()}` — rewrites `user_uri` from `from_user` to `to_user`
  for all of that session's rows, returning the count moved. Collision rule: the unique index is
  `(workspace_uri, session_uri, user_uri, source)`; if `to_user` already has a row for a `source`,
  KEEP the more-advanced marker (max `last_read_message_uri` by the existing ordering / `observed_at`)
  and drop the other, so re-point never violates the unique index and never regresses read state.

- [ ] **Step 1: Write the failing test** — three cases: (a) plain re-point (to_user has NO existing
  markers) moves all rows + returns count; (b) collision (to_user already has a `:read` marker)
  keeps the more-advanced one, no duplicate-key crash; (c) no-op when `from_user` has no rows →
  `{:ok, 0}`. Use the existing `mark/4` to seed rows.
- [ ] **Step 2:** Run it; expect failure (`repoint/3` undefined).
- [ ] **Step 3: Implement** — a transaction: load `from_user` rows + `to_user` rows for the session;
  for each source, compute the winner; `Repo.update_all`/`delete_all` to re-key survivors + remove
  losers. Reuse the existing observed_at/message ordering helper (the same one `mark/4` uses to
  decide `:already_ahead`).
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Commit.

---

## Task 3: `:takeover` action on `Behavior.Session` + `Membership.do_takeover/4` (footprint transfer)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` (action decl + handler)
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` (`do_takeover/4`)
- Test: extend the new socialware takeover test (Task 5) + a session-domain unit if isolable.

**Interfaces:**
- `action(:takeover, args: %{anon: :uri, member: :uri}, returns: %{members: {:list, :uri}},
  caps: [:takeover], modes: [:call])` — `member` = the confirmed user, `anon` = the anon being
  superseded. `:call` (the caller needs the result + it must be ordered before the retire step).
- `handle_takeover(%{anon: %URI{}, member: %URI{}}, ctx)` → delegates to
  `Membership.do_takeover(anon_uri, member_uri, ctx, source_module)`.
- `do_takeover/4` orchestrates IN-SESSION-DOMAIN: (1) assert `Users.confirmed?(member)` (fail closed
  if not), (2) `provision_join_authority(session_uri, member)` then `do_join` the confirmed user
  (mounts confirmed tier), (3) `ReadMarker.repoint(session_uri, anon, member)`, (4) remove the anon
  from membership (the existing `:leave` body / `Map.delete(members, anon)`), (5) return updated
  members. Does NOT delete the anon entity/binding (that's the socialware orchestrator, Task 4).

**Cap for `:takeover`:** declared `caps: [:takeover]`. The authorizer is the confirmed user's join
authority + (in the socialware orchestrator) the AnonBinding possession check. Decide in Task 3
whether `:takeover` reuses the `:join` cap shape (the confirmed user already obtains join authority)
or a distinct `:takeover` cap minted by the orchestrator inline (granted_by the member — self-claim).
Prefer reusing the join-authority path to avoid a new cap axis; if a distinct cap is needed, mint it
inline (granted_by member), per the 甲-3/甲-4 inline-cap pattern — NEVER a new principal.

- [ ] **Step 1:** Write a failing membership/session unit asserting: after `do_takeover`, the
  confirmed user is a member with confirmed-tier caps and the anon is no longer a member.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement the action decl + handler + `do_takeover/4` (reusing `do_join`,
  `mount_participation_caps`, `ReadMarker.repoint`, the leave body). Keep socialware symbols OUT.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit.

---

## Task 4: Socialware orchestrator `AnonTakeover.takeover/3` (validate handle + dispatch + retire)

**Files:**
- Create: `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_takeover.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_takeover_test.exs` (Task 5).

**Interfaces:**
- `AnonTakeover.takeover(anon_uri :: URI.t(), confirmed_user_uri :: URI.t(), session_uri :: URI.t())
  :: {:ok, %{members: [URI.t()]}} | {:error, term()}` — (1) `AnonBinding.get(anon_uri)` must exist
  AND `.session_uri == session_uri` (possession handle; fail closed `{:error, :no_anon_binding}` /
  `{:error, :session_mismatch}`), (2) assert `Users.confirmed?(confirmed_user_uri)`, (3) dispatch
  the session `:takeover` action (footprint transfer), (4) on `:ok`, retire: `Users.delete(anon_uri)`
  + `AnonBinding.delete(anon_uri)` (the §4.4 reap), (5) return members. Idempotent: a second call
  after the binding is gone → `{:error, :no_anon_binding}` (already taken over).

- [ ] **Step 1:** Write the failing orchestrator test (Task 5 covers it).
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement, dispatching via `Ezagent.Invocation.dispatch` with the confirmed user's
  authority (caller = confirmed_user_uri; caps = their held caps or an inline takeover cap granted_by
  the member per Task 3's decision). Retire AFTER the transfer succeeds (never orphan a half-transfer).
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit.

---

## Task 5: End-to-end takeover mechanism test

**Files:** Create `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_takeover_test.exs`.

- [ ] **Step 1:** Test the happy path: mint a public-view anon (`AnonUser.mint_for_public_session`),
  anon joins + reads (seed ReadMarker via `mark/4`), create a confirmed user, call
  `AnonTakeover.takeover/3`. Assert: confirmed user is a session member with `:send`/`:leave`/
  `subscribe_from` caps (confirmed tier); the anon's ReadMarker rows now belong to the confirmed
  user; the anon is no longer a member; `Users.confirmed?(anon)` row deleted; `AnonBinding.get(anon)`
  is nil.
- [ ] **Step 2:** Test fail-closed: (a) takeover with a NON-confirmed caller → error; (b) takeover
  naming an `anon_uri` whose binding session ≠ target session → `{:error, :session_mismatch}`; (c)
  second takeover after retire → `{:error, :no_anon_binding}` (idempotent).
- [ ] **Step 3:** Run → all pass.
- [ ] **Step 4:** Commit.

---

## Task 6: Full gate suite + adversarial review + merge

- [ ] Run the FULL gate suite (see Global Constraints). Ratchet stays **4** (甲-5 adds NO elimination;
  it's the prerequisite — 甲-6 drops lv-anon-mount + socialware-gc to 2).
- [ ] Dispatch a subagent adversarial review focused on: can a caller take over an anon they don't
  possess (binding-handle bypass)? does the footprint transfer leak/lose read state across the unique
  index? is the retire ordered strictly after a successful transfer (no orphan)? does the session
  action stay socialware-symbol-free (acyclic/umbrella)?
- [ ] Address findings; admin-merge.

## Self-Review
- Spec §3.5 coverage: confirmed user joins → Task 3 step (2); footprint transfer → Task 2 + Task 3
  steps (3-4); anon retire → Task 4 step (4); new-registration = create-confirmed-then-transfer →
  Task 4 (caller creates the confirmed user first; no promote-in-place). Covered.
- The two missing primitives the map flagged (ReadMarker re-point, membership transfer) → Tasks 2/3.
- `AnonBinding.delete/1`'s dangling-no-caller status → resolved by Task 4 (its intended consumer).
- Cross-domain trap (session must not ref socialware) → Task 1 seam + Task 3 NOTE.
