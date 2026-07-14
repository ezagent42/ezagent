# Capability/Auth Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the authentication escalation and capability truth-source gaps found during PR #1402 without mixing independent authority, display, signing, and operational concerns.

**Architecture:** Ship a queue of independently reviewable PRs. Fix `HomeLive` fail-closed behavior immediately; then consume the lead-owned `Ezagent.EntityCaps` facade for durable User/Agent capability semantics before converging LiveAuth and secondary readers. Keep signing enforcement, AgentRuntime debt reduction, and canary acceptance on separate tracks.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix LiveView 1.8, Ecto/PostgreSQL, ExUnit, Ezagent CapBAC/Kind/Identity/EntityCaps.

## Global Constraints

- Base each task branch on the latest `origin/main`; never stack new work on PR #1402.
- User physical SSOT remains `users.caps_json`; Agent physical SSOT remains Identity snapshot.
- All authorization reads are receiver-aware and verified.
- Never fall back to admin for malformed/stale identity input.
- Never construct signed/provenance-bearing capabilities outside `Ezagent.Cap.issue/3`.
- Do not enable `require_signature: true` until unsigned authorizer capability count is zero.
- Use `Req` for any HTTP work; add no HTTP dependency.
- Before canary mutation, record backup, rollback, and integrity-verification commands.

---

### Task 0: Close PR #1402 handoff

**Files:**
- Modify after CI/review: `docs/together/2026-07-14/returns/gagameow-agent-runtime-boundary.md`
- Modify after CI/review: `docs/together/2026-07-14/gagameow-agent-runtime-boundary-homework.md`

**Interfaces:**
- Consumes: PR #1402 checks and review decision.
- Produces: a valid dev-together return with immutable PR/check URLs.

- [ ] **Step 1: Confirm protected checks and review state**

Run:

```bash
gh pr view 1402 --json state,mergeStateStatus,reviewDecision,statusCheckRollup,url
```

Expected: all required check conclusions are `SUCCESS`; `reviewDecision` becomes
`APPROVED` before merge. Do not describe `REVIEW_REQUIRED` as merge-ready.

- [ ] **Step 2: Reconfirm the branch is based on current main**

Run:

```bash
git fetch origin main
git rev-list --left-right --count HEAD...origin/main
```

Expected: `<ahead> 0`. If behind is nonzero, rebase and rerun full verification.

- [ ] **Step 3: Write final return evidence**

Replace the pending CI row with the deterministic gate URL and `SUCCESS`; record
the final rebase SHA and review URL. Do not mark deferred ARB-2..ARB-5 or canary
acceptance as complete.

- [ ] **Step 4: Commit the evidence update**

```bash
git add docs/together/2026-07-14/returns/gagameow-agent-runtime-boundary.md \
  docs/together/2026-07-14/gagameow-agent-runtime-boundary-homework.md
git diff --cached --check
git commit -m "docs(together): finalize PR 1402 return evidence"
git push
```

### Task 1: AUTH-FAIL-1 — HomeLive identity input fails closed

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:57-91,239-258`
- Modify: `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs`
- Create: `apps/ezagent_web/test/invariants/home_live_no_admin_fallback_test.exs`

**Interfaces:**
- Consumes: session key `"current_entity_uri"` and existing login route.
- Produces: authenticated mount continues only with a parsed `entity://` URI;
  invalid/stale input halts and redirects without an admin principal.

- [ ] **Step 1: Add failing mount regressions**

Add isolated cases for `"not-a-uri"`, `"workspace://system"`, and a syntactically
valid entity URI whose principal no longer exists. Assert the mount halts or
redirects to `/login`, and assert the session-creation callback is never invoked.

- [ ] **Step 2: Prove the old behavior fails**

```bash
mix test apps/ezagent_web/test/ezagent_web/live/home_live_test.exs
```

Expected before implementation: at least the malformed-cookie case proceeds as
`entity://system/user/admin`, so the new assertion fails.

- [ ] **Step 3: Replace admin fallback with an explicit parse result**

Make the parser return `{:ok, %URI{scheme: "entity"} = uri}` or
`{:error, :invalid_identity}`. Handle the error in mount/event flow by clearing
authentication state through the existing auth mechanism and redirecting to
`/login`. Delete every malformed-cookie call to `Entity.User.admin_uri/0`.

- [ ] **Step 4: Add the structural invariant**

The invariant reads `home_live.ex` and fails if `parse_entity_uri` or its error
branch references `Entity.User.admin_uri`. It must allow explicit admin login
fixtures elsewhere in the module.

- [ ] **Step 5: Run focused tests and commit**

