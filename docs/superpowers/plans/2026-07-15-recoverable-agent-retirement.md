# Recoverable Agent Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agent retirement CapBAC-authorized, transaction-provenanced, truthful about cleanup, and recoverable through a dedicated durable obligation.

**Architecture:** `Ezagent.Domain.Agent` remains the public facade and delegates retirement orchestration to focused Agent-domain modules. Normal termination uses the existing Sandbox destroy dispatch; incomplete cleanup is stored in an Ecto-backed obligation with retry state. Session rollback and teardown preserve complete/partial/error results and never discard binding or lineage before cleanup is complete or durably recoverable.

**Tech Stack:** Elixir 1.19, OTP, Ecto/PostgreSQL-compatible Repo, ExUnit, telemetry, Phoenix umbrella supervision.

## Global Constraints

- Lineage proves provenance, never authorization.
- CapBAC remains at the existing dispatch chokepoint; no hand-written cap matching.
- Every partial result identifies a persisted pending obligation.
- No invocation-DLQ reuse and no compatibility shim.
- SessionManager remains Session-owned, but only inventory-backed conversation-executor seams are scanner-legal.
- Run `mix precommit` after all changes.

---

### Task 1: Durable Retirement Obligation Store

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260715000000_agent_retirement_obligations.exs`
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/retirement_obligation.ex`
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/retirement_obligations.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/retirement_obligations_test.exs`

**Interfaces:**
- Produces: `create_pending/1`, `get/1`, `mark_running/1`, `record_failure/2`, `resolve/1`, `list_due/1`.
- Obligation identity: `{agent_uri, creation_attempt_id, retirement_reason}`.

- [ ] **Step 1: Write failing persistence/state-transition tests**

```elixir
assert {:ok, pending} = RetirementObligations.create_pending(attrs)
assert pending.status == :pending
assert {:ok, running} = RetirementObligations.mark_running(pending.id)
assert running.attempts == 1
assert {:ok, failed} = RetirementObligations.record_failure(pending.id, :eacces)
assert failed.status == :pending
assert {:ok, resolved} = RetirementObligations.resolve(pending.id)
assert resolved.status == :resolved
```

- [ ] **Step 2: Run RED test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_agent/test/ezagent/agent/retirement_obligations_test.exs`
Expected: failure because schema/store/table do not exist.

- [ ] **Step 3: Add migration, schema and idempotent store**

The table carries `agent_uri`, `workspace_uri`, `provenance_root_uri`,
`creation_attempt_id`, `retirement_reason`, `status`, `pending_steps` (map),
`attempts`, `last_error`, `next_attempt_at`, `resolved_at`, timestamps, and a unique
index over the obligation identity. Store functions use changesets and
`Repo.insert(..., on_conflict: ...)`; no raw SQL outside the migration.

- [ ] **Step 4: Run GREEN test and commit**

Run the Task 1 test; expected 0 failures.
Commit: `feat(agent-runtime): persist retirement obligations`

### Task 2: Authorized, Provenanced Retirement Contract

**Files:**
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/retirement.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/retirement_test.exs`

**Interfaces:**
- Consumes: `RetirementObligations.create_pending/1`.
- Produces: `Ezagent.Domain.Agent.retire_spawned(agent_uri, context)` where context requires `caller`, `caps`, `workspace_uri`, `provenance_root`, `creation_attempt_id`, `reason`, and optional `created_agent_uris`.

- [ ] **Step 1: Write RED security tests**

```elixir
assert {:error, %{reason: :invalid_agent_target}} = Agent.retire_spawned(session_uri, ctx)
assert {:error, %{reason: :workspace_mismatch}} = Agent.retire_spawned(agent_uri, wrong_ws_ctx)
assert {:error, %{reason: :provenance_mismatch}} = Agent.retire_spawned(agent_uri, wrong_root_ctx)
assert {:error, %{reason: :unauthorized}} = Agent.retire_spawned(agent_uri, no_cap_ctx)
```

Also prove an Agent absent from `created_agent_uris` is rejected even if it has an unrelated valid lineage row.

- [ ] **Step 2: Run RED test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_agent/test/ezagent/agent/retirement_test.exs`
Expected: current arity/behavior fails the new contract.

- [ ] **Step 3: Implement validation and authorized dispatch**

Validate URI kind/workspace/inventory/lineage before invoking Sandbox destroy through `%Ezagent.Invocation{}` with the supplied caller/caps. Do not call `Capability.matches?/2`. Interpret the existing Sandbox structured reply into complete/partial/error reports.

- [ ] **Step 4: Run GREEN test and commit**

Expected: security cases and authorized success pass.
Commit: `fix(agent-runtime): authorize provenanced retirement`

