> **Task:** Capability/Auth Follow-ups Tasks 3–6
> **Branch:** `fix/capability-auth-followups`
> **PR:** https://github.com/ezagent42/ezagent/pull/1412
> **Dev:** codex
> **returned_at:** 2026-07-15

## Revision

- Latest base: `c7beace664284f31298c524871d7fa5470e10052`
- Implementation head before this return update:
  `f4f5785d37817078ab9fa2a3fa197ac1254ce180`
- Commits after the latest rebase:
  - `a8ecc8efb test(web): close EntityCaps LiveAuth matrix`
  - `2c195c924 fix(session): verify member capability idempotency reads`
  - `4fa088871 fix(world): count verified entity capabilities`
  - `99cfa656c fix(email): pin inbound authority provenance`
  - `95c48c583 docs(together): return capability auth follow-ups`
  - `b114a21b0 docs(capbac): define email inbound authority decision`
  - `bd3bb1fc6 docs(capbac): plan email inbound authority decision`
  - `6efaca159 fix(email): centralize inbound authority decisions`
  - `f4f5785d3 test(email): cover authority removal and signing retry`

## Result and DoD

| Task | status | result |
|---|---|---|
| 3 — LiveAuth | met | Complete online/cold User+cold Agent, revoke/restart, invalid signature, wrong receiver, reader failure, and no-raw-fallback matrix. Production already used `EntityCaps.load/1`, so this is honestly test-only. |
| 4 — Session MemberCap | met | Uses `EntityCaps.load_persisted/1`; invalid/wrong-receiver artifacts do not suppress required grants; reader failure means “not observed”; invariant forbids `SnapshotStore.latest/1` fallback. |
| 5 — World cap count | met | User list/detail count verified `EntityCaps.load/1` results; runtime-only grants count, stale revoked projection data does not, reader failure is zero, UI shape is unchanged, raw-reader exceptions removed. |
| 6 — Email inbound authority | met | Replaced public inline unsigned minting with one private authority decision home. A fresh durable projection/parent join validates receiver, provenance, adapter, target, workspace, actor, and message authentication before `Cap.issue/3` issues one receiver-bound cap. Deterministic reject deletes; reader/signing/dispatch failure retains for retry. |

Task 6 is governed by
`docs/superpowers/specs/2026-07-15-email-inbound-authority-decision.md`.
The accepted threat model treats release-loaded domain/plugin code as trusted;
generic rule issuance remains a trusted-code assertion. The authorization
linearization point is the successful fresh durable join, so an operation
already admitted may finish after a concurrent unbind. A normal unbind deletes
the parent and cascades the email projection by FK; the next fresh read rejects
with `:no_binding`.

## TDD and regression evidence

- Task 3: expanded LiveAuth matrix `7 tests, 0 failures`; no production rewrite.
- Task 4 RED: reader-failure case initially failed (`2 tests, 1 failure`). GREEN:
  member-cap focused suite `10 tests, 0 failures`.
- Task 5 RED: four focused tests failed against `length(user.caps)`. GREEN:
  focused world count suite `4 tests, 0 failures`.
- Task 6 boundary RED: under real `require_signature: true` enforcement the old
  unsigned inline artifact exposed the boundary. Wished-for Authority API suite
  then failed `10/10`; pipeline validation RED failed `12/29`. GREEN after the
  minimum authority implementation: `30/30` focused.
- Review follow-up: real FK-cascade unbind and real signing-seed outage tests
  pin delete/no-dispatch and retry/no-delete respectively. Focused authority +
  pipeline: `25/25`.
- Latest post-rebase regression: Cap/signing core `37/37`, email `102/102`,
  world `202/202`, LiveAuth `7/7`, member-cap `10/10`.

## Review

- Design review first challenged the public rule primitive and unbind race.
  The user clarified the trusted release-code threat model; the revised design
  explicitly records that boundary and the fresh-join linearization semantics.
- Plan review: 0 Critical, 0 Important; approved.
- Implementation review first found two Important coverage gaps and one Minor
  environment-restore issue. The real reachable paths were added without
  disabling FK constraints or manufacturing an orphan state.
- Final independent review of `36268a1..0d5167f84` (content-equivalent before
  the latest rebase): 0 Critical, 0 Important, 0 Minor; Ready.

## Gates

- `mix ezagent.check_invariants`: PASS.
- `mix ezagent.arch.scan`: PASS, including
  `concatenated_namespace_modules: count=0 cap=0` after a fresh compile.
- `mix ezagent.doc.scan`: PASS (`404/404` documented public defs baseline).
- `mix ezagent.uri_query.scan`: PASS.
- `git diff --check`: PASS.
- `SHELL=/bin/bash mix precommit`: all tests ran, but the shared local test DB
  contained two tables not defined by this source checkout
  (`agent_creation_inventory`, `agent_retirement_obligations`), causing the
  per-tenant table inventory test to report `1 failure` out of 2094 core tests.
  The run later also logged a test-application teardown `noproc`. This is not
  claimed green; no changed file appears in either failure.
- Clean PR-head CI: pending the final force-with-lease push below.

## Remaining risk / handoff

- Task 6 intentionally does not create an untrusted-plugin rule registry or
  immediate-revocation transaction protocol; both would exceed the accepted
  trusted-code model and this follow-up's scope.
- Local full-suite proof is contaminated by shared test-database state, so the
  clean PR runner is the final full-suite authority. If PR CI reproduces a
  product failure, this return must be updated and the PR is not ready.
- Merge target is `main`. Do not self-merge; lead owns close.
