# Capability/Auth Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the authentication escalation and capability truth-source gaps found around PR #1402 while keeping EntityCaps, authorization readers, display projections, signing enforcement, and operations independently reviewable.

**Architecture:** Land the already-isolated HomeLive fail-closed fix first. Build EntityCaps A/B/D as a separate prerequisite from current `main`, then migrate downstream readers in a dedicated follow-up branch with one logical commit per task. Keep capability-signing no-tail migration and enforcement in an isolated operations PR.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix LiveView 1.8, Ecto/PostgreSQL, ExUnit, Ezagent CapBAC/Kind/Identity/EntityCaps.

## Global Constraints

- Base every implementation branch on the latest `origin/main`; never continue from PR #1402 or its branch.
- User physical SSOT remains `users.caps_json`; Agent physical SSOT remains the Identity snapshot.
- `Ezagent.EntityCaps` wraps the two physical stores; it does not create a third store or perform a physical unification.
- Authorization reads are receiver-aware and signature-verified.
- Malformed, stale, missing, or wrong-kind identity input fails closed and never falls back to admin.
- Signed or provenance-bearing capability artifacts are created only through `Ezagent.Cap.issue/3`.
- `require_signature: true` stays disabled until the real-data audit reports zero unsigned authorizer capabilities, zero invalid signatures, and zero receiver mismatches.
- Auth invariant or data-migration changes require a real canary-data E2E before enforcement is enabled.
- Each PR must be independently reviewable, rebased on current `main`, and green under the project gates.

## Sources and Status

- PR #1402 is merged and supplies the AgentRuntime boundary gate plus the temporary verified LiveAuth reader.
- PR #1394 is merged and owns the scoped EntityCaps A/B/D design and handoff:
  `docs/superpowers/plans/2026-07-14-entity-caps-scoped-impl-plan.md`.
- PR #1404 is merged and assigns EntityCaps A/B/D and no-tail work to the lead/Codex track:
  `docs/together/2026-07-15/plan.md`.
- PR #1403 contains Task 1 and is open with deterministic CI green at the time this plan is written.
- PR #1386 remains the separate grantee-signing track consumed by EntityCaps at the STORE boundary.
- The 2026-07-14 draft at commit `a7f1eb0ab` is historical input only; this document supersedes it.

## PR Topology

| Order | Branch | Scope | Dependency |
|---|---|---|---|
| 1 | `fix/home-live-fail-closed` | Task 1, PR #1403 | none; merge first |
| 2 | `feat/entity-caps-scoped` | EntityCaps A/B/D prerequisite | latest `main`; coordinate #1386 STORE boundary |
| 3 | `fix/capability-auth-followups` | Tasks 2–6, one logical commit per task | EntityCaps prerequisite merged |
| 4 | `ops/cap-signing-no-tail` | Task 7 migration, audit, canary, enforcement | signing implementation landed; real-data audit clean |

Do not append EntityCaps or downstream reader changes to PR #1403. Do not append no-tail migration or enforcement to the reader/UI follow-up PR.

---

### Task 1: AUTH-FAIL-1 — Publish HomeLive fail-closed behavior

**Status:** Implemented in PR #1403 (`fix/home-live-fail-closed`).

**Files:**
- Modified: `apps/ezagent_web/lib/ezagent_web/live/home_live.ex`
- Modified: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`
- Modified: `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs`
- Modified: `apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`
- Created: `apps/ezagent_web/test/invariants/home_live_no_admin_fallback_test.exs`

**Produces:** Invalid or unresolvable authenticated identity state is cleared and redirected to login without acquiring `entity://system/user/admin` authority.

- [ ] **Step 1: Merge PR #1403 only after protected checks remain green**

```bash
gh pr view 1403 --json state,mergeStateStatus,reviewDecision,statusCheckRollup,url
```

Expected: required checks are `SUCCESS`; unresolved review findings are absent.

- [ ] **Step 2: Record the merge SHA in the implementation handoff**

Do not mark this task complete merely because the PR is open or CI is green.

### Task 2: Build and accept the EntityCaps A/B/D prerequisite

**Authoritative plan:** `docs/superpowers/plans/2026-07-14-entity-caps-scoped-impl-plan.md`.

