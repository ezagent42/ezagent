# Scenario 24: Destroy cascade — agent / session / workspace

**Category**: 12 — Destroy + cleanup cascade
**Status**: ⚠️ implemented-with-gaps
**Last verified**: 2026-05-25 (`sandbox_destroy_test.exs` for single-level; cascade untested)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- A populated workspace `workspace://acme` with:
  - 3 agents (cc, curl, echo) each with config_dir / api-keys
  - 2 sessions, each binding 2 agents
  - 1 Feishu binding on one session
- Admin logged in

## Actors

- **Caller**: admin
- **Targets (cascade)**: workspace → sessions → agents → config_dirs / api-keys / bindings
- **Framework**: PR #449 SagaRunner (post-Phase-1)

## Steps

### Destroy single agent (single-level — tested today)

1. Click "Destroy" on an agent in `/admin/agents/<uri>`.
2. The Agent Kind transitions to `:terminating`; PTY is killed; pid-files cleaned; config_dir is removed (if owned, per `sandbox_destroy_test.exs`).
3. Session memberships are evicted (the agent is removed from each session's `:members` slice).
4. Routing rules referring to the agent: today NOT cleaned (gap — see Notes).

### Destroy session

5. Click "Destroy" on a session.
6. The Session Kind terminates; session_members rows deleted; external_mirror bindings unbound.
7. Verify all members receive a `:session_destroyed` event.

### Destroy workspace (cascade — UNTESTED today)

8. Click "Destroy" on `workspace://acme`.
9. **Intended**: SagaRunner orchestrates:
   - Step 1: terminate all sessions (with compensation if step fails)
   - Step 2: terminate all agents (with compensation)
   - Step 3: delete templates, routing rules, workspace members
   - Step 4: delete workspace row + Kind worker
10. **Today**: only step 4-ish runs without proper saga; partial destroy leaks state.

## Expected outcomes (intended)

- Saga completion: NO orphan rows in DB; NO leaked PTYs; NO dangling ExternalMirrorWorker.
- Saga failure (mid-cascade): SagaRunner marks operator-repair marker; admin sees `/admin/saga-repairs` with the failed step + compensation status.

## Failure modes to test

- Mid-cascade phx crash: SagaRunner replays on boot; idempotent steps re-attempt.
- One agent terminate fails (e.g. PTY refuses SIGKILL): operator-repair marker + saga halts.
- Cap mismatch (admin caps revoked mid-cascade): saga halts with `:unauthorized`.

## Cross-references

- Related PRs:
  - PR #449 — feat(arch-p1d): SagaRunner
  - PR #451 — integration of all Phase 1 sub-branches
  - PR #385 — orphan reapers (single-agent)
  - PR #418 — unbind projection sync
- Related SPECs:
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5 — SagaRunner contract
- Tests:
  - `apps/ezagent_core/test/integration/sandbox_destroy_test.exs` — single agent
  - `apps/ezagent_core/test/integration/lifecycle_terminate_test.exs` — terminate action body
  - No cascade E2E test.
- Open bugs / gaps:
  - **No cascade E2E test**. This is the principal Category 12 gap.
  - Routing rules referencing a destroyed agent are not cleaned up. Worth a separate scenario (or part of this).
  - SagaRunner is Phase 1 code; Phase 2 will exercise it for the first time on a real Behavior migration.

## Notes

- This is master README §6 priority 3 — `SagaRunner` baseline test must land before Phase 2 begins migrating Behaviors that depend on it.
- Per `feedback_completion_requires_invariant_test`, the cascade scenario only counts as "done" when an invariant test asserts "destroy(workspace) ⇒ count(orphans) == 0".
