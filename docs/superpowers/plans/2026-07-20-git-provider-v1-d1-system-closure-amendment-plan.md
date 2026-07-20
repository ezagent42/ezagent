# Git Provider V1 Plan D1 system-closure amendment plan

**Design:** `docs/superpowers/specs/2026-07-20-git-provider-v1-d1-system-closure-amendment.md`

**Base for remediation review:** `d7c35d1e3`

**Execution rule:** TDD, one guarded Mix/BEAM process at a time, and no edits to
the preserved report/handoff files.

## Task 1 — schema and forward invariants

Write failing schema/migration tests, then add the four forward migrations from
the amendment. Update `Connection`, `AuthorizationAttempt`, and `Operation` with
pending/reservation/result/recovery/cleanup fields, closed constraints,
canonical constructors, immutable transition changesets, relational checks,
and redacted `Inspect`.

Gate:

- fresh migrate from zero and upgrade a non-empty current D1 schema containing
  active, pending, consuming, backend-committed, cleanup-pending, refreshing,
  and termination fixtures;
- no sentinel pending account/ref values;
- canonical/immutable and cross-workspace/absent-parent tests fail closed;
- every durable struct passes runtime secret-sentinel Inspect tests.

Commit: `feat(provider-connection): model pending connection lifecycle`

## Task 2 — aggregate birth, begin, reauthorize, and read

Write RED public Router/Store tests for missing initial connection, exact retry,
conflicting retry, terminal/begin race, reauthorization source/version/assurance,
and safe read view.

Implement a focused lifecycle module. Initial begin reserves/creates under lock,
calls the backend outside the transaction, and settles the attempt under a
second lock. Reauthorize uses its own purpose and never delegates to initial
begin. Read uses exact owner/workspace scope and an allowlist.

Gate: all seven registered actions have a real Store implementation; no handler
falls through to `orchestration_not_implemented` for protocol-valid input. The
public boundary separately proves begin/consume/refresh/read are reachable and
reauthorize/revoke/disconnect always return the closed assurance error.
Test-only verifier injection may exercise the latter three protocols;
production runtime configuration cannot open them.

Commit: `feat(provider-connection): close owner command lifecycle`

## Task 3 — callback subject and cold authority

Write RED tests where an operator starts initial authorization or
reauthorization with distinct owner-granted callback artifacts and where the
owner User is cold at ingress. Each attempt reservation/digest combines the
artifact identity with purpose, connection id, and connection generation; the
capability format itself is unchanged. Add the narrow
durable-current-authority verification path in core. Store only owner-bound
continuations; retain central Router/Kind verification as the authorization
decision.

Gate: wrong generation/target/grantee creates zero DB/backend/driver mutation;
cold valid initial and reauthorization callbacks reach owner dispatch and exact
retry remains single-use; an artifact/reservation cannot replay across attempt,
purpose, or connection generation.

Commit: `fix(provider-connection): bind callback authority to owner`

## Task 4 — callback identity convergence and public receipt

Write RED tests for first-bind normalized metadata, no placeholder refs,
duplicate real-account CAS race, reauth identity drift, CAS crash recovery, and
receipt status from Connection.

Journal normalized safe callback metadata before CAS. Atomically commit identity,
authorization/credential pointers, versions, permissions, expiry, backend ids,
and connection/operation states. Route unique losers and stale reauth results to
durable cleanup without replacing the winner. In the same loser transaction set
connection `failed/account_conflict`, cancel the attempt, and make exact retry
return `account_conflict` without recreating work.

Gate: selector sees only the winning active binding. Winner retry returns the
same `%{connection_id, status: "active", version}` and no internal state; loser
retry returns stable `account_conflict` and creates no new cleanup work.

Commit: `feat(provider-connection): atomically bind provider identity`

## Task 5 — recovery poison fairness

Write RED deterministic-clock tests with a permanently failing oldest row,
later successful rows in the same phase, and work in later phases. Assert no
zero-delay loop.

Implement durable attempts/backoff/due queries, cursor advancement for every
inspected row, bounded scheduling to earliest due work, and observable closed
errors. D1 retries permanent failures forever at capped backoff and never
quarantines or silently skips them.

Commit: `fix(provider-connection): schedule fair recovery retries`

## Task 6 — refresh losing-result compensation

First amend the driver contract with a stable refresh result coordinate and an
exact discard/reconcile callback. Add RED barriers after provider effect,
journal, credential handoff, and pointer CAS.

Journal provider ownership immediately; make credential output addressable;
then fence pointer commit. Persist and independently retry provider-discard and
credential-revoke obligations for every loser.

Commit: `fix(provider-connection): compensate stale refresh results`

## Task 7 — assurance fail-closed boundary (Decision B)

Add `action` to `Assurance`, define the backend-neutral trusted-session verifier
port, keep production hard-wired to the unavailable validator with no runtime
opening, and test
action/replay/expiry/owner/version binding. Document and gate the deferred
`reauthorize`, `revoke`, and `disconnect` public flows; do not claim them as
production-complete D1 actions. No OneAuth/WebAuthn dependency is added.

Commit: `fix(provider-connection): keep assurance actions fail closed`

## Task 8 — structural gates and finalizer closure

Extend authority/secret AST gates to grouped aliases and all durable structs.
Make HandoffFinalizer fail closed on unexpected lifecycle and add DB/runtime
coherence tests. Gate only the four new amendment migrations against
`IF NOT EXISTS`; previously committed migrations remain byte-immutable, and any
historical correction uses another forward migration.

Commit: `test(provider-connection): close structural boundary gaps`

## Task 9 — verification and review

Run, serialized under the 5G cgroup guard:

1. focused RED/GREEN files per task;
2. full provider-connection suite;
3. Git, Identity, Core cap, Workspace, Session callback, architecture, migration,
   doc/URI/invariant/lifecycle gates;
4. warnings-as-errors compile and fresh DB migration;
5. `mix precommit`, classifying only independently reproduced failures;
6. `git diff --check`, exact status, and log from `d7c35d1e3`.

Then run two independent read-only reviews: one against this amendment and one
whole-branch X-level review from the original D1 base. Any finding is fixed and
re-reviewed before completion.
