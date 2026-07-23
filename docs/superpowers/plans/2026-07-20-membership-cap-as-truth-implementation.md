# Membership = Capability as the SINGLE Source of Truth — Implementation Plan (#166)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Also load `ezagent-developer` + `elixir-phoenix-helper` project skills before writing any `.ex`** (per `feedback_subagent_must_load_project_skills`). **Before ANY grant/revoke/cap/authz code, read `.claude/skills/ezagent-developer/references/capbac.md`.**

**Goal:** Make the session **membership-cap** — `cap(:session, Ezagent.ActionSet.Session, :receive, S)` — the SINGLE enabling truth of "is X a member of session S". DROP the divergent `:members` roster as an *authority*: every authorization decision (read / receive / self-add) keys on the durably-held membership cap, never on a separate roster record. The entity self-drives its own roster entry once it durably holds the cap (cap-gated), so the roster becomes a derived delivery/facet projection that can only ever be a subset of the cap-holders. Fold in codex's two lifecycle findings (creation-readiness barrier + durable `do_join` transitions) and RESOLVE the supervisor "review-but-not-member" middle state.

**Architecture:** Invert the join causality. Phase A (owner-rooted, `:async`, deadlock-free) mints the membership cap; the Session STOPS writing `:members`. Phase B (entity-side, cap-gated, `:cast`, fail-closed) has the entity write ITSELF into `:members` only after it durably holds the cap, verified by an in-handler durable caller-cap read. A Session `reconcile_after_load/2` floor (flipped UNION→EVICT after a cap backfill) makes `members(S) == { durable membership-cap holders over S }` at rest. The read plane drops its `member?` roster conjunct so authz is `owner? OR holds_membership_cap?` alone. The membership check RIDES the unified `authorize/3` chokepoint that the epoch + delete_user programs are consolidating — it becomes a *membership predicate* alongside epoch's generation predicate and delete_user's tombstone predicate, NOT a parallel gate.

**Tech Stack:** Elixir/OTP umbrella (`apps/*`), three-tier `core / domain / plugin`; `use Ezagent.Lifecycle` Behaviors; CapBAC (`%Capability{}`, `Cap.Verifier`); Ecto/Postgres durable snapshots; `mix test` + `mix ezagent.check_invariants` + `mix ezagent.arch.scan` gates.

---

## Global Constraints (verbatim — apply to every task)