```bash
mix format apps/ezagent_web/lib/ezagent_web/live/home_live.ex \
  apps/ezagent_web/test/ezagent_web/live/home_live_test.exs \
  apps/ezagent_web/test/invariants/home_live_no_admin_fallback_test.exs
mix test apps/ezagent_web/test/ezagent_web/live/home_live_test.exs \
  apps/ezagent_web/test/invariants/home_live_no_admin_fallback_test.exs
git add apps/ezagent_web/lib/ezagent_web/live/home_live.ex \
  apps/ezagent_web/test/ezagent_web/live/home_live_test.exs \
  apps/ezagent_web/test/invariants/home_live_no_admin_fallback_test.exs
git commit -m "fix(web): fail closed on invalid HomeLive identity"
```

### Task 2: Accept and verify the EntityCaps A/D dependency

**Files:**
- Inspect landed facade under: `apps/ezagent_domain_identity/lib/ezagent/`
- Inspect landed tests under: `apps/ezagent_domain_identity/test/`
- Create review notes under: `docs/together/2026-07-14/`.

**Interfaces:**
- Consumes: lead-owned EntityCaps A/D PRs.
- Produces: confirmed common API for `load`, `persist`, `grant`, and `revoke`, plus
  evidence that User and Agent restart semantics are durable.

- [ ] **Step 1: Rebase only after the dependency lands**

```bash
git fetch origin main
git rebase origin/main
rg -n "defmodule Ezagent.EntityCaps|def (load|persist|grant|revoke)" apps/ezagent_domain_identity
```

Expected: one facade owns the common API; no third capability store exists.

- [ ] **Step 2: Run the dependency's durability matrix**

Run its focused tests and confirm both principals cover:

```text
load online → grant → load → revoke → stop → restart → load
```

Expected: the grant appears before revoke and never reappears after restart.

- [ ] **Step 3: Stop on contract divergence**

If User storage is moved away from `caps_json`, Agent storage is moved away from
snapshot, verification is not receiver-aware, or revoke can resurrect after
restart, do not build a compatibility wrapper. Return the dependency for review.

### Task 3: Migrate LiveAuth to EntityCaps and close the cold matrix

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/live_auth.ex:335-359`
- Modify: `apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs`

**Interfaces:**
- Consumes: the exact EntityCaps load function accepted in Task 2.
- Produces: `socket.assigns.current_caps` as a receiver-aware verified `MapSet` for
  online and cold User/Agent principals.

- [ ] **Step 1: Extend tests before changing the reader**

Add User and Agent cases for online grant, cold load, revoke, stop/restart, and
wrong-receiver signed artifact. The wrong-receiver artifact must never enter
`current_caps`.

- [ ] **Step 2: Run tests against the temporary reader**

```bash
mix test apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs
```

Expected: at least one cold/restart case fails before facade migration.

- [ ] **Step 3: Replace the temporary Identity call**

Change only `load_caps/1` to use the accepted EntityCaps load API. Preserve the
empty `MapSet` error result; do not fall back to `Users.get_by_uri/1`.

- [ ] **Step 4: Run and commit the complete matrix**

```bash
mix format apps/ezagent_web/lib/ezagent_web/live_auth.ex \
  apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs
mix test apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs
git add apps/ezagent_web/lib/ezagent_web/live_auth.ex \
  apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs
git commit -m "fix(web): converge LiveAuth on EntityCaps"
```

### Task 4: Verify Session member-cap idempotency reads

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:227-245`
- Modify: `apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs`
- Create: `apps/ezagent_domain_session/test/invariants/member_cap_verified_reader_test.exs`

**Interfaces:**
- Consumes: EntityCaps nonblocking verified load API.
- Produces: join idempotency based only on verified capability identity keys.

- [ ] **Step 1: Add invalid-signature and wrong-receiver fixtures**

Persist each artifact in a member snapshot and prove neither suppresses the
required join grant.

- [ ] **Step 2: Replace `SnapshotStore.latest/1` cap decoding**

Call the common verified reader and compare only
`Ezagent.Capability.identity_key/1`. Preserve the current best-effort behavior:
reader failure means “grant not observed”, never authorization success.

- [ ] **Step 3: Pin the boundary and commit**

The invariant forbids `SnapshotStore.latest` in capability-specific production
reader functions under `member_cap.ex`.

```bash
mix test apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs \
  apps/ezagent_domain_session/test/invariants/member_cap_verified_reader_test.exs
git add apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex \
  apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs \
  apps/ezagent_domain_session/test/invariants/member_cap_verified_reader_test.exs
git commit -m "fix(session): verify member capability idempotency reads"
```