**Files:**
- Create/modify under: `apps/ezagent_core/` for durable cap delivery A
- Create/modify under: `apps/ezagent_domain_identity/` for EntityCaps D and OutboundGrant B
- Add migrations and focused tests in the owning applications
- Add an architecture gate forbidding new raw capability-store access outside approved boundaries

**Produces:**
- A: durable retry for only `:absorb_cap` and `:revoke_cap`
- B: one shared `Ezagent.OutboundGrant` record and query/revoke API
- D: `Ezagent.EntityCaps.load/1`, `persist/2`, `grant/2`, and `revoke/2`

- [ ] **Step 1: Create the prerequisite branch from current main**

```bash
git fetch origin main
git switch -c feat/entity-caps-scoped origin/main
```

- [ ] **Step 2: Implement A, B, and D as bounded commits**

Follow the #1394 plan exactly. Preserve `users.caps_json` and Identity snapshots as their physical stores. Do not add a compatibility wrapper or a third store.

- [ ] **Step 3: Prove the durability and facade matrix**

For both User and Agent principals, test:

```text
load online → grant → load → revoke → stop → restart → load
```

Expected: the grant is visible before revoke and never resurrects after restart. A cap grant/revoke queued while its target is unavailable survives process/application restart and is retried until applied.

- [ ] **Step 4: Verify the architecture boundary**

Expected: the new gate rejects newly introduced direct `users.caps_json` access and raw snapshot-cap mutation outside `Ezagent.EntityCaps` and explicitly approved migration code.

- [ ] **Step 5: Run gates, commit, and open the prerequisite PR**

```bash
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
SHELL=/bin/bash mix precommit
git diff --check
```

### Task 3: Converge LiveAuth on EntityCaps and close the cold matrix

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/live_auth.ex`
- Modify: `apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs`

**Consumes:** The accepted `Ezagent.EntityCaps.load/1` contract from Task 2.

**Produces:** `socket.assigns.current_caps` is a receiver-aware verified `MapSet` for online and cold User/Agent principals.

- [ ] **Step 1: Add failing User and Agent matrix tests**

Cover online grant, cold load, revoke, stop/restart, invalid signature, and a valid signature bound to the wrong receiver. Invalid or wrong-receiver artifacts must never enter `current_caps`.

- [ ] **Step 2: Replace only the temporary reader**

Change `load_caps/1` to use `Ezagent.EntityCaps.load/1`. Reader failure returns an empty `MapSet`; it must not fall back to `Users.get_by_uri/1`, raw `caps_json`, or raw snapshots.

- [ ] **Step 3: Run focused tests and commit**

```bash
mix test apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs
git commit -am "fix(web): converge LiveAuth on EntityCaps"
```

### Task 4: Verify Session member-cap idempotency reads

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex`
- Modify: `apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs`
- Create: `apps/ezagent_domain_session/test/invariants/member_cap_verified_reader_test.exs`

**Produces:** Join idempotency is based only on verified capability identity keys.

- [ ] **Step 1: Add invalid-signature and wrong-receiver fixtures**

Persist each artifact in a member store and prove neither suppresses the required join grant.

- [ ] **Step 2: Replace the raw snapshot reader**

Use `Ezagent.EntityCaps.load/1` and compare `Ezagent.Capability.identity_key/1`. Reader failure means “grant not observed,” never authorization success.

- [ ] **Step 3: Pin and test the boundary**

The invariant forbids `SnapshotStore.latest/1` in capability-specific production reader functions in `member_cap.ex`.

```bash
mix test apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs \
  apps/ezagent_domain_session/test/invariants/member_cap_verified_reader_test.exs
git commit -am "fix(session): verify member capability idempotency reads"
```

### Task 5: Converge World capability counts

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex`
- Create: `apps/ezagent_plugin_world/test/ezagent/world/user_data_caps_test.exs`

**Produces:** `cap_count` reflects verified entity capabilities rather than raw serialized rows.

- [ ] **Step 1: Add projection-divergence regressions**

Cover a verified runtime grant not represented by the old projection and a revoked artifact still present in legacy serialized data.

- [ ] **Step 2: Count the EntityCaps result**

Resolve the user URI from existing row data and count the verified `MapSet`. Reader failure reports zero; no raw-store fallback is allowed.

- [ ] **Step 3: Test and commit**

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/user_data_caps_test.exs
git commit -am "fix(world): count verified entity capabilities"
```

