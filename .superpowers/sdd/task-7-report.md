# Task 7 report — receipt-gated recovery

## Outcome

Recovery now classifies the Provision row's exact attempt, Agent, provenance
root, and workspace against `CreationInventory.exact/4`:

- exact receipt: `{:owned, facts}` and sanctioned Agent retirement receives
  those exact facts;
- absent receipt: `{:unowned, :creation_receipt_absent}` and only the exact
  Provision-owned Git workspace is cleaned;
- same-key coordinate mismatch: `{:error, :creation_receipt_conflict}` and the
  row remains `:cleanup_pending` with fixed blocker
  `"creation_receipt_conflict"`.

The retirement facade no longer searches for a replacement/latest attempt. It
requires the classified facts to equal the durable Provision coordinates before
building the existing CapBAC retirement context.

Lease deferral, expired-start CAS, cleanup-token acquisition, renewals around
destructive effects, and stale-token fencing are unchanged.

## RED evidence

The exact Task 7 command initially failed as intended:

- expired starting without a receipt emitted `{:retire_agent, ...}`;
- an exact-key coordinate conflict was cleaned instead of remaining blocked;
- the dedicated matrix file did not yet exist.

The run also exposed older boot fixtures that no longer satisfied the durable
start-identity database constraint; those fixtures now include the exact
attempt/Agent/root coordinates, and only owned boot cases seed a receipt.

## Deterministic ten-case matrix

`task_workspace_atomic_ownership_test.exs` contains ten numbered cases:

1. winner commit before init return crash;
2. instantiate return before completion crash;
3. adopted same-lineage Agent;
4. concurrent attempts with one winning receipt;
5. inventory and lineage transaction-write failures;
6. cache absence with durable receipt rehydration;
7. sidecar failure after receipt;
8. Repo/BEAM-state restart read from SQL;
9. exact replay and coordinate conflict;
10. expired starting row without receipt.

Crash/concurrency boundaries use explicit process messages and release barriers;
there are no sleeps or wall-clock coordination assertions. Owned cases assert
all four exact facts. No-receipt recovery asserts no retirement message and
exact Git cleanup.

## Verification

```text
SHELL=/bin/bash MIX_ENV=test mix test \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs

47 tests, 0 failures
```

Touched files were formatted with `mix format`; `git diff --check` completed
without errors. Full `mix precommit` was intentionally not run per the Task 7
brief.

## Correction after production-path review

The original matrix was rejected because nine cases inserted or classified
facts directly. The correction replaces those fixtures with real
`AgentStart -> TemplateSpawn -> Kind.spawn -> LaunchCoordinator` execution.
Test-build-only barriers now stop the child immediately after the SQL commit
and stop TemplateSpawn immediately before `PreStart.complete/2`; caller death
at either boundary leaves the durable Provision for `recover_once/1`.

The production race test found an additional defect: the inventory unique key
`(creation_attempt_id, agent_uri)` allowed two concurrent attempts to both own
one Agent URI. The corrected schema fences `agent_uri` itself, and
`record_exact/5` treats a different attempt for that URI as a fixed creation
fact conflict. This makes the SQL row the winner election rather than an ETS or
caller-local observation.

Every owned case now invokes `Reconciler.recover_once/1` and asserts the fake
retirement's exact attempt, Agent, root, and workspace facts. Every unowned case
invokes recovery, observes exact Git verification, and asserts zero retirement.
Write failures use the Task 4 test-build hooks inside real Agent initialization;
cache publication failure uses the real postcommit publisher and SQL rehydrate;
all concurrency and crash boundaries use process messages without sleeps.

Follow-up review made three boundaries explicit: the adopted Agent is safely
terminated and monitored during teardown; case 7 makes the test Template Class
return a real post-`Kind.spawn` sidecar error after the coordinator receipt has
committed; and case 8 commits through the production path using a bounded
non-Sandbox pool, discards both lineage and workspace ETS entries, actually
terminates/restarts the application-owned Repo process, then reloads the SQL
receipt and republishes both production caches before recovery. Its `after`
block removes every committed restart fixture and restores the Sandbox Repo
configuration. The permanent-identity contract is now
stated in the design: one Agent URI has one final receipt, and destroy/recreate
requires a new URI.

The Repo-mode helper establishes its outer `try/after` before changing either
application configuration or Sandbox state. Case 8 first injects a failure in
the initial restart callback, then proves the original configuration is restored
and a fresh Sandbox checkout can execute SQL before running the real restart
scenario. Restoration starts a bounded two-connection Sandbox pool to avoid a
restart-time connection surge, then restores the exact configured pool size in
application state.

Fresh correction verification:

```text
SHELL=/bin/bash MIX_ENV=test mix test \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_atomic_ownership_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs

47 tests, 0 failures
```