### Task 5: Converge World capability counts

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex:20-76`
- Create: `apps/ezagent_plugin_world/test/ezagent/world/user_data_caps_test.exs`

**Interfaces:**
- Consumes: EntityCaps verified load API.
- Produces: `cap_count` matching the verified authority read model.

- [ ] **Step 1: Add projection divergence regressions**

Create one runtime grant absent from `caps_json` and one revoked DB-origin cap.
Assert list and detail payloads report the verified count.

- [ ] **Step 2: Replace `length(user.caps)`**

Resolve the user's URI through the existing row data, load verified caps through
EntityCaps, and count the returned set. On reader failure report zero; do not use
raw `caps_json` as fallback.

- [ ] **Step 3: Run and commit**

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/user_data_caps_test.exs
git add apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex \
  apps/ezagent_plugin_world/test/ezagent/world/user_data_caps_test.exs
git commit -m "fix(world): count verified entity capabilities"
```

### Task 6: Decide and pin the email inbound authority boundary

**Files:**
- Modify after decision: `apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex`
- Modify: `apps/ezagent_plugin_email/test/inbound_principal_test.exs`
- Create: `apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs`

**Interfaces:**
- Consumes: verified binding and one concrete session URI.
- Produces: one principal/cap set restricted to that session, workspace, and send action.

- [ ] **Step 1: Record the decision before implementation**

Choose exactly one: retain the ephemeral self-authority as a reviewed transport
exception, or issue a formal artifact through `Cap.issue/3`. Reject any proposal
that introduces a wildcard instance, action, behavior, or workspace.

- [ ] **Step 2: Add exact-shape tests**

Assert one cap only, receiver equals the inbound principal, instance equals the
session URI, workspace derives from that session, and action equals send.

- [ ] **Step 3: Add a structural invariant**

If retaining the exception, pin its constructor file and exact axes. If migrating,
forbid direct `%Capability{}` construction in `inbound/principal.ex`.

- [ ] **Step 4: Run and commit**

```bash
mix test apps/ezagent_plugin_email/test/inbound_principal_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs
git add apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs
git commit -m "fix(email): pin inbound authority provenance"
```

### Task 7: Complete capability signing no-tail migration

**Files:**
- Read: `docs/superpowers/handoffs/2026-07-14-cap-signing-notail-upgrade-codex-handoff.md`
- Read: `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md`
- Modify or extend the landed audit task identified by the no-tail handoff.
- Create: `docs/guide/cap-signing-no-tail-upgrade.md`
- Create: `docs/together/2026-07-14/returns/cap-signing-no-tail-upgrade.md`

**Interfaces:**
- Consumes: stored authorizer capabilities and `Ezagent.Cap.issue/3`.
- Produces: signed receiver-bound artifacts only, followed by enforcement.

- [ ] **Step 1: Back up every mutable capability store**

Record row counts, snapshot counts, unsigned counts by store, backup location,
restore command, and checksum before changing data.

- [ ] **Step 2: Re-derive through normal issuance**

Reissue only when the original authority and receiver can be proven. Quarantine
unprovable artifacts; never blind-sign legacy bytes.

- [ ] **Step 3: Audit the no-tail condition**

Expected result:

```text
unsigned authorizer capabilities = 0
invalid signatures = 0
receiver mismatches = 0
```

- [ ] **Step 4: Flip enforcement and test rollback**

Enable `require_signature: true`, restart, run authorization smoke tests, and
restore the prior configuration immediately if any verified principal loses
expected authority.

### Task 8: Full gate and per-PR handoff

**Files:**
- Create one return under `docs/together/2026-07-14/returns/` per task PR.

**Interfaces:**
- Consumes: each independently completed task above.
- Produces: reviewable PRs with machine evidence and no mixed deferred work.

- [ ] **Step 1: Run the complete gate set on each PR head**

```bash
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
SHELL=/bin/bash mix precommit
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Request independent review**

No PR is pushed with an unresolved Critical or Important finding.

- [ ] **Step 3: Rebase and create the PR**

```bash
git fetch origin main
git rebase origin/main
git push -u origin fix/home-live-fail-closed
```

For later PRs substitute their fixed branch name:
`fix/live-auth-entity-caps`, `fix/member-cap-verified-reader`,
`fix/world-verified-cap-count`, `fix/email-inbound-cap-boundary`, or
`ops/cap-signing-no-tail`. Record the exact main SHA, PR URL, protected CI URL,
DoD reconciliation, and deferred follow-ups in the return file.

## Parallel execution map

- Task 1 starts immediately after the new session branches from current main.
- Task 2 is an external dependency gate; Task 3 waits for it.
- Tasks 4 and 5 may run in parallel after Task 2 because they modify separate apps.
- Task 6 may be researched in parallel but implementation waits for its explicit decision.
- Task 7 remains isolated from all UI/reader PRs.
- ARB-2..ARB-5 and creator Terminal acceptance use separate plans/branches and may
  proceed in parallel with this queue after PR #1402 merges.