### Task 3: Truthful Cleanup Outcome and Obligation Creation

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/retirement.ex`
- Modify: `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex` only if the existing dispatch result cannot expose cleanup failure without changing Lifecycle semantics.
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/retirement_test.exs`
- Test: `apps/ezagent_domain_session/test/integration/spawned_participant_teardown_test.exs`

**Interfaces:**
- Produces reports exactly shaped as complete, partial-with-obligation, or not-destroyed error.

- [ ] **Step 1: Write RED cleanup-failure test**

Use the existing raising config-dir fixture and assert:

```elixir
assert {:partial, %{termination: :destroyed, cleanup: :pending, obligation_id: id}} = result
assert RetirementObligations.get!(id).status == :pending
```

- [ ] **Step 2: Run RED test**

Expected: current code incorrectly returns complete cleanup.

- [ ] **Step 3: Persist obligation before reporting partial**

Ensure every failure list maps to explicit pending steps. If obligation persistence fails before irreversible termination, return `{:error, %{termination: :not_destroyed, reason: {:obligation_persist_failed, reason}}}` and retain evidence. Remove `:agent_retirement_cleanup` from `Ezagent.DLQ` and its tests.

- [ ] **Step 4: Run GREEN tests and commit**

Commit: `fix(agent-runtime): preserve partial cleanup outcomes`

### Task 4: Retry Worker and Operator Surface

**Files:**
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/retirement_obligation_sweeper.ex`
- Create: `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.retirement.retry.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/retirement_obligation_sweeper_test.exs`

**Interfaces:**
- Consumes: obligation store and idempotent cleanup-step executor.
- Produces: `retry/1`, periodic `sweep_due/0`, and `mix ezagent.agent.retirement.retry --id ID`.

- [ ] **Step 1: Write RED retry tests**

Prove a pending filesystem step increments attempts on failure and becomes resolved only after all pending steps succeed; repeated resolved retries are idempotent.

- [ ] **Step 2: Run RED test**

Expected: modules/functions undefined.

- [ ] **Step 3: Implement supervised sweeper and Mix task**

Use a bounded batch and configurable interval; emit `created`, `attempted`, `resolved`, and `failed` telemetry. The Mix task uses the same store/executor, not a duplicate cleanup path.

- [ ] **Step 4: Run GREEN test and commit**

Commit: `feat(agent-runtime): retry retirement cleanup`

### Task 5: Rollback and Teardown Result Preservation

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex`
- Modify: its call sites in `session_creator.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex`
- Test: focused rollback tests plus `spawned_participant_teardown_test.exs`.

**Interfaces:**
- Consumes: new retirement context and reports.
- Produces: rollback/teardown reports that aggregate `completed`, `partial`, and `failed` targets.

- [ ] **Step 1: Write RED ordering tests**

Assert an error leaves workspace binding and lineage intact; a partial proceeds only when its obligation exists; another session's Agent is rejected; cascade reports partial instead of `:ok`.

- [ ] **Step 2: Run RED tests**

Expected: current unconditional unbind/forget and `:ok` fail assertions.

- [ ] **Step 3: Pass trusted creation provenance and preserve evidence**

Change `compensate_spawned_members/1` to consume a rollback context populated at the create call site. Remove target-self parent lookup. Branch explicitly on complete/partial/error before unbind/forget.

- [ ] **Step 4: Run GREEN tests and commit**

Commit: `fix(session): preserve retirement recovery evidence`

### Task 6: Precise SessionManager Architecture Gate

**Files:**
- Modify: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex`
- Modify: `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`

**Interfaces:**
- Produces exact legal conversation-executor classification without an allowlist.

- [ ] **Step 1: Write RED positive/negative fixtures**

The confirmed keyword binding with both `orchestrator_uri` and `session_uri` is legal; `SessionManager.stop(worker_uri)` and member/PTY/sidecar-shaped targets are offenders.

- [ ] **Step 2: Run RED architecture test**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`
Expected: worker negative fixture currently returns no offender.

- [ ] **Step 3: Implement exact contextual classifier**

Match the inventory-backed path/definition/argument shapes; retain `@allowlist []` and stale allowance enforcement.

- [ ] **Step 4: Run GREEN test and commit**

Commit: `test(agent-runtime): pin SessionManager executor seams`

### Task 7: Review Closure and Full Verification

**Files:**
- Modify: PR description and design/plan only if implementation reveals a contract delta.

- [ ] **Step 1: Run focused suites**

Run Agent retirement/obligation tests, Session rollback/teardown/materialization tests, and core architecture gates. Expected: 0 failures.

- [ ] **Step 2: Run full gate**

Run: `SHELL=/bin/bash mix precommit`
Expected: exit 0 without architecture-cap increase.

- [ ] **Step 3: Request two read-only reviews**

One reviewer focuses authorization/provenance and one focuses cleanup ordering/recovery. Resolve all Critical/Important findings.

- [ ] **Step 4: Push updated PR**

Push the branch, update PR #1411 summary/verification, and report CI status.
