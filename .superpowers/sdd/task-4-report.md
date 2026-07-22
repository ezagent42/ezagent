# Task 4 Report — Winner child-init ownership transaction

## Status

Implemented the Agent-domain `LaunchCoordinator` and wired
`Ezagent.Entity.Agent.before_start/1` to consume trusted launch context before
Kind visibility, readiness, or snapshot initialization.

## RED → GREEN evidence

- RED command:
  `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
- RED result: 5 failures, all `UndefinedFunctionError` for the absent
  `LaunchCoordinator.consume_before_start/2`; the inherited spawn tests passed.
- GREEN result for the same command: 12 tests, 0 failures.
- Required invariant:
  `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.

## Behavior proved

- Exact canonical Agent type, requested URI, structural workspace, same-workspace
  root, and non-empty attempt are validated before writes.
- Creation inventory and direct lineage use their frozen exact-write APIs in one
  `Repo.transaction`; either conflict rolls back the other fact.
- ETS lineage publication, WorkspaceRegistry binding, and authority
  acknowledgement occur only after durable commit and cannot reverse ownership.
- Exact replay converges even when authority acknowledgement fails; conflicting
  replay fails closed.
- A deterministic acknowledgement barrier proves durable facts exist while
  KindRegistry, ReadyGate, and KindSnapshot remain absent. Killing the spawning
  caller at that barrier does not remove inventory or lineage.
- Transaction failures publish no lineage cache, workspace binding, or
  acknowledgement, and the Agent hook is a no-op for legacy starts without
  launch context.
- No ownership branch was added to Core.

## Scope

The unrelated untracked handoff
`docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`
was preserved and excluded.

## Review correction after `a5e1db592`

- Added a compile-time-selected Agent-domain persistence seam. Its test
  implementation provides a deterministic pre-transaction/pre-commit barrier
  and separately injected inventory and lineage failures; production retains
  the single `Repo.transaction` exact-write path.
- The barrier and both failures now run through `Ezagent.Kind.spawn/3` and
  `Ezagent.Entity.Agent.before_start/1`. Tests assert the spawn result plus
  absence of KindRegistry, ReadyGate, KindSnapshot, the opposite durable fact,
  lineage cache, and WorkspaceRegistry as applicable.
- Added a narrow post-commit publisher behaviour. Production publishes lineage
  cache, binds WorkspaceRegistry, then acknowledges the authority in that exact
  order. A compile-time test implementation raises specifically at lineage
  cache publication; the test proves exact durable inventory/lineage survive
  and an identical replay receipt succeeds.
- Added an independent authority resolution case returning a different facts
  `agent_uri`; coordinator validation returns `:agent_uri_mismatch` with no
  writes or publications.

Fresh correction verification after formatting:

- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
  — Agent suite 11 tests, 0 failures; Session suite 6 tests, 0 failures.
- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.

## Second review correction after `5e242ad5e`

- Removed the configurable `LaunchPersistence` behaviour, production adapter,
  and test configuration. `LaunchCoordinator` again visibly and directly calls
  the fixed `CreationInventory.record_exact/5` and
  `AgentLineage.record_exact/3` APIs inside its transaction.
- Retained only a compile-time test-build hook around the fixed calls. The
  production build compiles the hook as a direct no-op and exposes no runtime
  or configuration-selected ownership persistence extension point.
- Moved the deterministic barrier inside `Repo.transaction`, after both exact
  writes return and immediately before the transaction callback returns. The
  real `Kind.spawn/3` test uses a separate PostgreSQL connection to prove
  KindSnapshot, inventory, and lineage are externally invisible while the
  transaction is blocked, while KindRegistry and ReadyGate are also absent.
  Releasing the barrier commits the facts before the child becomes visible.
- Inventory failure remains injected before its fixed call; lineage failure is
  injected after inventory and before its fixed call, proving rollback through
  real Agent initialization.

Fresh second-correction verification after formatting:

- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/agent/launch_coordinator_test.exs apps/ezagent_domain_session/test/ezagent/entity/agent_spawn_fresh_test.exs`
  — Agent suite 11 tests, 0 failures; Session suite 6 tests, 0 failures.
- `SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/kind_provenance_test.exs`
  — 1 test, 0 failures.
