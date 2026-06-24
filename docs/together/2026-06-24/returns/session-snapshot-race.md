# Return: session snapshot race / Bug A

## Scope

- Worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/fix-session-snapshot-race`
- Branch: `fix/session-snapshot-race`
- Target branch: `target/session-snapshot-race`
- Draft PR: https://github.com/ezagent42/ezagent/pull/934
- Base: `origin/main` at `db0e2394`
- Handoff read first: `docs/together/2026-06-24/handoffs/core-session-create-and-resolver-restart-handoff.md`

## Result

Bug A's suspected create-time snapshot race was independently checked against current main after PR #912. The new regression exercises `Workspace.create_session/3` concurrently and asserts that each returned session already has a durable finalized `KindSnapshot` containing the expected session slice, owner membership, template URI, and orchestrator member declaration.

That regression passed before any create-path production change. Based on this evidence, the post-#912 create boundary already waits for the session snapshot condition we need; the old "5s orchestrator wait races snapshot persistence" failure was not reproducible on current main. I did not add a redundant create-path ordering change.

The remaining Bug A symptom was the silent `:cast` loss: pre-delivery `:no_such_actor` for fire-and-forget dispatches with `reply: :ignore` could still disappear from the caller perspective. `Ezagent.Invocation` now logs those pre-delivery cast failures and emits `[:ezagent, :dispatch, :cast_failed]` telemetry with `target`, `instance_uri`, `mode`, `reason`, and `stage: :pre_delivery`. Return semantics are unchanged.

## Files changed

- `apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs`
  - Added create-session regression for dispatch-budget latency plus durable finalized snapshot availability at return.
- `apps/ezagent_core/lib/ezagent/invocation.ex`
  - Added pre-delivery cast-failure logging and telemetry for unobservable `reply: :ignore` casts.
- `apps/ezagent_core/test/ezagent/invocation_test.exs`
  - Added regression proving `:cast + reply: :ignore` missing actor failure is logged and telemetered.

## Validation

- `mix test apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs` passed: 4 tests, 0 failures.
- `mix test apps/ezagent_core/test/ezagent/invocation_test.exs` passed: 12 tests, 0 failures.
- `mix format --check-formatted` passed.
- `mix ezagent.check_invariants` passed: all in-scope invariants clean.
- `mix precommit` passed.

## Caveats

- `mix precommit` initially failed because `apps/ezagent_web/assets/node_modules` was missing; `npm install` in that asset directory restored local dependencies and did not change tracked files.
- Mix commands needed escalated execution in this environment because sandboxed Mix hit local TCP/PubSub `:eperm`.
- The full precommit emits existing test-intentional warnings/errors from other subsystems; the command exited successfully.

## Next

Draft PR #934 is open from `fix/session-snapshot-race` into `target/session-snapshot-race`. The target branch can later be merged to `main` with any sibling Bug A/B slices once reviewed.