### Task 6: Decide and pin the email inbound authority boundary

**Files:**
- Modify after decision: `apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex`
- Modify: `apps/ezagent_plugin_email/test/inbound_principal_test.exs`
- Create: `apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs`

**Produces:** One reviewed authority model restricted to one session, workspace, receiver, and send action.

- [ ] **Step 1: Record one explicit decision before implementation**

Choose either the reviewed transport exception or formal issuance via `Ezagent.Cap.issue/3`. Reject wildcard instance, action, behavior, receiver, or workspace axes.

- [ ] **Step 2: Add exact-shape tests**

Assert one cap, receiver equals the inbound principal, instance equals the concrete session URI, workspace derives from that session, and action equals send.

- [ ] **Step 3: Add the matching invariant**

If retaining the exception, pin its only constructor file and exact axes. If migrating, forbid direct `%Ezagent.Capability{}` construction in `inbound/principal.ex`.

- [ ] **Step 4: Test and commit**

```bash
mix test apps/ezagent_plugin_email/test/inbound_principal_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs
git commit -am "fix(email): pin inbound authority provenance"
```

### Task 7: Complete capability-signing no-tail migration

**Files:**
- Read: `docs/superpowers/handoffs/2026-07-14-cap-signing-notail-upgrade-codex-handoff.md`
- Read: `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md`
- Extend the landed audit/re-provision task identified by the handoff
- Create: `docs/guide/cap-signing-no-tail-upgrade.md`
- Create a dated return under: `docs/together/2026-07-15/returns/`

**Produces:** Signed receiver-bound authorizer artifacts only, with a reversible migration and evidence-backed enforcement decision.

- [ ] **Step 1: Back up every mutable capability store**

Record row counts, snapshot counts, unsigned counts by store, backup location, restore command, and checksum before mutation.

- [ ] **Step 2: Re-derive through normal issuance**

Reissue only when original authority and receiver are provable. Quarantine unprovable artifacts; never blind-sign legacy bytes.

- [ ] **Step 3: Audit the no-tail condition on real canary data**

Expected:

```text
unsigned authorizer capabilities = 0
invalid signatures = 0
receiver mismatches = 0
```

- [ ] **Step 4: Flip enforcement only after the audit is clean**

Enable `require_signature: true`, restart, run authorization smoke tests, and immediately execute the recorded rollback if any verified principal loses expected authority.

### Task 8: Full gate and per-PR handoff

**Files:**
- Create one dated return under `docs/together/2026-07-15/returns/` per implementation PR.

- [ ] **Step 1: Run the complete project gate set on each PR head**

```bash
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
SHELL=/bin/bash mix precommit
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Rebase on current main and rerun impacted tests**

```bash
git fetch origin main
git rebase origin/main
```

- [ ] **Step 3: Request independent review**

No implementation PR is ready with an unresolved Critical or Important finding.

- [ ] **Step 4: Record immutable evidence**

Each return records the base SHA, head SHA, PR URL, protected CI URL, focused-test output, full-gate result, DoD reconciliation, canary evidence where required, rollback procedure for mutable data, and deferred work.

## Execution Order

1. Merge PR #1403.
2. Build and merge `feat/entity-caps-scoped` from the then-current `main`.
3. Create `fix/capability-auth-followups` from the then-current `main`.
4. Complete Tasks 3–6 as separate logical commits; Tasks 4 and 5 may be developed independently, but one shared PR must remain reviewable and green after every commit.
5. Run Task 8 for the reader/UI follow-up PR.
6. Execute Task 7 in `ops/cap-signing-no-tail` with its own rollback/canary review and Task 8 handoff.

## Out of Scope

- ARB-2 through ARB-5 AgentRuntime migrations; they retain their own branch and review track.
- Physical unification of User and Agent capability storage.
- A synchronous capability ACK protocol; EntityCaps A implements durable retry and leaves only the approved configuration hook.
- P5 mount rebuild, `socialware_mounts`, and #1376 changes; those follow A+B+C+D under the separate EntityCaps plan.
- Demo stabilization and cc-PTY bridge-join work.
