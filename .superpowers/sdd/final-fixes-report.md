# Plan C final fixes report

Date: 2026-07-17
Worktree: `/home/huangjiajia/ezagent/.worktrees/git-domain-spine`
Starting HEAD: `6c30fe35ce69fe66296c8d326f8f3e9d9849b86d`

## Outcome

- Commit `78684af01 fix(workspace): close task start recovery gaps`
- No push, merge, rebase, or deploy performed.
- Unrelated untracked handoff preserved: `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`.

## Corrected claims

- A sanctioned `creation_attempt_id` is allocated with the durable start intent, before a row may enter `starting`.
- PreStart reserves that exact identity in Agent CreationInventory before checkout verification/instantiation; TemplateSpawn receives and idempotently records the same ID after its normal obligations.
- Expired-start recovery uses the durable ID, so an instantiate/completion crash does not produce a permanent `creation_attempt_not_found` retry loop. The retirement path remains the sanctioned Agent-domain path and retains inventory/lineage fencing against unrelated agents.
- `GitRunner.verify/1` now distinguishes positive proof mismatch/dirty results from executor/infrastructure failures (`:checkout_unavailable`).
- PreStart releases an availability-failed claim back to retryable `ready` under the exact current start-claim fence; it does not instantiate or schedule destructive cleanup.
- Ready reconciliation now verifies remote URL, resolved commit, deterministic branch ref, and canonical cache/worktree paths. Positive mismatch/dirty is cleanup-eligible; availability remains non-destructive.
- Store rejects malformed resolved commits (only lowercase 40/64 hex) and non-deterministic local branch refs for the provision ID/generation in both ready and failure-effect proof.

## TDD evidence

RED command:

`SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs`

RED result: 25 tests, 4 failures. Expected failures proved: missing durable creation ID, availability transitioned to `cleanup_pending`, ready reconciliation omitted remote/commit/branch proof, and recovery retirement had no durable attempt ID. (`mise` was unavailable; direct `mix` initially required explicit `SHELL=/bin/bash` for erlexec.)

Focused GREEN:

- Store: 23 tests, 0 failures.
- Provisioner: 14 tests, 0 failures.
- Combined GitRunner/Store/PreStart/Reconciler focused set: 73 tests; initial fixture-only deterministic-ref failures were corrected at the shared fake runner.
- Full Workspace: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test` -> 312 tests, 0 failures.

Domain Agent:

`SHELL=/bin/bash mix test apps/ezagent_domain_agent/test` -> 154 tests, 1 failure. The failing pre-existing timing assertion was `Ezagent.Agent.TransportReadinessTest` expecting the `never_ready` DLQ SQL row immediately; runtime logs showed the dead-letter action but the query observed no row. This run is not reported green.

## Migration roundtrip

The first rollback revealed the local dev DB had not yet applied the Plan C migrations, then migrate applied `01000` through `04000`. An exact subsequent roundtrip succeeded:

- `mix ecto.rollback --step 1` ran `20260717004000 ... down/0`, including dropping the new start-identity constraint.
- `mix ecto.migrate` ran `20260717004000 ... up/0`, recreating the start recovery index, status constraint, and `git_task_workspace_provisions_start_identity_check`.

## Fresh precommit

Command: `SHELL=/bin/bash mix precommit`

Final status: non-zero. Failures observed (therefore not green):

1. `oversized_modules_gt_1000`: measured 5, cap 4.
2. `SkillRegistryTest`: seed bundle refs contained `dev-together` and `kanban-assistant`, derived runtime set only contained `ezagent-session-orchestrator`.
3. URI-query scan violation in pre-existing `apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex:142` raw `entity://` string check.
4. Subsequent DB sandbox/timeout cascade failures in unrelated core E2E tests after the above failures.
5. The umbrella run continued after core failure; isolated later stages included Domain Agent 154/0, Identity 500/0, Workspace 312/1 (`ApplicationBootTest` registry absent in the contaminated aggregate process), and World 362/62 (authentication redirects after the earlier shared-state failures). The independently fresh Workspace run remained 312/0.

These are recorded as the exact non-green precommit state; no false-green claim is made.

## Remaining concerns

- The requested five named static gates were exercised as part of precommit, but the aggregate precommit is non-green for the failures above. A clean isolated rerun may be useful after reconciling the branch's pre-existing architecture/skill/URI baselines.
- The full Domain Agent timing failure should be rerun in isolation if a completely clean branch-wide result is required.