- **`members ⊆ { durable holders of cap(:session, Session, :receive, S) }` (INV-FAILCLOSED, safety).** Every writer of `:members` MUST gate on the target's durable membership cap. No code path adds a roster entry for a non-holder.
- **For every durable membership-cap holder over S, eventually `self ∈ members(S)` (INV-CONVERGE, liveness).** Guaranteed by the entity self-add fast path AND the Session reconcile floor.
- **`:members` STAYS as a delivery-targeting + facet cache; it is dropped only as an AUTHORITY.** Do NOT physically delete the map — that breaks the per-message hot path (`session.ex:497` `members_map = ctx[:read].(:members,%{})`). `member?/2` remains a function for delivery/display targeting; it is removed ONLY from the authz conjunct.
- **The membership check is a CAP CHECK that rides the unified `authorize/3`.** Do NOT fork a parallel gate. Route the held-cap check through the same signed-verify chokepoint epoch/delete_user consolidate (see "Architectural convergence" + DECISION #C). The roster-drop and membership=cap-holding work can begin independently; the authz-site integration composes with unify-`authorize/3`.
- **Deadlock-free by construction:** the at-join grant stays `:async` (`member_cap.ex:66`); the entity self-add is `:cast` and its entity-side triggers (`handle_grant_cap`, `activate`) never block on the Session. A `:call` form or a blocking trigger is a regression an invariant test must reject (T10).
- **Fail-closed everywhere:** a missing/failed cap-read is a DENY (`{:error, :unauthorized}` / no roster write), never a default-allow. `add_self` reads the caller's OWN durable caps (K4 provenance-filtered via `granted_by_entity?/1`), NOT `ctx.caps` (member-caps are unsigned; a forged cap could sit in `ctx.caps`).
- **No back-compat shims** (SPEC v2 §5.11; `feedback_let_it_crash_no_workarounds`) — delete legacy paths, don't keep them beside new ones. Data is wiped+reseeded on cutover EXCEPT the one-time cap backfill migration (M-8), which is a live-grant, not a schema back-compat shim.
- **`uv run` not `python`; `pnpm` not `npm`; `mix format` only touched files** (ezagent-developer conventions). `mix precommit` is the final gate.
- **Every PR: TDD (fail-before/pass-after), independently testable, frequent commits.** Reproduce the deny/allow on a clean base or the failure is yours (`feedback_zero_new_failures_baseline_proof`). Completion = an invariant test that fails when the goal is unmet (`feedback_completion_requires_invariant_test`).
- **Reviewer gate — security-authz:** M-1, M-2, M-5, M-7, M-8, S-1, S-2 change the authorization model → **codex adversarial review BEFORE kimi implements each, and `/codex:adversarial-review` at PR open.** Never self-merge these (`feedback_codex_review_every_pr`, `feedback_no_admin_merge_codex_prs`).
- **Run the gates before claiming done:** `mix ezagent.check_invariants` + the new M-9 members-not-authority enumerator must be green.

---

## GROUND-TRUTH ANCHOR TABLE (real current-main file:line — verified 2026-07-20 @ origin/main `fe2906431`)

Read current-main via the clean worktree `/private/tmp/ci189-bc-wt` or `git show origin/main:<path>`. **The design spec (`2026-07-19-membership-cap-as-truth-design.md`) predates several merges; where its cited lines differ from THIS table, trust the table.** Notably the spec's `runtime.ex:362-411 granted_via_holds_cap?` / "ctx.caps FIRST short-circuit then durable fallback" **does not exist** on main — the real chokepoint is `Cap.Verifier` (below), which authorizes cap-required actions ONLY against `ctx.caps`.

| Concern | Symbol | Path:line |
|---|---|---|
| **Read-plane predicate (THE #166 conjunct-drop)** | `Ezagent.Session.Membership.authorize/3` | `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55-64`; the disjunct `owner? or member_with_held_cap?` at `:59`; `member_with_held_cap?/3` `:69-71`; `member?/2` `:108-111`; `holds_member_cap?/2` `:77-82` |
| Read chokepoint that calls it (before row-policy) | `SessionReads.authorize/2` | `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:264` (row-policy at `:141-144`) |
| Publisher-read authz (funnels to SAME predicate) | `authorize/1` | `apps/ezagent_domain_session/lib/ezagent/behavior/socialware_publisher_read.ex:199-207` |
| **Receive-plane predicate (SHARED held-cap gate)** | `MemberReceive.authorize/1`; `holds_member_cap_over?/2` | `apps/ezagent_domain_identity/lib/ezagent/session/member_receive.ex:78-85` / `:102-116` (FIELD-match `:105-113`); dep-graph moduledoc (no `Ezagent.ActionSet.Session` module pin) `:25-41` |
| **Roster write (do_join)** | `Membership.do_join/5` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:28-105`; grant call `MemberCap.grant_at_join` `:88`; compensation `:96-102`; **`{:set, :members, new_members}` `:461`** (do_join_apply tail `:459-467`) |
| Approve-path capless-mount hazard | `approve_admission/3` | `membership.ex:314-338` (re-enters `do_join` `:328-329`); hazard doc `:300-305`; `record_pending_admission/2` `:215-235` |
| merge_member relabel | `do_merge_member/4` | `membership.ex:481-494` (composes `do_join` `:489-490`) |
| **Member-cap grant (Phase A mint)** | `MemberCap.grant_at_join/2` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:31-83`; **`:async` `:66`**; deadlock comment `:42-59`; idempotency `:36`; cap shape `member_cap/2` `:278-286`; sync revoke `revoke_membership/2` `:150-161`; `holds_member_cap_exact?/3` `:298-307` |
| Session Kind handlers | `handle_join/2` `:781`; `do_handle_join/3` `:817-857` (do_join `:847`,`:851`); `handle_assign_role/2` `:897-911` (roster-write `:909`, `require_joined_member` `:925`); `handle_merge_member/2` `:968-970`; `handle_approve_admission/2` `:977-979`; `passive_actor?/1` `:862-867` | `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` |
| `action(:join)` (the return contract) | `:155-163` (**`returns: %{members: {:list, :uri}}` `:159`**, `modes: [:call, :cast]` `:161`, `caps: [:join]` `:160`); idempotent return `{:ok, %{members: …, already_member: true}, []}` `:843` | `session.ex` |
| `action(:approve_admission)` | `:276-284` (`returns: %{members: {:list, :uri}, approved: :uri}`) | `session.ex` |
| **Reconcile floor (union→evict flip)** | `reconcile_after_load/2` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex:53-78` (UNION reduce `:57-68`); candidate scan `candidate_uris/1` `:81-85` (users ∪ agents); `member_cap_holder?/3` `:102-118`; **eviction-deferred-to-A2 comment `:16-24`** |
| Entity convergence seams | `handle_grant_cap/2` `:523-529`; `activate/2` `:206-221` | `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` |
| Live durable cap read | `read_entity_caps/1` (defdelegate → `EntityCaps.load`) | `apps/ezagent_domain_identity/lib/ezagent/identity.ex:327-328` |
| **route_provisioner known bypass** | direct `Membership.do_join` `:35-42`; `system_mediated_ctx/1` `:113` (forces admin caller) | `apps/ezagent_domain_session/lib/ezagent/behavior/session/route_provisioner.ex` |
| **Cap backfill migration** | `MemberCapMigration.migrate/1` `:72-96`; `gate/0` `:103-117`; grant `grant_cap_via_router(…, :sync)` `:141-146`; keyset scan `:200-219` | `apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex` |
| Migration mix task | `run/1` `:29-48`; `run_gate/0` `:65-76` | `apps/ezagent_domain_session/lib/mix/tasks/ezagent.migrate.member_caps.ex` |
| **THE dispatch chokepoint (ctx.caps ONLY)** | `Cap.Verifier.authorize/5` `:47-54`; `@non_cap_actions` (cap-EXEMPT list) `:21-41` (Session exemptions `:34-40`); `verify_cap/5` `:68-97` (candidate_caps = `Map.get(ctx,:caps,…)` `:104`, `verified_artifact?` `:79`, `matches?` `:81`) | `apps/ezagent_core/lib/ezagent/cap/verifier.ex` |
| Dispatch → verifier call | `do_handle_dispatch` verifier at `:164-171` | `apps/ezagent_core/lib/ezagent/kind/runtime.ex` |
| **Behavior cap-exempt list (DUAL-LIST — must edit BOTH)** | `Session.cap_exempt_actions/0` | `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:328-329` |
| Delivery fan-out roster read (STAYS — allowlist in M-9) | `handle_send/2` `members_map = ctx[:read].(:members, %{})` | `session.ex:497` (per cascade §2.3) |
| UI roster reads (STAY — allowlist) | `member_presence/1`, `member_options/1` | `apps/ezagent_plugin_world/.../conversation_data.ex:394-405`, `:118-134` |
| **Supervisor: responsibility assignment** | `ResponsibilityAssignment.assigned?/3` `:106-118`; `supervisor_caps_for_session/2` `:122`; **read_unfiltered cap shape `:124`**; bundle enumerated `:123-136` (NO member-cap) | `apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignment.ex` |
| **Supervisor: WRITE-plane acceptance (the middle state)** | `SupervisorApproval.handle_submit_verdict/2` `:37-79`; **`assigned?/3` gate `:52-59`** (never checks `:members`); else `:stale_holder` `:75` | `apps/ezagent_domain_session/lib/ezagent/behavior/supervisor_approval.ex` |
| **read_unfiltered row-policy (READ modifier, POST-authorize)** | `read_unfiltered?/2` `:450-459`; `read_unfiltered_cap?/3` `:461-473` (match `:466-470`); consumed AT `:143` (AFTER `authorize` at `:142`) | `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex` |
| Supervisor cap bundle grant/revoke | `responsibility_caps("supervisor",…)` `:148-165`; `grant_responsibility_caps/4` `:125-136` (`grant_cap` `:131`); facade `assign_role/5` `:15-46` (grant `:43`) | `apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignments.ex` |
| Workspace `assign_role` action | action `:198-204`; validator `handle_assign_role/2` `:478-484` | `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` |
| Existing gates to model M-9 on | `no_surface_read_dispatch_test.exs` (+`_detector_test.exs`, probes `test/support/no_surface_read_dispatch_probes.ex`); `check_invariant_10` presence-grep in `mix/tasks/ezagent.check_invariants.ex`; arch `member_cap_grant_seam_test.exs`; parity `receive_authz_parity_test.exs`. **NO existing "members-not-authority" gate.** | `apps/ezagent_core/test/invariants/`, `apps/ezagent_domain_session/test/` |

---

## Architectural convergence — the membership check RIDES `authorize/3` (read before DECISION #C)

`#166`'s "is-member" is a **cap check**. Two parallel programs are consolidating every cap authorization onto ONE signed-verify chokepoint:
- **epoch** (`docs/superpowers/plans/2026-07-20-epoch-revocation-implementation.md`) adds a per-cap **generation** predicate (`verify_against_current/3`) to the read-plane cap gates — including `membership_predicate.ex:55` and `member_receive.ex:78` (its Task A-4).
- **delete_user** (`docs/superpowers/plans/2026-07-20-delete-user-invalidation-implementation.md`) adds a per-holder **tombstone** predicate at the same authorize decision (its PR-6), explicitly as "a tombstone predicate alongside epoch's gen predicate, not a second chokepoint".

Under `#166` the membership check is the THIRD predicate on that same chokepoint: *does the holder durably hold the concrete membership cap over S?*. **Do NOT build a separate membership gate.** M-1's `holds_member_cap?` must route the held-cap check through the unified `authorize/3` so it inherits gen + tombstone by construction, rather than staying a bare `identity_key ==` field-match that bypasses them.

**Dependency / ordering (state in every relevant commit):**
- The **roster-drop** (M-5) and **membership = cap-holding** (M-2, M-3, M-8) can begin **independently** — they don't touch the shared verifier.
- The **authz-site integration** (M-1's held-cap check; the read/receive gates) **composes with unify-`authorize/3`**. Merge-order:
  - If epoch A-1/A-4 (or delete_user PR-6) landed the unified `authorize/3` / `verify_against_current` first → M-1 is a *predicate addition*: route `holds_member_cap?` through `Cap.authorize/3` and DROP the `member?` conjunct there. Do not re-implement the field-match.
  - If not landed yet → M-1 drops the `member?` conjunct at the current `MemberReceive.holds_member_cap_over?/2` boundary, structured so it collapses into `authorize/3` when it lands (same shared-predicate shape — the exact structural convergence epoch A-4 targets these two files for).
- **File-collision note:** epoch A-4 edits `membership_predicate.ex:55` and `member_receive.ex:78`; M-1 edits the same. Coordinate the merge so the conjunct-drop and the signed-verify addition compose (one file, two changes), not collide.

---

## DECISIONS — resolve BEFORE kimi implements (this plan goes to codex adversarial review first)

### DECISION #A (THE KEY DECISION FOR ALLEN) — the supervisor moderation model

**Grounded problem (current-main, verified).** A workspace "supervisor" is assigned via workspace `assign_role` (`responsibility_assignments.ex:15-46`), which grants a **cap bundle** (`responsibility_assignment.ex:123-136`): `read_unfiltered`, `Turn:claim`, `Turn:settle`, `Surface:approve`, `Surface:commit_settlement`, `SupervisorApproval:submit_verdict` — **and NO session membership cap** (`cap(:session, Session, :receive, S)`). Consequence today:
- **WRITE plane ACCEPTS the non-member supervisor:** the moderate verbs authorize purely on the held bundle caps at the dispatch chokepoint (turn/surface handlers contain no `:members` check), plus `supervisor_approval.ex:52-59` re-verifies via `ResponsibilityAssignment.assigned?/3` (workspace responsibility — NOT membership).
- **READ plane REJECTS the non-member supervisor:** the read chokepoint `Membership.authorize/3` (`membership_predicate.ex:59`, invoked by `session_reads.ex:264` BEFORE row-policy at `:143`) has **no supervisor branch** — a `read_unfiltered`-holder who is not a member fails `authorize` and never reaches `read_unfiltered?`. `read_unfiltered` is a row-policy **modifier** applied only to already-authorized readers; it confers NO standalone access.

That asymmetry (**can moderate, cannot read**) is the "review-but-not-member" middle state Allen rejected. Under `#166`'s cap-as-truth model it dissolves cleanly: **a principal is a member IFF they hold the session membership cap.** A `read_unfiltered`-holder without the membership cap is simply NOT a member → NO session access (read OR write).

**Options (present to Allen; recommendation is the default):**

- **Option 1 — NO middle state; supervisor must be a real member to touch a session (RECOMMENDED, Allen's stated default).** A supervisor who legitimately must review/moderate a specific session is granted a **first-class reviewer-membership** (a membership-kind facet the supervisor holds → they hold the membership cap → they ARE a member with normal read+write access). The WRITE-plane bundle stops conferring session-content authority on non-members: the turn/surface/`submit_verdict` verbs additionally require the actor be a member (holds the membership cap over S), OR the supervisor is granted the membership cap when assigned to that session. Workspace-level moderation that needs *session content* requires *session membership*. Clean: one truth (the membership cap) gates both planes; no asymmetry; no new authority concept beyond a reviewer-membership facet (which is just the membership cap with a role_name).
- **Option 2 — supervisors never act on a session's content.** Strip the session-content verbs (turn/surface/`submit_verdict` over a specific session) from the non-member supervisor bundle entirely; keep only workspace-scoped, content-free oversight (e.g. metadata, assignment, quorum config). A supervisor who must see/act on content must first be invited as a member (Option 1's flow). Most restrictive; removes the write-plane authority instead of upgrading the supervisor to a member.
- **Option 3 — keep the asymmetry, but make it explicit and content-free.** Accept that a supervisor moderates without membership (status quo write plane), but formally define `read_unfiltered` + the moderate bundle as a NON-member "oversight" authority that is deliberately blind to raw content (verdict on metadata/policy only, never message bodies). Rejected by the cap-as-truth model — it re-legitimizes the very middle state Allen rejected — listed only for completeness.

**Option 1 SUB-DECISION — reviewer-membership SCOPE (must resolve; it changes what Allen agrees to).** The supervisor bundle is minted *per-live-session across the WHOLE workspace* at assignment time (`responsibility_assignments.ex:148-163`). So naively adding the membership cap to that bundle makes a supervisor a real member of **every session in the workspace** (they appear in every roster), and sessions created *after* assignment get nothing unless a new-session hook re-grants. Pick: **(1a) per-session reviewer-membership** — the supervisor is granted membership on a specific session, explicit + opt-in + scoped (they appear only in rosters they were assigned to); vs **(1b) workspace-wide** — membership of all sessions, which additionally needs a new-session hook so sessions born after assignment also grant it. **Recommendation: (1a) per-session opt-in** — it keeps "a supervisor is a member" honest without silently making them a member of hundreds of conversations, and avoids the after-created-session hook. **DECISION FOR ALLEN.**

**RECOMMENDATION: Option 1 (scoped per-session, 1a).** It is Allen's stated default (no middle state; a supervisor must be a real member to read), it makes the membership cap the single truth on BOTH planes, and it models moderation as a proper reviewer-membership rather than a non-member cap-holder. **Asymmetry flag (fold into S-2):** the WRITE-plane grant — `supervisor_approval.ex:52-59` accepting non-members via `ResponsibilityAssignment.assigned?/3`, and the turn/surface verbs authorizing on the bundle without membership — must be reconsidered for consistency: either supervisors are members (reviewer-membership → hold the membership cap) or they don't act on the session's content. This **supersedes** the earlier read-plane-hardening option iii ("add a supervisor-read branch") — that middle-state branch is DROPPED (it was never merged; `Membership.authorize/3` has no supervisor branch on main). S-2 carries this decision + the recommended code path; it is GATED on Allen's choice.

### DECISION #B — `merge_member` shape (spec §7.3 open question).
`do_merge_member/4` (`membership.ex:481-494`) atomically relabels `from → to` in `members` + repoints read-markers. Under cap-as-truth, `to ∈ members ⇒ to holds the membership cap`. **Options:** (i) express merge as `grant(to)` + cap-gated `self-add(to)` + `leave(from)` — reuses the Phase-A/B seam, no new handler; or (ii) a dedicated cap-gated relabel handler that verifies `to`'s durable cap before the relabel. Either way the read-marker repoint atomicity (abort-on-repoint-failure) is preserved. **Recommendation: (i)** — composes existing seams, no new authority surface. **DECISION FOR CODEX/ALLEN.** (Owned by M-7.)

### DECISION #C — held-cap gate: ride the unified `authorize/3` now, or field-match now + collapse later.
See "Architectural convergence" above. **Recommendation:** route `holds_member_cap?` through the unified chokepoint IF it has landed at M-1 time; otherwise drop the conjunct at the current predicate boundary, shaped to collapse in. **DECISION FOR CODEX** (merge-order fact, not a design fork). (Owned by M-1.)

### DECISION #D — create-path first-message delivery (spec §12.1, codex finding (a)).
Between Phase A (grant) and Phase B (self-add landing), `members(S)` may not yet contain the new member, so a fan-out targets an incomplete roster → a brand-new member could miss the session's FIRST message. **Options:** (i) a **creation-readiness barrier + initial replay cursor** — the new member records a durable "joined-at" cursor at grant time and replays every message since that cursor once it converges (no message is missed regardless of the window); (ii) an **eager warm** — the materializer invokes the Session reconcile immediately after issuing its grants (it knows the grants it just made), warming `members` before the first send. **Recommendation: (i) is mandatory (correctness), (ii) is an optional create-path optimization.** **DECISION FOR CODEX/ALLEN.** (Owned by M-4.)

---

## Phase overview & PR count

| Phase | PRs | Deliverable |
|---|---|---|
| **M — Membership = cap** | M-1 … M-9 (9) | Read plane keys on the cap; entity self-adds cap-gated; convergence; lifecycle fixes; grant-only `handle_join` cutover; migration+eviction; the members-not-authority gate. |
| **S — Supervisor middle-state** | S-1 … S-2 (2) | Read-plane lock test + `read_unfiltered`-as-modifier doc (option-iii drop recorded); write-plane DECISION for Allen (moderation model) + the recommended reviewer-membership path. |

**Total: 11 PRs** (S-2 is a DECISION-gated PR — its code lands only after Allen picks a moderation model).

**Sequencing (ADDITIVE-FIRST — this order is load-bearing).** `handle_join`/`do_join` is today the ONLY in-session writer of `:members`. Making it grant-only (M-5) BEFORE the self-add writer + convergence exist would leave every new joiner cap-authorized but absent from `members` until the Session restarts — authorized-but-never-delivered-to and invisible in the roster. So add the new writer + convergence FIRST, keep `handle_join` writing `:members` (dual-write, additive, green), and REMOVE the `handle_join` write LAST once self-add is the proven sole writer:

```
M-1 (read plane keys on cap)        → M-2 (add_self writer, additive)
  → M-3 (entity convergence, additive) → M-4 (lifecycle: readiness barrier + replay, additive)
  → M-5 (CUTOVER: handle_join grant-only — removes the roster write)
  → M-6 (:join return contract) → M-7 (funnel: route_provisioner/approve/merge)
  → M-8 (backfill migration → reconcile UNION→EVICT + scan coverage)
  → M-9 (members-not-authority enumerator gate — lands last, enforces the rest)
S-1 (read-plane lock + modifier doc) rides alongside M-1;  S-2 (write-plane decision) after Allen picks DECISION #A.
```

---

# PHASE M — Membership = capability

## Task M-1: Read plane keys on the membership cap ALONE (drop the `member?` roster conjunct)

**Why first:** it is the independent authz change — a just-joined cap-holder who is not yet in the roster becomes readable, and a revoked ex-member with a stale roster entry is denied. It is the file epoch A-4 also touches (coordinate per DECISION #C).

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55-71` (`authorize/3`, `member_with_held_cap?/3`)
- Test: `apps/ezagent_domain_session/test/ezagent/session/membership_predicate_cap_only_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Session.MemberReceive.holds_member_cap_over?/2` (`member_receive.ex:102`), `Ezagent.EntityCaps.load/1`. If the unified `Cap.authorize/3` has landed (DECISION #C), consume it instead of the bare field-match.
- Produces: `Ezagent.Session.Membership.authorize/3` returns `:ok` iff `owner?(chat, caller) OR holds_member_cap?(caller, session_uri)` — the `:members` map is NO LONGER consulted for authz. `member?/2` remains, used only for delivery/display targeting.

- [ ] **Step 1: Write the failing tests**

```elixir
# membership_predicate_cap_only_test.exs
defmodule Ezagent.Session.MembershipPredicateCapOnlyTest do
  use Ezagent.DataCase, async: false
  alias Ezagent.Session.Membership

  test "T11: a cap-holder who is NOT in the :members roster is authorized to read" do
    {session_uri, ws} = TestSupport.spawn_session!()
    holder = TestSupport.spawn_user!(ws)
    TestSupport.grant_member_cap!(holder, session_uri)          # holds the cap
    chat = %{owner_uri: TestSupport.owner_of(session_uri), members: %{}}  # roster does NOT contain holder
    assert :ok = Membership.authorize(chat, holder, session_uri)
  end

  test "T12: a revoked ex-member with a STALE roster entry is denied (cap is the truth)" do
    {session_uri, ws} = TestSupport.spawn_session!()
    member = TestSupport.spawn_user!(ws)
    TestSupport.grant_member_cap!(member, session_uri)
    chat = %{owner_uri: TestSupport.owner_of(session_uri), members: %{member => %{online: true}}}
    assert :ok = Membership.authorize(chat, member, session_uri)   # allowed while held
    TestSupport.revoke_member_cap!(member, session_uri)            # cap gone, roster entry LINGERS
    assert {:error, :unauthorized} = Membership.authorize(chat, member, session_uri)
  end

  test "a read_unfiltered-cap holder who holds NO membership cap is denied (S-1 companion)" do
    {session_uri, ws} = TestSupport.spawn_session!()
    supervisor = TestSupport.spawn_user!(ws)
    TestSupport.grant_read_unfiltered_cap!(supervisor, session_uri)  # row-policy cap, NOT membership
    chat = %{owner_uri: TestSupport.owner_of(session_uri), members: %{}}
    assert {:error, :unauthorized} = Membership.authorize(chat, supervisor, session_uri)
  end
end
```

- [ ] **Step 2: Run to verify it fails.** `MIX_TEST_PARTITION=mship MIX_ENV=test mix test apps/ezagent_domain_session/test/ezagent/session/membership_predicate_cap_only_test.exs`
  Expected: **T11 FAILS** — `member_with_held_cap?/3` (`:69-71`) requires `member?(chat, caller)`, so a cap-holder absent from the roster is denied. T12 and the read_unfiltered case PASS on main (they are locks that must stay green after the change).

- [ ] **Step 3: Drop the `member?` conjunct.** In `membership_predicate.ex`, change line `:59` and `member_with_held_cap?/3` so authz is `owner? OR holds_member_cap?` alone:

```elixir
  def authorize(chat, caller, session_uri) do
    with %URI{} = caller <- caller,
         true <- valid_caller_uri?(caller),
         %{} = chat <- chat,
         true <- owner?(chat, caller) or holds_member_cap?(caller, session_uri) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end
```

Delete `member_with_held_cap?/3` (`:69-71`) — the roster pre-filter is gone; the held cap is the sole non-owner authority. KEEP `member?/2` (`:108-111`) — it is still used for delivery/display targeting elsewhere. Update the moduledoc (`:26-31`) to state: "membership is the durably-held member-cap; the `:members` roster is NEVER consulted for authorization." **If the unified `Cap.authorize/3` has landed (DECISION #C), route `holds_member_cap?/2` through it** so the check inherits epoch's generation + delete_user's tombstone predicates; otherwise keep the `MemberReceive.holds_member_cap_over?/2` field-match, shaped to collapse in.

- [ ] **Step 4: Run to verify pass.** All three tests PASS.

- [ ] **Step 5: Regression — the read chokepoint + publisher-read still behave.**
  Run: `MIX_TEST_PARTITION=mship MIX_ENV=test mix test apps/ezagent_domain_session/test/ezagent/session/socialware_read_held_cap_test.exs apps/ezagent_domain_socialware/test/ezagent/socialware/session_reads_test.exs apps/ezagent_domain_session/test/ezagent/behavior/socialware_publisher_read_test.exs`
  Expected: PASS (both read gates funnel through this ONE predicate — `socialware_publisher_read.ex:202` and `session_reads.ex:264`).

- [ ] **Step 6: Commit.** `feat(session): read plane authorizes on the membership cap alone, not the :members roster (#166 M-1)`

---

## Task M-2: Phase-B `add_self` handler on the Session — cap-EXEMPT at chokepoint, in-handler durable read (ADDITIVE)

The entity writes ITSELF into `:members`, gated by the Session's durable read of the caller's OWN membership cap. Additive: `handle_join`/`do_join` still writes `:members` until M-5. The monitors / `last_seen` replay / `{:member_joined}` broadcast responsibilities (spec §7.5) MOVE here (they attach to the roster write).

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — add `action(:add_self, …)` (near `:155`) + `handle_add_self/2` (near `handle_join` `:781`); add `:add_self` to `cap_exempt_actions/0` (`:328-329`).
- Modify: `apps/ezagent_core/lib/ezagent/cap/verifier.ex:34-40` — add `:add_self` to the `Ezagent.ActionSet.Session` entry of `@non_cap_actions` (**the ENFORCED list — dual-list caveat: both this AND `cap_exempt_actions/0` must list it**).
- Create: `apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex` — the `add_self` body + the in-handler durable gate.
- Test: `apps/ezagent_domain_session/test/ezagent/session/self_add_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Identity.read_entity_caps/1` (`identity.ex:327`), `Ezagent.Session.MemberReceive.holds_member_cap_over?/2` (`member_receive.ex:102`), `Ezagent.ActionSet.Session.Members.sanitize_facets/1`.
- Produces: `handle_add_self(%{member: %URI{}=caller, facets: map()}, ctx) :: {:ok, %{status: :added | :already_member}, effects} | {:error, :unauthorized}`. Writes `{:set, :members, Map.put(members, caller, meta)}` ONLY when the caller durably holds the membership cap over `self_uri`. `add_self` is `:cast`-only.

- [ ] **Step 1: Write the failing tests**

```elixir
# self_add_test.exs
defmodule Ezagent.Session.SelfAddTest do
  use Ezagent.DataCase, async: false

  test "T1: a caller with NO durable membership cap — even with a FORGED cap in ctx.caps — is denied and never added" do
    {session_uri, ws} = TestSupport.spawn_session!()
    attacker = TestSupport.spawn_user!(ws)                       # holds NO membership cap durably
    forged = TestSupport.forged_member_cap(session_uri)          # planted in ctx.caps only
    ctx = TestSupport.session_ctx(session_uri, caller: attacker, caps: MapSet.new([forged]))
    assert {:error, :unauthorized} = TestSupport.dispatch_add_self(ctx, attacker)
    refute attacker in Map.keys(TestSupport.members_of(session_uri))
  end

  test "a caller that DURABLY holds the membership cap is added exactly once (idempotent, T7)" do
    {session_uri, ws} = TestSupport.spawn_session!()
    member = TestSupport.spawn_user!(ws)
    TestSupport.grant_member_cap!(member, session_uri)
    :ok = TestSupport.cast_add_self(session_uri, member)
    :ok = TestSupport.cast_add_self(session_uri, member)         # redundant cast
    TestSupport.settle()
    assert Map.keys(TestSupport.members_of(session_uri)) == [member]  # exactly one entry
  end
end
```

- [ ] **Step 2: Run to verify it fails.** `MIX_TEST_PARTITION=mship MIX_ENV=test mix test apps/ezagent_domain_session/test/ezagent/session/self_add_test.exs`
  Expected: FAIL — `add_self`/`handle_add_self` undefined.

- [ ] **Step 3: Implement.** Declare the action and exempt it at BOTH lists:

```elixir
# session.ex — near action(:join) :155
action(:add_self,
  args: %{member: :uri, facets: :map},
  returns: %{status: :atom},
  modes: [:cast],
  description: "Entity self-adds to the :members projection AFTER it durably holds the membership cap (cap-gated in-handler)."
)

# session.ex — cap_exempt_actions/0 :328
def cap_exempt_actions,
  do: [:approve_admission, :deny_admission, :withdraw_admission, :composition_consent, :add_self]
```

```elixir
# cap/verifier.ex — @non_cap_actions :34-40 (the ENFORCED list)
Ezagent.ActionSet.Session =>
  MapSet.new([:approve_admission, :deny_admission, :withdraw_admission, :composition_consent, :add_self]),
```

```elixir
# self_add.ex — the in-handler durable gate (mirrors MemberReceive; NOT ctx.caps)
defmodule Ezagent.ActionSet.Session.SelfAdd do
  @moduledoc "Phase-B self-add: the caller writes ITSELF into :members only after a durable read proves it holds the membership cap over S. Authorized in-handler (cap-EXEMPT at the chokepoint) because member-caps are unsigned — a forged cap in ctx.caps must not clear the gate."
  alias Ezagent.ActionSet.Session.Members

  def handle_add_self(%{member: %URI{} = subject, facets: facets}, ctx) do
    session_uri = ctx[:self_uri]
    caller = ctx[:caller]
    # AUTHORIZE THE CASTER, not args — this is SELF-add. The subject must BE the
    # caller (reject a proxy adding someone else); then gate on the caller's OWN
    # durable caps. (args.member is redundant-but-checked to keep the contract
    # explicit; the security subject is ctx.caller.)
    if subject != caller do
      {:error, :unauthorized}
    else
      do_add_self(caller, session_uri, facets, ctx)
    end
  end

  defp do_add_self(%URI{} = caller, session_uri, facets, ctx) do
    held = Ezagent.Identity.read_entity_caps(caller)                       # durable, K4 provenance-filtered inside
    if Ezagent.Session.MemberReceive.holds_member_cap_over?(held, session_uri) do
      members = ctx[:read].(:members, %{})
      case Map.get(members, caller) do
        %{} = _existing -> {:ok, %{status: :already_member}, []}           # idempotent no-op
        nil ->
          meta = Map.merge(%{online: true}, Members.sanitize_facets(facets))
          new_members = Map.put(members, caller, meta)
          {:ok, %{status: :added},
           [{:set, :members, new_members} | Ezagent.ActionSet.Session.SelfAdd.Effects.on_add(caller, ctx)]}
      end
    else
      {:error, :unauthorized}                                             # no held cap ⇒ no roster write
    end
  end
end
```

Move the monitor install + `last_seen` replay + `{:member_joined}` broadcast (today emitted from `do_join_apply`, `membership.ex:459-467`) into `SelfAdd.Effects.on_add/2` so they attach to THIS roster write. (Keep the effect grammar; look up the member pid here and `Process.monitor` it, per spec §7.5.)

- [ ] **Step 4: Run to verify pass.** Both tests PASS.

- [ ] **Step 5: Guard the exemption parity + no-deadlock (T10).** Add to `self_add_test.exs`: assert `Ezagent.ActionSet.Session` lists `:add_self` in BOTH `cap_exempt_actions/0` and `Cap.Verifier`'s `@non_cap_actions` (a drift between them is the union-equality invariant break), and assert the action's `modes` is `[:cast]` (a `:call` form is the no-deadlock regression). Run the existing `receive_authz_parity_test.exs` — green.

- [ ] **Step 6: Commit.** `feat(session): cap-gated Phase-B add_self handler (in-handler durable read, cast-only) (#166 M-2)`

---

## Task M-3: Entity-side convergence — `MembershipConvergence` on the identity Kind (ADDITIVE)

The entity drives itself into the roster: on cap-land and on its own `activate`, it casts `add_self` for every session it holds a membership cap over but is not yet in. Lives on the identity Kind, dispatches a SESSION action by URI/action-string **without pinning `Ezagent.ActionSet.Session`** (dep-graph constraint — exactly like `MemberReceive`).

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/identity/membership_convergence.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:523-529` (`handle_grant_cap/2` — enqueue a convergence step when the committed cap is a `{kind: :session, action: :receive, instance: S}` cap) and `:206-221` (`activate/2` — rescan all held membership caps).
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/membership_convergence_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Identity.read_entity_caps/1`; the membership-cap FIELD shape (`kind: :session`, `action: :receive`, concrete instance) — matched by fields, no module pin.
- Produces: `Ezagent.Identity.MembershipConvergence.converge(entity_uri, held_caps) :: :ok` — for each session S where the entity holds the membership cap and `self ∉ members(S)`, dispatch `session://…?action=add_self` (`:cast`) with the entity as `member`. Idempotent; never blocks on the Session.

- [ ] **Step 1: Write the failing tests**

```elixir
# membership_convergence_test.exs
test "T5: an entity granted the membership cap eventually appears in members(S) via the self-add fast path" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  TestSupport.grant_member_cap!(member, session_uri)      # lands in member's :identity slice → handle_grant_cap fires
  TestSupport.settle()
  assert member in Map.keys(TestSupport.members_of(session_uri))
end

test "T8: once self ∈ members(S), the entity stops re-dispatching add_self" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  TestSupport.grant_member_cap!(member, session_uri)
  TestSupport.settle()
  n1 = TestSupport.add_self_dispatch_count(session_uri, member)
  TestSupport.trigger_activate(member)                    # re-entry
  TestSupport.settle()
  assert TestSupport.add_self_dispatch_count(session_uri, member) == n1  # no new dispatch once present
end
```

- [ ] **Step 2: Run → FAIL** (`MembershipConvergence` undefined; grant-land does not yet cast `add_self`).

- [ ] **Step 3: Implement `MembershipConvergence`** (cast-only, fields-not-module):

```elixir
defmodule Ezagent.Identity.MembershipConvergence do
  @moduledoc "Self-driven roster convergence (spec §3). Runs in the entity's own process. On cap-land / activate, cast add_self to each session S whose membership cap the entity durably holds but where self ∉ members(S). Idempotent, cast-only (no cross-Kind block), no Ezagent.ActionSet.Session module pin."

  def converge(%URI{} = entity_uri, held_caps) when is_list(held_caps) do
    held_caps
    |> Enum.filter(&membership_cap?/1)
    |> Enum.map(& &1.instance)
    |> Enum.uniq()
    |> Enum.each(fn session_uri ->
      unless already_member?(session_uri, entity_uri) do
        cast_add_self(session_uri, entity_uri)
      end
    end)
  end

  defp membership_cap?(%Ezagent.Capability{kind: :session} = cap),
    do: Ezagent.Capability.granted_by_entity?(cap) and Ezagent.Capability.action_of(cap) == :receive and match?(%URI{}, cap.instance)
  defp membership_cap?(_), do: false

  # dispatch by action-string, NOT Ezagent.ActionSet.Session (dep-graph constraint).
  # NOTE (kimi, verify before use — writing-plans forbids undefined APIs): confirm
  # the real action-target-URI builder + the dispatch entry against current-main —
  # the anchor table's canonical form is `<session_uri>?action=session.add_self`
  # (as `external_mirror` tests build `?action=session.join`), and dispatch is
  # `Ezagent.Invocation.dispatch/1` (invariant #1). Use the verified names; the
  # shape below is illustrative.
  defp cast_add_self(%URI{} = session_uri, %URI{} = entity_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.add_self")
    Ezagent.Invocation.dispatch(%Ezagent.Cmd{target: target, args: %{member: entity_uri, facets: %{}}, mode: :cast})
    :ok
  end
end
```

Wire the triggers: in `handle_grant_cap/2` (`identity.ex:523`), after `store_verified_cap`, if the committed cap is a membership cap, `MembershipConvergence.converge(self_uri, [cap])`; in `activate/2` (`identity.ex:206`), after the caps union, `MembershipConvergence.converge(self_uri, read_entity_caps(self_uri))`. Both are casts — never block the Session.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Confirm User + Agent + Worker identity Kinds all reach these seams** (spec §12.4). Add an assertion enumerating the identity-bearing Kinds and asserting each routes grant-land + activate through `MembershipConvergence`. Regression: existing `identity` suite green.

- [ ] **Step 6: Commit.** `feat(identity): self-driven membership convergence on cap-land + activate (cast, no module pin) (#166 M-3)`

---

## Task M-4: Lifecycle fixes (codex findings) — creation-readiness barrier + initial replay cursor + durable transitions (ADDITIVE)

Fold in codex's two lifecycle findings: **(a)** a new member must not miss the session's FIRST message (the Phase-A→B window, DECISION #D); **(b)** the join transitions are durable so a crash between grant and self-add heals without loss.

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex` (M-2) — record the member's initial replay cursor at add-self and replay messages since it.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:31-83` — stamp a durable "membership-granted-at" cursor at grant time (Phase A) so the replay floor is anchored even if self-add lags.
- Test: `apps/ezagent_domain_session/test/ezagent/session/creation_readiness_test.exs` (create)

**Interfaces:**
- Consumes: the existing `replay_messages_since` / `last_seen` machinery (`membership.ex` join replay).
- Produces: a durable per-member `:joined_cursor` (the message position at grant time). `add_self`'s effects replay every message since `:joined_cursor`, so no message between grant and convergence is missed.

- [ ] **Step 1: Write the failing test**

```elixir
# creation_readiness_test.exs
test "codex (a): a member granted the cap BEFORE the first send receives that first message after convergence" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  TestSupport.grant_member_cap!(member, session_uri)          # Phase A — records :joined_cursor
  TestSupport.send_message!(session_uri, "first")             # sent while members(S) may not yet contain member
  TestSupport.settle()                                        # Phase B converges
  assert "first" in TestSupport.received_by(member, session_uri)   # replayed from :joined_cursor, not missed
end
```

- [ ] **Step 2: Run → FAIL** — without the readiness cursor, the first message fans out to an incomplete roster and is not replayed to the late-converging member.

- [ ] **Step 3: Implement (per DECISION #D-i).** At Phase-A grant (`member_cap.ex`), capture the current message position and stamp it as the member's durable `:joined_cursor` (a per-member facet, durable). In `SelfAdd.Effects.on_add/2` (M-2), on the first add, `replay_messages_since(member, :joined_cursor)`. This makes the barrier a durable cursor, independent of the fan-out timing window. (Optionally add DECISION #D-ii eager warm on the create path — the materializer invokes reconcile after its grants — as a non-required optimization.)

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Durable-transition test (codex (b)).** Add a test: grant the cap, crash/restart the member Kind BEFORE self-add lands, and assert on `activate/2` it re-converges (self-add) and replays from the durable `:joined_cursor` — no missed message, no lost transition. (This exercises INV-CONVERGE's activate-rescan arm + durable cursor.)

- [ ] **Step 6: Commit.** `feat(session): creation-readiness barrier + durable initial replay cursor so a new member never misses the first message (#166 M-4, codex a/b)`

---

## Task M-5: CUTOVER — make `handle_join`/`do_join` grant-only (REMOVE the roster write)

Now that self-add is the proven sole writer, remove `do_join`'s `{:set, :members}` write. `handle_join` becomes: preflights (hoisted BEFORE the grant) → Phase-A mint → done. Owner-claim keeps its home on the intent step.

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:28-105` (`do_join/5` → grant-only), `:459-467` (remove the `{:set, :members, …}` effect at `:461`), hoist `role_name_conflict` (`:48`) + passive-actor + owner-claim preflights BEFORE the grant.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:781-857` (`handle_join`/`do_handle_join`) — no longer require the member to be live-registered to MINT (the cap lands in the member's identity slice; it self-adds on its own activate); keep the passive-actor gate (`:812`).
- Test: `apps/ezagent_domain_session/test/ezagent/session/join_grant_only_test.exs` (create)

**Interfaces:**
- Produces: `do_join/5` returns after minting the membership cap (Phase A) with NO `:members` write. Roster presence is achieved solely by the entity's Phase-B self-add / the reconcile floor.

- [ ] **Step 1: Write the failing tests**

```elixir
# join_grant_only_test.exs
test "T2: when the Phase-A grant FAILS, the entity NEVER appears in members(S) (no roster-without-cap window)" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  TestSupport.inject_grant_failure(member, session_uri)       # grant_cap_via_router errors
  {:error, _} = TestSupport.dispatch_join(session_uri, member)
  TestSupport.settle()
  refute member in Map.keys(TestSupport.members_of(session_uri))
end

test "handle_join writes NO :members effect (grant-only)" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  effects = TestSupport.capture_effects_of_join(session_uri, member)
  refute Enum.any?(effects, &match?({:set, :members, _}, &1))  # the roster write is gone from do_join
end
```

- [ ] **Step 2: Run → FAIL** — on main `do_join` emits `{:set, :members, …}` at `membership.ex:461`, so the second test fails; the first fails because the roster write happens even on grant-failure paths that don't reraise.

- [ ] **Step 3: Implement.** In `do_join_apply` (the `:459-467` tail), remove the `{:set, :members, new_members}` effect and the `%{members: …}` return payload's dependence on it; return the Phase-A status. Hoist `role_name_conflict` + `passive_actor?` to run BEFORE `MemberCap.grant_at_join/2` (`:88`) — a static refusal must prevent the grant (spec §9, avoids a granted-but-can-never-be-member liveness trap). Keep the async grant + compensation (`:96-102`). Give owner-claim (first non-anon user becomes owner, RFC #402) an explicit home on the intent step, orthogonal to `:members`. Facets travel to the self-add (M-2) via the grant/cursor, not the removed roster write.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: No-deadlock regression (T9).** Run the SessionCreator/materializer join path (`join_session_members`) and assert it completes with no `GenServer.call` timeout on the Session Kind (the original `:sync`-grant deadlock class stays closed). Run the full `ezagent_domain_session` suite.

- [ ] **Step 6: Commit.** `feat(session): handle_join/do_join is grant-only — the entity self-adds; roster write removed (#166 M-5 CUTOVER)`

---

## Task M-6: `:join` return contract — accepted/pending STATUS, not the post-join roster

Once `handle_join` is grant-only, a `:call` join can no longer return a roster containing the joiner (Phase B has not happened). Re-specify the return + audit `:call` sites (spec §7.6).

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:155-163` (`action(:join)` `returns:` → status) and `:843` (the idempotent `already_member` return).
- Audit + fix `:call` join sites (materializer, orchestrator, tests) that read the joiner out of the return.
- Test: `apps/ezagent_domain_session/test/ezagent/session/join_return_status_test.exs` (create)

**Interfaces:**
- Produces: `action(:join)` returns `%{status: :granted | :pending | :already_member, member: :uri}` — NOT `%{members: …}`. Membership presence is verified via `list_participants/1` / the members slice AFTER convergence, or the `{:member_joined}` broadcast.

- [ ] **Step 1: Write the failing test**

```elixir
# join_return_status_test.exs
test "T16: a :call :join returns the accepted/pending STATUS, not a roster containing the joiner" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  {:ok, result, _} = TestSupport.call_join(session_uri, member)
  assert result.status in [:granted, :pending, :already_member]
  refute Map.has_key?(result, :members)                        # the stale roster is gone from the return
end
```

- [ ] **Step 2: Run → FAIL** — on main `action(:join)` `returns: %{members: {:list, :uri}}` (`:159`) and `:843` returns `%{members: …, already_member: true}`.

- [ ] **Step 3: Implement.** Change `returns:` (`:159`) to `%{status: :atom, member: :uri}`; change the idempotent branch (`:843`) to `{:ok, %{status: :already_member, member: member_uri}, []}`; the grant path returns `%{status: :granted, member: member_uri}` (or `:pending` when admission pends). **Audit** — `git grep -n "action=session.join\|handle_join\|:members" -- apps/**/*.ex | grep -v test` for `:call` sites reading `.members` off the return (materializer `join_session_members`, orchestrator tools); update each to NOT depend on the joiner appearing in the return.

- [ ] **Step 4: Run → PASS.** Update any test asserting the joiner appears in the `:join` return.

- [ ] **Step 5: Commit.** `feat(session): :join returns accepted/pending status, not the post-join roster (#166 M-6)`

---

## Task M-7: Funnel coverage — route_provisioner bypass, approve_admission, merge_member

Every member-add path must obey Phase A/B. Close the known `route_provisioner` bypass and bring the two sibling handlers under the cap-gated seam (spec §7.2-7.4).

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/route_provisioner.ex:35-42` — re-point the direct `Membership.do_join` onto the converged Phase-A seam (mint owner-rooted; the declared-role member self-adds); preserve `system_mediated_ctx/1` (`:113`) purpose.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:314-338` (`approve_admission` → unblock Phase A, no direct `:members` write — closes the capless-mount hazard `:300-305`) and `:481-494` (`do_merge_member` per DECISION #B).
- Test: `apps/ezagent_domain_session/test/ezagent/session/funnel_coverage_test.exs` (create)

- [ ] **Step 1: Write the failing tests (T13/T14/T15)**

```elixir
# funnel_coverage_test.exs
test "T13: route_provisioner produces a member only via the converged seam (no direct :members write); the member holds the cap" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.declared_role_member(session_uri)
  effects = TestSupport.capture_route_provisioner_effects(session_uri, member)
  refute Enum.any?(effects, &match?({:set, :members, _}, &1))
  TestSupport.settle()
  assert TestSupport.holds_member_cap?(member, session_uri)
  assert member in Map.keys(TestSupport.members_of(session_uri))
end

test "T14: approve_admission mounts the member ONLY after the cap grant lands; a grant failure leaves them out" do
  {session_uri, ws, pending} = TestSupport.pending_cross_owner_member!()
  TestSupport.inject_grant_failure(pending, session_uri)
  {:error, _} = TestSupport.approve_admission(session_uri, pending)
  refute pending in Map.keys(TestSupport.members_of(session_uri))
end

test "T15: merge_member — to ∈ members ⇒ to holds the cap; from removed; read-markers repointed atomically" do
  {session_uri, from, to} = TestSupport.anon_takeover!(session_uri: nil)
  TestSupport.merge_member(session_uri, from, to)
  TestSupport.settle()
  assert TestSupport.holds_member_cap?(to, session_uri)
  assert to in Map.keys(TestSupport.members_of(session_uri))
  refute from in Map.keys(TestSupport.members_of(session_uri))
  assert TestSupport.read_markers_repointed?(session_uri, from, to)
end
```

- [ ] **Step 2: Run → FAIL** — route_provisioner writes `:members` directly (`:35-42`); approve re-runs `do_join` (`:328-329`) which — until this PR — mounts without requiring the landed cap; merge relabels directly (`:489-490`).

- [ ] **Step 3: Implement.** route_provisioner: replace the direct `do_join` with the Phase-A mint (owner-rooted) + rely on the declared-role member's self-add; keep `system_mediated_ctx`. approve_admission: on approval, ISSUE the owner-rooted grant and let the member self-add — do NOT write `:members` in the approve handler (this closes the capless-mount hole). merge_member (DECISION #B recommended): express as `grant(to)` + cap-gated self-add(`to`) + `leave(from)`, preserving the read-marker repoint atomicity (abort-on-repoint-failure).

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.** `feat(session): funnel route_provisioner/approve_admission/merge_member through the cap-gated seam (#166 M-7)`

---

## Task M-8: Migration ordering — backfill member-caps, THEN flip reconcile UNION→EVICT + extend the candidate scan

Heal the two pre-existing divergences and make `members == cap-holders` EXACT. **Ordering is mandatory** (spec §10): (1) backfill caps onto every existing roster member; (2) THEN flip reconcile from UNION to EVICT-map-only. Flipping first would evict live members.

**Files:**
- Run: `mix ezagent.migrate.member_caps` (`member_cap_migration.ex:72-96`), then `--gate` (`:103-117`) to PROVE every roster member holds the exact cap.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex:57-68` (UNION reduce → evict map-only entries that hold no cap) and `:81-85` (`candidate_uris/1` — extend to workers + anon so the floor covers EVERY membership-cap-capable type, spec §6 coverage caveat).
- Test: `apps/ezagent_domain_session/test/ezagent/session/reconcile_evict_test.exs`, `apps/ezagent_domain_session/test/ezagent/session/members_are_cap_holders_invariant_test.exs` (create)

- [ ] **Step 1: Write the failing tests (T4, T6-per-type)**

```elixir
# members_are_cap_holders_invariant_test.exs
test "T4: after migration + eviction flip, for every session members(S) ⊆ durable holders of the membership cap" do
  {session_uri, _ws} = TestSupport.session_with_map_but_no_cap_member!()   # OLD divergence
  MemberCapMigration.migrate(false)
  :ok = MemberCapMigration.gate()                                          # proves all roster members hold the cap
  TestSupport.reactivate_session(session_uri)                              # reconcile now EVICTS map-only
  members = Map.keys(TestSupport.members_of(session_uri))
  assert Enum.all?(members, &TestSupport.holds_member_cap?(&1, session_uri))
end

# reconcile_evict_test.exs
for kind <- [:user, :agent, :worker, :anon] do
  test "T6/#{kind}: with the self-add cast DROPPED and no restart, reconcile brings a #{kind} cap-holder into members (floor)" do
    {session_uri, holder} = TestSupport.cap_holder_missing_from_roster!(kind: unquote(kind))
    TestSupport.drop_add_self_cast(holder)
    TestSupport.reactivate_session(session_uri)                            # reconcile floor
    assert holder in Map.keys(TestSupport.members_of(session_uri))
  end
end
```

- [ ] **Step 2: Run → FAIL** — reconcile UNIONS (`:57-68`) so a map-but-no-cap member is NOT evicted (T4 fails); the candidate scan is users∪agents only (`:81-85`) so worker/anon holders are not swept (T6/worker, T6/anon fail).

- [ ] **Step 3: Implement — IN ORDER.** (a) run the backfill + gate (they already exist). (b) Flip the reconcile reduce so it produces `{ persisted-with-cap } ∪ { cap-holders }` = evict any persisted entry that holds no cap AND add any cap-holder missing (update the moduledoc `:16-24` — the deferred "A2 eviction" is now DONE). (c) Extend `candidate_uris/1` (`:81-85`) to include workers + anon users (or, if a type genuinely cannot be enumerated, NARROW the floor's documented guarantee for it to fast-path-only and assert that explicitly — spec §6 mandate). Keep the per-candidate rescue + fail-safe.

- [ ] **Step 4: Run → PASS** (all T6 variants + T4).

- [ ] **Step 5: Migration-ordering guard.** Add a test asserting the gate (`gate/0`) returns `:ok` (every roster member holds the exact cap) BEFORE the eviction flip is exercised — i.e. a test that eviction on an un-backfilled roster would drop a live member (documenting WHY the order is mandatory).

- [ ] **Step 6: Commit.** `feat(session): backfill member-caps then flip reconcile UNION→EVICT + cover workers/anon (#166 M-8)`

---

## Task M-9: The members-not-authority enumerator gate + presence tripwire

Prove the roster is gone as a truth source: no authorization decision reads `:members`. Model on `no_surface_read_dispatch_test.exs` (`@probes`, `assert offenders == []`) + `check_invariant_10`'s presence-grep.

**Files:**
- Create: `apps/ezagent_core/test/invariants/members_not_authority_test.exs`
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` (add invariant #N — presence of the cap-based check in the read/receive predicates)
- Test support: `apps/ezagent_core/test/support/members_not_authority_probes.ex` (create; mirror `no_surface_read_dispatch_probes.ex`)

**Interfaces:** a source-scan (`%{id, desc, pattern, allowlist}` over `apps/*/lib/**/*.ex`, no BEAM):
- **Non-leakage probe:** every read of the `:members` map (`ctx[:read].(:members …)`, `Map.has_key?(members, …)`, `member?/2`, `.members`) that feeds an AUTHORIZATION decision must be in an explicit reviewed allowlist. Allowed (delivery/display, NOT authority): the fan-out targeting at `session.ex:497`, the UI roster reads (`conversation_data.ex:394-405`, `:118-134`), and `member?/2` used only for targeting. The authz sites (`membership_predicate.ex`, `member_receive.ex`, `socialware_publisher_read.ex`, `session_reads.ex`) must NOT read `:members`.
- **Presence tripwire (positive):** fail the build if `membership_predicate.ex`'s `authorize/3` no longer contains the `holds_member_cap?` cap-based check (guards against a silent regression back to a roster read).

- [ ] **Step 1: Write the gate with an EMPTY authority-allowlist → run → it lists every remaining `:members` authority-read** (the worklist; RED until M-1/M-7 land). Record the list in the PR body.
- [ ] **Step 2: Add the presence tripwire; run `mix ezagent.check_invariants` → the new invariant passes** (the predicate contains the cap check).
- [ ] **Step 3: Iterate the allowlist to exactly the reviewed delivery/display exemptions**; the gate goes GREEN only when NO authz site reads `:members`. Commit `test(session): members-not-authority enumerator + presence tripwire (#166 M-9)`.

---

# PHASE S — Supervisor middle-state

## Task S-1: Read-plane lock test + `read_unfiltered`-as-modifier documentation (records the option-iii drop)

The read plane already denies non-member `read_unfiltered`-holders (the chokepoint denies non-members before row-policy). This PR LOCKS that denial across the M-1 change and documents `read_unfiltered` as a row-policy modifier, not an access gate. It has no fail-before code change on the read plane — it is a regression guard + doc (option iii was never merged; nothing to remove).

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:441-473` (moduledoc/comment on `read_unfiltered?/2` — clarify it is a POST-authorize row-policy modifier applied only to already-authorized readers; a non-member never reaches it).
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/read_unfiltered_not_a_gate_test.exs` (create)

- [ ] **Step 1: Write the lock tests**

```elixir
# read_unfiltered_not_a_gate_test.exs
test "a non-member holding ONLY read_unfiltered is denied session read at the chokepoint (before AND after M-1)" do
  {session_uri, ws} = TestSupport.spawn_session!()
  supervisor = TestSupport.spawn_user!(ws)
  TestSupport.grant_read_unfiltered_cap!(supervisor, session_uri)   # row-policy cap, NO membership cap
  assert {:error, :unauthorized} = TestSupport.session_reads_authorize(supervisor, session_uri)
  assert {:error, _} = TestSupport.session_reads_messages(supervisor, session_uri)  # never reaches read_unfiltered?
end

test "read_unfiltered only widens rows for an already-authorized MEMBER" do
  {session_uri, ws} = TestSupport.spawn_session!()
  member = TestSupport.spawn_user!(ws)
  TestSupport.grant_member_cap!(member, session_uri)
  TestSupport.grant_read_unfiltered_cap!(member, session_uri)
  assert TestSupport.reads_internal_rows?(member, session_uri)      # member + read_unfiltered ⇒ unfiltered
end
```

- [ ] **Step 2: Run → both PASS on main** (this is a lock, not a fail-before). Record in the PR body that these guard the invariant across M-1.
- [ ] **Step 3: Add the doc** clarifying `read_unfiltered` is a modifier, and record that read-plane-hardening option iii ("add a supervisor-read branch" to `Membership.authorize/3`) is DROPPED — the read plane stays cap-gated on membership; a supervisor reads a session only by being a member.
- [ ] **Step 4: Re-run after M-1 lands to confirm the lock still passes** (a non-member supervisor is still denied — now because they lack the MEMBERSHIP cap, not the roster).
- [ ] **Step 5: Commit.** `test(socialware): lock read_unfiltered as a row-policy modifier, not an access gate; drop supervisor-read branch (#166 S-1)`

---

## Task S-2: DECISION-FOR-ALLEN — the moderation model + the write-plane asymmetry (GATED on DECISION #A)

Resolve the middle state on the WRITE plane. This PR is GATED: it lands code only after Allen picks a moderation model (DECISION #A). It carries the recommended path (Option 1 — reviewer-membership) as the default.

**Files (under Option 1 — recommended):**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/supervisor_approval.ex:52-59` — additionally require the actor be a member (holds the membership cap over S), OR grant the membership cap when a supervisor is assigned to a specific session.
- Modify: the turn/surface content verbs (`apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`, `.../surface.ex`) — require session membership to act on a specific session's content.
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignment.ex:123-136` — if Option 1, add the membership cap (a reviewer-membership facet) to the per-session supervisor bundle so an assigned supervisor becomes a real member.
- Test: `apps/ezagent_domain_session/test/ezagent/session/supervisor_is_member_test.exs` (create)

- [ ] **Step 1: Present DECISION #A to Allen** (the three options + Option-1 recommendation, verbatim from the DECISIONS section). **Do NOT write code until Allen chooses.** This is the key decision Allen reads first (`feedback_no_tui_use_feishu` — present in Feishu with options inline).

- [ ] **Step 2 (Option 1 chosen): Write the failing test**

```elixir
# supervisor_is_member_test.exs
test "a supervisor assigned to a session becomes a real member (holds the membership cap) with read + moderate access; a non-member supervisor cannot moderate its content" do
  {session_uri, ws} = TestSupport.spawn_session!()
  sup = TestSupport.spawn_user!(ws)
  # Not yet assigned to THIS session: cannot moderate its content.
  assert {:error, _} = TestSupport.submit_verdict(sup, session_uri)
  # Assign the reviewer-membership → holds the membership cap → is a member.
  TestSupport.assign_supervisor!(sup, ws, session_uri)
  TestSupport.settle()
  assert TestSupport.holds_member_cap?(sup, session_uri)
  assert :ok = TestSupport.session_reads_authorize(sup, session_uri)     # reads as a member
  assert {:ok, _, _} = TestSupport.submit_verdict(sup, session_uri)      # moderates as a member
end
```

- [ ] **Step 3: Run → FAIL** — on main the supervisor can `submit_verdict` (write plane) without membership and CANNOT read (asymmetry).
- [ ] **Step 4: Implement Option 1** — grant the membership cap in the per-session supervisor bundle (reviewer-membership) so the supervisor is a member on both planes; require membership for the content verbs. The write-plane `assigned?/3` gate stays as a defense-in-depth but is no longer the SOLE authority — membership is.
- [ ] **Step 5: Run → PASS.** Update `supervisor_approval_test.exs` + `socialware_p10_codex_gate_test.exs` for the member-supervisor model.
- [ ] **Step 6: Commit.** `feat(workspace): supervisors are real members via reviewer-membership; eliminate the review-but-not-member middle state (#166 S-2, Option 1)`

---

## Acceptance matrix (spec §11 tests → task)

| Spec test | Assertion | Task |
|---|---|---|
| T1 | forged `ctx.caps` add_self denied; never in `members` | M-2 |
| T2 | grant failure ⇒ never in `members` (no roster-without-cap) | M-5 |
| T3 | reconcile unions ONLY exact holders (admin `:any` not added) | M-8 (preserved from `member_cap_holder?/3`) |
| T4 | invariant scan: `members(S) ⊆ durable holders` | M-8 + M-9 |
| T5 | granted entity converges via self-add fast path | M-3 |
| T6 (per type) | dropped cast + no restart ⇒ reconcile floor converges (user/agent/worker/anon) | M-8 |
| T7 | idempotent — exactly one `members` entry | M-2 |
| T8 | termination — stop re-dispatching once present | M-3 |
| T9 | full join, no `GenServer.call` timeout | M-5 |
| T10 | `add_self` is `:cast`; `:call`/blocking trigger rejected | M-2 |
| T11 | just-joined member (cap held, roster not observed) can READ | M-1 |
| T12 | revoked member denied read AND receive immediately | M-1 |
| T13 | route_provisioner via converged seam; holds cap | M-7 |
| T14 | approve_admission mounts only after cap lands | M-7 |
| T15 | merge_member: `to ∈ members ⇒ to holds cap`; markers atomic | M-7 |
| T16 | `:call` `:join` returns status, not roster | M-6 |
| codex (a) | new member never misses the first message | M-4 |
| codex (b) | durable do_join transitions (crash-heal) | M-4 |
| Supervisor middle-state | read_unfiltered-holder-non-member denied read; write-plane asymmetry resolved | S-1, S-2 |

---

## Self-Review (against spec §1-§13 + the task directives, fresh eyes)

- **§2 model (cap = truth; members = derived projection):** M-1 (read keys on cap), M-2 (self-add cap-gated), M-5 (grant-only join), M-8 (reconcile = cap-holder set). ✔ `:members` STAYS as delivery/facet cache (Global Constraints), dropped only as authority (M-9 gate). ✔
- **§3 convergence state machine:** M-3 (handle_grant_cap + activate triggers, cast add_self), M-8 (reconcile floor). ✔ Termination = `self ∈ members` (T8). ✔
- **§4 fail-closed proof (3 adders each cap-gated):** self-add in-handler durable read (M-2), reconcile exact-holder (M-8), merge relabel cap-gated (M-7). ✔ Adder classification honored; `handle_assign_role` (`:897-911`) is a MUTATOR (guarded by `require_joined_member` `:925`), not an adder — untouched. ✔
- **§5 no-deadlock:** async grant kept (M-5); add_self `:cast` + non-blocking triggers (M-2/M-3); T9/T10. ✔
- **§6 idempotency + reconcile floor + coverage caveat:** M-8 extends candidate scan to workers/anon or narrows the guarantee explicitly; T6 per-type. ✔
- **§7 funnel (every add path):** M-5 (do_join grant-only), M-7 (route_provisioner bypass, approve, merge), M-6 (return contract). ✔ Displaced responsibilities (monitors/replay/broadcast → add_self, owner-claim → intent) homed in M-2/M-5. ✔
- **§8 read/receive plane keys on cap:** M-1 (drop `member?` conjunct); receive plane already correct (`MemberReceive`). ✔ Both read gates funnel through the ONE predicate (`membership_predicate.ex`). ✔
- **§9 termination-liveness hazard:** static refusals hoisted BEFORE the grant (M-5); no post-grant stuck cap-holder. ✔
- **§10 migration ordering:** backfill THEN evict (M-8), mandatory order guarded. ✔
- **§11 tests T1-T16:** mapped in the acceptance matrix. ✔
- **§12 open questions:** #1 create-path first message → M-4 + DECISION #D; #2 live-vs-snapshot gate → live+cast (M-2); #3 merge shape → DECISION #B (M-7); #4 where convergence lives → M-3 (shared module, FIELDS not module pin); #5 join-cap vs member-cap distinct → M-5/M-6. ✔
- **Task directives — supervisor:** read_unfiltered not an access gate (S-1, already true + locked); middle state dissolved (member IFF holds membership cap); DECISION #A (3 options + Option-1 recommendation); write-plane asymmetry flagged + carried to S-2; option-iii read-branch DROPPED. ✔
- **Task directives — convergence:** membership check rides unified `authorize/3` as a predicate alongside epoch's gen + delete_user's tombstone (Architectural convergence + DECISION #C); roster-drop can begin independently; authz-site integration composes. ✔
- **Task directives — acceptance:** members-not-authority enumerator (M-9); membership == holds-cap uniformly; read_unfiltered-holder-non-member denied (S-1/M-1); lifecycle fixes (M-4); fail-closed, no deadlock (async/cast). ✔

**Placeholder scan:** every task cites real current-main file:line and shows test + implementation locus; no "add error handling"/"similar to Task N" placeholders. **Type consistency:** `holds_member_cap_over?/2`, `read_entity_caps/1`, `handle_add_self/2`, `MembershipConvergence.converge/2`, `members(S)`, the membership-cap FIELD shape (`kind: :session, action: :receive, instance: S`) used consistently across M-1…M-9/S.

**Known residuals (flag for codex):** (1) DECISION #C is a merge-order fact — M-1 must coordinate with epoch A-4 / delete_user PR-6 on `membership_predicate.ex` + `member_receive.ex`. (2) DECISION #A is the key product decision — S-2's code is GATED on Allen. (3) The spec's `runtime.ex:362-411 granted_via_holds_cap?` cite is stale — the real chokepoint is `Cap.Verifier` (ctx.caps only), which is WHY add_self must be cap-EXEMPT + in-handler durable-read (M-2), and WHY both exemption lists must be edited.

---

**Codex review asks (architecture, per `feedback_codex_spec_review_architecture_not_details`):**
1. **DECISION #A** — is Option 1 (reviewer-membership; supervisor is a real member) the right dissolution of the middle state, and is removing session-content authority from non-member supervisors on the WRITE plane the correct consistency fix?
2. Is the ADDITIVE-first sequencing (M-2/M-3/M-4 before the M-5 cutover) the right way to avoid the authorized-but-invisible window, and is M-5 safe to land only after self-add is the proven sole writer?
3. Is riding the unified `authorize/3` (DECISION #C) the correct convergence, and does M-1 collapse cleanly into it without a double-gate against epoch/delete_user?
4. Is the M-8 backfill→evict ordering + workers/anon scan coverage the complete floor, or does any membership-cap-capable type still rely on the fast path only?
5. **DECISION #B** — merge_member as grant+self-add+leave vs a dedicated relabel handler, preserving read-marker atomicity.
