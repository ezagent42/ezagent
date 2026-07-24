# Plan E E2 — Implementation Plan

## Phase 1: App scaffold + migration + schema tests (RED first)
- [ ] mix.exs (plugin app)
- [ ] migration 20260724010000_create_git_workflow_intents.exs
- [ ] TaskBinding schema test
- [ ] WorkflowRun schema test

## Phase 2: Schema implementation (GREEN)
- [ ] TaskBinding schema
- [ ] WorkflowRun schema

## Phase 3: Store + concurrency tests (RED first)
- [ ] Store test (claim, transition, idempotency)
- [ ] Concurrency tests (20 concurrent claims)

## Phase 4: Store implementation (GREEN)
- [ ] Store.claim/1 (insert-or-load)
- [ ] Store.transition/4 (CAS)

## Phase 5: ActionSet + authority tests (RED first)
- [ ] GitWorkflow ActionSet test
- [ ] Authority tests (missing principal, revoked, no cap)

## Phase 6: ActionSet implementation (GREEN)
- [ ] TaskIntake (claim authorization, binding validation)
- [ ] GitWorkflow ActionSet (register_binding, disable_binding, claim_task, read_run)

## Phase 7: Architecture tests (RED first)
- [ ] No workspace/worker/provider side effects in claim
- [ ] No GitHub/Kanban/socialware plugin dependency
- [ ] Static rejection of Kind.spawn, Cap.issue in claim call graph

## Phase 8: Release/web wiring
- [ ] mix.exs release applications
- [ ] ezagent_web/mix.exs umbrella dependency
- [ ] Declarative plugin test

## Phase 9: Final gates
- [ ] Focused tests green
- [ ] mix ci.fast green
- [ ] mix precommit green
- [ ] git diff --check clean
