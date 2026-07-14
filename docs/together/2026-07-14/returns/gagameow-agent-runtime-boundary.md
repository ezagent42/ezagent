# AgentRuntime Boundary Return

> **Task:** gagameow-agent-runtime-boundary
> **Branch:** `spec/agent-runtime-boundary`
> **PR:** https://github.com/ezagent42/ezagent/pull/1402
> **Dev:** gagameow / Codex
> **returned_at:** 2026-07-14 22:37 +0800
> **deadline:** 2026-07-14 23:59 +0800
> **deadline_status:** on_time

## Delivered

- Approved domain-agent narrow Facade ownership design; no core AgentRuntime,
  command bus, Port behaviour, or duplicate PTY policy.
- Closed 34-edge Session→Agent lifecycle inventory.
- Syntax-only AST scanner over every Session production source.
- Exact current-debt allowlist with stale, duplicate, schema, and replacement checks.
- Adversarial fixtures for qualified, aliased, imported, grouped-alias, and lexical-scope calls.
- Independent architecture verdict `SOUND`; final code review found no Critical or Important issue.
- Canary investigation found LiveAuth reading stale `users.caps_json`; the immediate hot-state
  fix now reads receiver-aware verified Identity state for both User and Agent principals.

ARB-2 through ARB-5 remain follow-up migration slices. The additional Caps audit items are
recorded in the homework document and intentionally remain outside this return's completed DoD.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Close the Session→Agent lifecycle inventory | met | 34-edge table in the homework/design artifacts |
| 2 | Add an exact structural gate for current Session-owned lifecycle debt | met | focused AgentRuntime architecture suite: 23/23 |
| 3 | Prove qualified, alias, import, and grouped-alias bypasses fail | met | adversarial scanner fixtures; independent verdict `SOUND` |
| 4 | Preserve sanctioned negative fixtures and stale-allowlist enforcement | met | focused gate suite and full precommit |
| 5 | Rebase onto current `origin/main` and run full machine gates | met locally | base `be23fcf97`; full precommit exit 0; PR #1402 CI pending |
| 6 | Complete creator Terminal product-call and restart-persistence canary acceptance | deferred | operational follow-up; no longer blocks the structural ARB-0/ARB-1 PR |

**Method friction:** shared local test DB retained four `probe-*` workspaces from old test
runs, producing false visibility-invariant failures. After confirming they were isolated
test-only rows, they were deleted transactionally and the invariant was rerun clean. Future
test isolation should prevent durable probe names from escaping a test transaction.

## Verification

| Gate | Result |
|---|---|
| focused AgentRuntime architecture test | PASS — 23 tests, 0 failures |
| LiveAuth User/Agent regression | PASS — 2 tests, 0 failures |
| workspace visibility invariant | PASS — 10 tests, 0 failures after local test-data cleanup |
| `mix ezagent.arch.scan` | PASS |
| `mix ezagent.doc.scan` | PASS |
| `mix ezagent.uri_query.scan` | PASS |
| `mix ezagent.check_invariants` | PASS |
| touched-file format check | PASS |
| `git diff --check` | PASS |
| `SHELL=/bin/bash mix precommit` | PASS — exit 0 |
| PR CI | PENDING — https://github.com/ezagent42/ezagent/pull/1402/checks |

## Rebase and scope

- Rebase base: `origin/main@be23fcf97a17da9f667b7ec3acccb1d3aedf4e2d`, containing
  PR #1375, #1379, #1399, #1400, and #1401.
- Branch state at PR creation: ahead 17, behind 0.
- The shared-DB cleanup affected only local `127.0.0.1:55432/ezagent_pg_compat_test`;
  no canary database row was modified.
- LiveAuth's remaining durable SSOT, HomeLive fail-closed, member-cap reader, cap-count UI,
  email boundary, and no-tail enforcement tasks will be handled after this PR is established.

## Deferred follow-ups / lead decisions

1. Schedule ARB-2..ARB-5 as shrink-only slices until the lifecycle allowlist reaches zero.
2. Complete creator Terminal normal product-call, credential status, and restart-persistence
   acceptance as an operational follow-up.
3. Process Caps audit work in priority order after this PR: `AUTH-FAIL-1`, then the
   `EntityCaps`-dependent LiveAuth migration/cold matrix, then P1/P2 reader/display/boundary work.

## Merge request

PR #1402 targets `main`. Wait for protected CI, then replace the pending CI field above with
the final run URL and status before lead merge.
