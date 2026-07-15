> **Task:** Capability/Auth Follow-ups Tasks 3–6
> **Branch:** `fix/capability-auth-followups`
> **PR:** https://github.com/ezagent42/ezagent/pull/1412
> **Dev:** codex
> **returned_at:** 2026-07-15T14:11:58+08:00
> **deadline:** 2026-07-15 EOD +0800
> **deadline_status:** met

## Revision

- Original base: `b050f15bcb17f7392dfb2a392bc220eb9c83fc1d`
- Rebase base: `4956804acc4fdeb77a611c70edf389fc2b0f9e4e`
- Implementation head before return/PR metadata: `c9c8645389423195972a8d826a31762fac9bb8cd`
- PR creation head (includes this return record): `c302cba50070a0f3107596f324014c2d9113a67c`
- CI-verified rebased PR head: `562df8bfccae3f215da58531da1760d3c6656829`
- Commits:
  - `6cfed613e test(web): close EntityCaps LiveAuth matrix`
  - `164362ffb fix(session): verify member capability idempotency reads`
  - `78780bb76 fix(world): count verified entity capabilities`
  - `c9c864538 fix(email): pin inbound authority provenance`

## What changed

- LiveAuth now has the complete online/cold User+Agent, revoke/restart,
  signature, receiver, reader-failure, and no-raw-fallback regression matrix.
  Production already used `EntityCaps.load/1`, so this slice is test-only.
- Session join idempotency continues to use `EntityCaps.load_persisted/1` and now
  treats reader exceptions as “grant not observed.” Invalid-signature and
  wrong-receiver persisted artifacts cannot suppress the required join grant.
- World user list/detail capability counts use verified `EntityCaps.load/1`
  results. Runtime/projection divergence, stale revoked rows, reader failure,
  and removal of both raw-reader allowlist entries are pinned.
- Email inbound authority is issued through `Cap.issue/3` under the existing
  narrow `{:rule, :verified_email_binding, binding_actor}` category. The
  durable binding's `bound_by` entity is provenance; the synthetic email
  principal is the signed receiver. The previous unsigned hand-stamped inline
  artifact and its constructor-gate exception are removed. The authority join
  fails closed unless the durable row and email projection agree on session,
  adapter, target, and workspace, and `bound_by` is an entity URI.

## TDD evidence

- Task 3: production behavior was already present from #1409; the expanded
  user-facing mount matrix ran `7 tests, 0 failures`. No production rewrite was
  made merely to manufacture a diff.
- Task 4 RED: `member_cap_verified_reader_test.exs` ran `2 tests, 1 failure`
  because the reader did not rescue infrastructure failure. GREEN: focused
  session suite `10 tests, 0 failures`.
- Task 5 RED: world focused suite ran `4 tests, 4 failures` against raw
  `length(user.caps)`. GREEN: `4 tests, 0 failures` after the facade count.
- Task 6 boundary RED: with `require_signature: true`, the old unsigned inline
  cap still produced `{:ok, %{stored: true}}` through real
  `Invocation.dispatch/1`. The new wished-for `mint/2` + invariant suite then
  ran `9 tests, 9 failures`. GREEN: email focused + pipeline `18 tests, 0
  failures`; signing/invariant group `16 tests, 0 failures`. Review follow-up
  RED: a corrupt email projection borrowed provenance from an unrelated binding
  and injected successfully (`10 tests, 1 failure`). GREEN: full email plugin
  `87/0`; Cap signing/chokepoint focused group `29/0`.
- Post-rebase combined evidence: core `34/0`, session `10/0`, email `87/0`,
  world `4/0`, web `7/0`.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | LiveAuth complete verified EntityCaps matrix and no fallback | met | `apps/ezagent_web/test/ezagent_web/live_auth_caps_test.exs` |
| 2 | MemberCap verified persisted-reader semantics and invariant | met | focused `10/0`; `member_cap_verified_reader_test.exs` |
| 3 | World counts verified current caps, failure=0, stable output shape | met | focused `4/0`; raw-reader gate shrank by two entries |
| 4 | Email inbound has reviewed receiver/provenance-bound authority | met | real enforcement dispatch; full email `87/0`; Cap signing/chokepoint `29/0` |
| 5 | Complete local gates green | not-met | latest `origin/main` itself is red on arch/uri/check_invariants; see below |
| 6 | Independent review has no Critical/Important | met | first review found two Important; rebased `c9c864538` contains both fixes; re-review: 0 Critical, 0 Important |
| 7 | PR-head protected CI green | met | rebased `562df8bfc`: deterministic gate, gitleaks, return advisory, and ownership check passed; conditional macOS/canary jobs skipped |

**Method friction:** the Task 6 plan correctly required a real enforcement test:
`require_signature` does not filter inline `ctx.caps`, which was not apparent
from matcher-only tests. The repository's latest `main` is already red under
three required static gates, so the machine return gate cannot be honestly
claimed locally without an upstream repair.

## Gates

- `mix ezagent.doc.scan`: PASS.
- `git diff --check`: PASS.
- Focused EntityCaps access/mutation and signing gates: PASS (`28/0`).
- `mix ezagent.arch.scan`: FAIL on latest `origin/main` and this branch with the
  same five pre-existing counters (SpawnRegistry call/module/off-chokepoint,
  `spawn_fresh_unsanctioned`, `all_slices_unsanctioned`).
- `mix ezagent.uri_query.scan`: FAIL on latest `origin/main` and this branch with
  the same six pre-existing `home_path_in_runtime_code` findings.
- `mix ezagent.check_invariants`: FAIL on four pre-existing
  `apps/ezagent_domain_pty` `Phoenix.PubSub.broadcast` lines.
- `SHELL=/bin/bash mix precommit`: started the full suite; core reported three
  PostgreSQL sandbox/session-create timeouts and identity reported one existing
  `ConfigEvolveTest` failure. Remaining apps were stopped after the failure was
  established. No failure named a changed file.
- PR #1412 rebased head `562df8bfc`: all required GitHub checks PASS. Conditional
  macOS full-suite and canary jobs were skipped by workflow policy.

## Remaining risk / merge request

- Local all-gate green remains unclaimable because the same static findings
  reproduce on the rebased `origin/main`; that upstream debt is outside this
  PR. Protected PR-head CI is green.
- Merge target is `main`; do not self-merge. Lead owns close.
