# Handoff: self-target per-instance action capability resolution

> **Date:** 2026-07-20
> **From:** Codex
> **To:** Allen
> **Base:** `origin/main` @ `fe290643133cf3f8e9de932236c5d64623748122`
> **Status:** `clarify_first` — root cause proven; choose the CapBAC-safe repair shape before implementation

## Mission

Fix agent result self-dispatch for recipe-loaded per-instance actions. A Hello
message is accepted and persisted, but the front-desk agent raises
`{:unknown_action, :hello_sync_result}` before it can enqueue its self-dispatch.
The same design must be checked for `:py_sync_result` and
`:cc_headless_sync_result`; do not add a Hello-only fallback.

This is separate from the normal-user stale `session.send` capability defect,
which is being fixed on `fix/g5-cap-reconciliation`.

## Proven root cause

`Ezagent.ActionSet.Agent.Receive.sync_result_effect/4` builds a flavor-specific
self target and synchronously issues a new cap:

```elixir
{:ok, signed_cap} =
  Ezagent.Cap.issue_for_action({:admin, admin}, self_uri, target)
```

See `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:291-302`.

Because the caller is already executing inside the target Agent process,
`Cap.issue_for_action/3` takes its `pid == self()` branch. That branch resolves
the action only through the global `BehaviorRegistry`:

- `apps/ezagent_core/lib/ezagent/cap.ex:78-106`
- `apps/ezagent_core/lib/ezagent/cap.ex:119-131`

`Ezagent.ActionSet.HelloOrchestrator` is recipe-loaded into the concrete agent's
effective behavior set; it is intentionally not a global Agent action. External
issuance reads the live runtime state and calls `BehaviorSet.resolve_action/3`,
so materialization can successfully issue and persist the cap. Self-target
issuance cannot synchronously call its own GenServer and therefore reports
`{:unknown_action, :hello_sync_result}`.

Both the admin-created and G5-created Hello sessions exhibited the same
downstream exception. Their front-desk snapshots contained
`Ezagent.ActionSet.HelloOrchestrator` and an already signed
`:hello_sync_result` capability, which falsifies the missing-overlay hypothesis.

## Important design question

The agent already holds the exact target-signed self-action artifact. The
preferred capability model is normally “present held authority”, not “mint a
fresh artifact for every message”. Investigate this repair first:

1. Declare the minimal explicit `:identity` sibling-slice read for
   `Ezagent.ActionSet.Agent.Receive`.
2. Build the deferred self-dispatch with the agent's held capability set (or a
   narrowly selected exact-action set).
3. Let the normal target `Cap.Verifier` validate presenter binding, current
   signature, action, and instance when the deferred command executes.

Compare that with the alternative of extending the current-target authority
context so `issue_for_action/3` can resolve the effective per-instance
`BehaviorSet` without a self GenServer call. The latter changes a core runtime
boundary and must not expose arbitrary sibling state or create a second action
registry/signer.

Do not:

- globally register Hello-specific actions on `Ezagent.Entity.Agent`;
- bypass or weaken `Cap.Verifier`;
- special-case the `hello` flavor;
- catch the bad match and silently drop the result;
- read private Kind state through an ad-hoc process-dictionary escape hatch.

## Required tests

Add a production-path integration test that materializes a real Hello
front-desk agent and dispatches a user message through the Session. It must prove:

1. the user message is persisted;
2. `Agent.Receive` resolves the in-process result;
3. the deferred `:hello_sync_result` self-dispatch is authorized;
4. the Hello agent produces its expected reply/effect;
5. the same behavior survives a cold restart of the agent/session;
6. no `{:unknown_action, :hello_sync_result}` or `:behavior_exception` is emitted.

Add a focused matrix covering:

| action class | external issuance | self dispatch |
|---|---:|---:|
| globally registered Agent action | succeeds | succeeds |
| recipe-loaded Hello action | succeeds | succeeds |
| recipe/flavor-loaded py action | succeeds | succeeds |
| per-instance cc-headless action | succeeds | succeeds |

If a flavor is not configured in the test environment, pin the shared mechanism
with a synthetic per-instance ActionSet rather than weakening the matrix.

## Definition of Done

- [ ] The first failing boundary is covered by an automated regression test.
- [ ] The repair works for per-instance actions generically, with no plugin-name branch in core/domain Agent code.
- [ ] Existing target-signed, presenter-bound, fail-closed CapBAC semantics remain intact.
- [ ] There is still one action-resolution truth (`BehaviorSet.resolve_action/3`) and one strict verification truth (`Cap.Verifier`).
- [ ] Already materialized agents work after cold restart; document whether any cap backfill is required.
- [ ] A real `/session` Hello flow shows the user message and the subsequent agent result/reply.
- [ ] Relevant Agent, Hello, py/cc, core invariant tests and `mix precommit` pass.

## Return

Return a document under `docs/together/2026-07-20/returns/` containing:

- chosen repair shape and rejected alternative;
- exact failing and passing test commands/output;
- behavior/action-resolution matrix;
- restart result;
- migration/backfill conclusion;
- PR and commit links.
