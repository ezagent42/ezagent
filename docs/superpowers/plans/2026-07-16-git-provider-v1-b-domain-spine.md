# Git Domain Spine (Plan B) Implementation Plan

> Executed on branch `feat/git-domain-spine`, stacked on Plan A PR #1423. Task 0
> documentation may land on this stack; the auxiliary shapes were corrected per
> architecture review. Production Task 1+ remains gated on #1423 landing and rebase.
> This plan authorizes no deploy or merge.

**Goal:** Land a provider-neutral Git domain spine whose exact-resource CapBAC path
dispatches authorized in-memory task actions to either of two fake adapters and
provably performs no effects when authorization fails.

**Architecture:** A new `ezagent_domain_git` app owns value types,
`GitTaskAccess`, its Lifecycle ActionSet, adapter contract, and registry. Provider
plugins depend inward on that contract. Registry lookup and adapter invocation are
allowed only behind the authorized ActionSet.

**Method:** strict TDD; each task begins with a failing focused test, implements the
minimum behavior, reruns the focused test, and commits only after relevant gates
pass.

## Preflight: rebase the design onto landed main

1. Fetch `origin` and verify Plan A's merge SHA is an ancestor of `origin/main`.
2. Confirm the Plan A worktree is clean and leave it intact until the Draft PR is
   merged/closed by the authorized lead flow.
3. Create a new isolated worktree from `origin/main` on
   `feat/git-domain-spine` using the repository's worktree convention.
4. Read root `AGENTS.md`, relevant skill instructions, the landed Plan A decision
   record, current architecture invariants, and current daily/weekly facts.
5. Re-run Plan A's focused probe tests on main. Record drift before changing code.
6. Re-check the exact Resource URI against the current URI SPEC and replace the
   semantic placeholder in the design with the canonical constructor.
7. Copy the approved design and this plan into the tracked documentation location;
   update paths below if mainline conventions changed.

Checkpoint: no production code until the rebased design diff is reviewed for scope
drift.

## Task 0: freeze the exact Plan A contract

**Expected files**

- Modify: the tracked Plan B design copied during preflight

1. Transcribe verbatim the approved `Ezagent.DomainGit.RepositoryRef`, `FileChange`,
   `ChangeRequest`, and `OperationContext` fields and the five callbacks
   `resolve_repository/2`, `create_change_request/4`, `read_change_request/3`,
   `list_checks/3`, and `list_reviews/3`.
2. Transcribe the complete approved `Ezagent.DomainGit.Error.t()` union.
3. Specify minimum provider-neutral shapes for the referenced but undefined
   `CreateChangeRequest`, `ChangeRequestId`, `CommitSha`, `Check`, and `Review` types.
   Obtain architecture review of this narrow contract amendment before production
   scaffolding; do not infer provider payload fields.
4. Record the exact source/compile assertions that Tasks 2–3 will add incrementally:
   namespaces, fields, callbacks, actions, error union, and forbidden
   credential/client/path fields.
5. Confirm Plan A's generic SSH/merge callbacks remain absent in the amendment.

Checkpoint: stop if the auxiliary types cannot be approved without changing Plan A.

Task 0's exact Tasks 2–3 assertions are frozen in the tracked design. The five
shapes are the only Plan A amendment and incorporate architecture review fixes;
generic SSH and merge callbacks remain absent.

Commit candidate: `docs(git): freeze plan b domain contract`

## Task 1: scaffold the independent domain app

**Expected files**

- Create: `apps/ezagent_domain_git/mix.exs`
- Create: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/test/test_helper.exs`
- Create: `apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs`

1. Scaffold only enough app/test infrastructure for focused Mix tests to run; add no
   production Git domain modules yet.
2. Write an architecture test asserting no provider/Phoenix/socialware/workspace-
   provision dependency.
3. Run the scaffold/dependency test to RED, add the minimum approved dependencies,
   then run it and app compilation to GREEN.
4. Run applicable dependency-direction/static architecture tests.
5. Expect normal umbrella `apps/*` discovery; change root configuration only if
   rebased main proves a repository-specific app manifest requires it.

Commit candidate: `feat(git): scaffold provider-neutral domain app`

## Task 2: define and validate provider-neutral values

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/repository_ref.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/file_change.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/change_request.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/operation_context.ex`
- Create: the five reviewed auxiliary type modules frozen in Task 0
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/validation_error.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/change_limits.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/value_contract_test.exs`
- Create: `apps/ezagent_domain_git/test/architecture/plan_a_contract_test.exs`

1. Write the first part of the Plan A contract gate for exact value namespaces,
   fields, auxiliary types, error union, and forbidden credential/client/path fields.
2. Write table-driven failing tests for valid construction and rejection of tokens,
   absolute/traversing paths, invalid UTF-8, empty refs, unknown fields, and
   provider-specific payload leakage.
3. Run both tests and confirm RED for missing types/validation.
4. Implement structs and explicit constructors without accepting arbitrary maps as
   trusted values.
5. Run all Task 2 contract/value assertions to GREEN before committing.
6. Exercise every applicable member of the frozen error union and distinguish
   provider errors from closed pre-adapter construction/policy errors.
7. Add a structural test scanning value modules for token/client/Req/Cap/local-path
   fields if the existing invariant suite has no reusable gate.
8. Assert `CreateChangeRequest` has no `base_ref`; `Review` has `author_label` and no
   `author`/`:pending`; and check normalization/projection is total, including
   `:action_required`/`:other` remaining non-green.
9. Before RED, obtain architecture approval for design §4.2. Then assert every
   value has the exact `new/1` atom-keyed map boundary and closed, non-echoing
   `ValidationError` results.
10. Assert the exact domain-owned `ChangeLimits.current/0` defaults and deterministic
    invalid-config failure. Cover `FileChange.validate_many/1` count/per-file/total
    byte limits and prove invocation/adapter input cannot override them.

Commit candidate: `feat(git): add provider-neutral operation values`

## Task 3: define the adapter contract

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/adapter.ex`
- Create: `apps/ezagent_domain_git/test/support/fake_git_adapter_a.ex`
- Create: `apps/ezagent_domain_git/test/support/fake_git_adapter_b.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/adapter_contract_test.exs`

1. Write one shared failing contract suite covering the five exact Plan A callbacks,
   their typed arguments, and every applicable closed normalized result/error shape.
2. Extend `plan_a_contract_test.exs` with exact callback/action assertions, then run
   the new assertions and two deliberately incomplete fakes to capture RED.
3. Add the behaviour callbacks/types and minimum complete fake implementations.
4. Run the expanded contract gate and shared suite against both fakes to GREEN before
   committing.
5. Confirm no callback accepts raw credentials, raw Caps, Req clients, or local
   checkout paths.

Commit candidate: `feat(git): define provider adapter contract`

## Task 4: implement deterministic adapter registration

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/adapter_registry.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/adapter_registry_test.exs`

1. Write failing tests for register/lookup/list, invalid provider ids, missing
   behaviour/callbacks, idempotent same-module registration, and conflicting
   duplicate registration.
2. Add concurrency coverage so two conflicting registrations have one deterministic
   winner and no corrupt entry.
3. Run focused tests to capture RED.
4. Implement the registry using the established owned-table/process primitive from
   main, not an ad hoc table owner.
5. Run registry tests to GREEN and prove registration invokes no adapter callback.
6. Keep adapter-selecting `lookup/1` internal to the ActionSet path. Expose
   non-effectful operator listing, if needed, through a domain-owned diagnostic API.

Commit candidate: `feat(git): add validated adapter registry`

## Task 5: define the ephemeral GitTaskAccess Resource policy

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/entity/git_task_access_test.exs`

1. Write failing tests for the canonical exact URI, task/provider/repository binding,
   `:ephemeral` persistence policy, and rejection of cross-workspace or malformed ids.
2. Run focused tests and capture RED.
3. Freeze a closed authoritative task policy: task, generation, `workspace_uri`,
   credential-owner/entity URI, assigned agent/grantee URI, normalized repository,
   provider binding, normalized `allowed_head_ref`, allowed actions,
   and non-secret idempotency inputs. Invocation args may not provide context,
   provider selection, credential owner, or mutable policy coordinates.
4. Implement `pattern: :resource`, `persistence/0 == :ephemeral`, and canonical
   `uri_from_args/1` using `Ezagent.URI.resource/3`. Use `with_action/3` for action
   targets and never concatenate URI strings.
5. Specify idempotent same-policy initialization and reject conflicting initialization.
6. Run focused Kind and URI gates to GREEN.
7. Assert `allowed_head_ref` is authoritative and cannot be changed or selected by
   invocation arguments.

Commit candidate: `feat(git): add task-scoped access resource`

## Task 6: own Resource spawn and teardown

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/task_access_lifecycle_test.exs`

1. Write failing tests proving an absent ephemeral Resource returns the canonical
   no-instance result and is never snapshot-lazy-restored.
2. Add a domain-owned DynamicSupervisor and supported `Ezagent.Kind.spawn/2` setup
   that pre-spawns the Resource with validated authoritative policy.
3. Test same-policy duplicate spawn, conflicting-policy collision, supervised
   teardown, and test cleanup.
4. Add a dispatch-versus-teardown race test: once removal wins, no new adapter entry
   may occur; an in-flight operation follows the repository's defined termination
   semantics and cannot execute after teardown completion.
5. Cover child-start cleanup, repeated supervisor start, and registry restart without
   registering production CapabilityRegistry bindings yet.
6. Run fresh-loader, plugin-isolation, supervisor, lifecycle, and race tests to GREEN.

Commit candidate: `feat(git): own task access resource lifecycle`

## Task 7: add a receiver-bound exact-cap fixture

**Expected files**

- Create: `apps/ezagent_domain_git/test/support/git_cap_fixture.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/cap_fixture_test.exs`

1. Write failing tests constructing a concrete required capability with exact Kind,
   ActionSet, action, workspace, and `Ezagent.URI.instance(task_access_uri)` axes.
2. Issue it only with `Cap.issue(authorization, grantee_uri, capability)` using the
   repository's legitimate governance/test authorization fixture.
3. Assert `Cap.verify_for(artifact, grantee_uri)` and present only the issued artifact
   through the actual grantee's Invocation context.
4. Add rejection tests for wrong grantee, action, task instance, and workspace.
5. Structurally forbid raw `%Capability{}` injection as an authorization artifact,
   unsigned caps, and `:any` workspace/instance axes in these tests.

Commit candidate: `test(git): issue exact receiver-bound task caps`

## Task 8: implement the Lifecycle ActionSet behind CapBAC

**Expected files**

- Create: `apps/ezagent_domain_git/lib/ezagent/action_set/git_task_access.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs`
- Create: `apps/ezagent_domain_git/test/support/git_effect_probe.ex`

1. Write the unauthorized test first. Dispatch through the real invocation path
   without the exact cap; assert the canonical authorization error and zero registry
   lookup, adapter callback, HTTP sentinel, secret sentinel, and filesystem probe.
2. Run it and confirm RED for the missing Kind/ActionSet path—not because the test
   bypasses dispatch.
3. Write an authorized test using only Task 7's signed receiver-bound artifact and
   assert one fake adapter receives the handler-constructed `OperationContext`.
4. Add failing mismatch tests for wrong resource, workspace, repository, provider,
   unsupported action, `head_ref != allowed_head_ref`, stale `expected_base_sha`,
   and attempted caller-supplied context/provider/base-ref coordinates.
5. Implement `use Ezagent.Lifecycle` ActionSet with validation before registry lookup
   and adapter invocation. Select the adapter exclusively from stored Resource policy;
   request repository data is comparison-only. Resolve the authoritative base ref
   from stored policy, require exact normalized head-ref equality, and check the
   expected base SHA concurrency assertion before lookup/effects.
6. Use one per-test synchronous probe ref. If a fake callback is entered it must trip
   adapter, HTTP, secret, and filesystem bomb sentinels before returning. Run non-async
   or with unique process/registry names, clean with `on_exit`, and synchronize with a
   barrier rather than sleep before asserting no messages.
7. Run focused tests to GREEN, including both fake providers.

Commit candidate: `feat(git): dispatch task operations through CapBAC`

## Task 9: register production bindings with all-or-nothing rollback

**Expected files**

- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/test/ezagent_domain_git/application_boot_test.exs`

1. After the complete ActionSet exists, write failing tests for normal
   CapabilityRegistry/action registration, repeated identical boot, Nth binding
   failure, and cleanup of every binding created by that startup attempt.
2. Add two provider adapter declarations and inject an Nth adapter-registration
   failure. Assert attempt-owned adapter rows are removed while pre-existing adapter
   rows and CapabilityRegistry bindings remain intact.
3. Cover later child failure, adapter-registry restart/reconciliation, application
   restart, and absence of partial global ETS state.
4. Implement all-or-nothing startup bookkeeping. Roll back only rows/bindings created
   by the failed attempt; never unregister pre-existing identical state.
5. Prove adapter declaration and rollback never execute an adapter callback.

Commit candidate: `feat(git): make domain boot registration atomic`

## Task 10: add structural bypass and isolation gates

**Expected files**

- Create: `apps/ezagent_core/test/architecture/git_adapter_boundary_test.exs`
- Modify: architecture baseline manifest only through the repository's authorized
  baseline workflow and only when a genuine new invariant row is required

1. Write a repository-wide failing source-structure gate allowing adapter-selecting
   registry lookup and callbacks only inside the domain-owned ActionSet; registry
   internals may validate declarations but may not execute callbacks.
2. Add dependency assertions that provider modules do not appear in the domain app.
3. Add forbidden-field assertions for tokens/credentials/Req/local paths in domain
   structs and callback signatures.
4. Keep domain-local behaviour/value contract tests in `ezagent_domain_git`, while
   cross-app bypass/dependency detectors live unconditionally in core architecture.
5. Run gates to RED against controlled positive and negative fixtures, then GREEN after the rule is
   correct. Avoid a self-fulfilling scan that never exercises the detector.

Commit candidate: `test(git): enforce provider and authorization boundaries`

## Task 11: integration proof and documentation

**Expected files**

- Create: `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`
- Modify: tracked Plan B spec/plan docs selected during preflight
- Modify: `docs/together/2026-07-16/returns/...` when returning the slice

1. Write an integration test that boots the real supervisors, pre-spawns an ephemeral
   Resource with authoritative policy, registers two fakes, uses Task 7's exact signed
   artifact, and dispatches through the real Router/Invocation path.
2. Assert exact routing, normalized result, and no cross-provider call.
3. Repeat without the Cap and assert zero mutation/effects.
4. Document the honest boundary: provider-neutral in-memory spine only; no GitHub,
   checkout, persistence, Kanban, canary, or merge.
5. Record commands, environment, results, and blockers in the dev-together return.

Commit candidate: `test(git): prove exact-resource adapter dispatch`

## Task 12: verification and WIP PR handoff

1. Ensure the worktree contains no unrelated user changes.
2. Run formatter and the domain's focused tests.
3. Run all relevant architecture/static gates, including plugin isolation, dispatch
   bypass, CapBAC, URI, and dependency-direction checks.
4. Run the umbrella regression set required by current repository guidance.
5. Run `mix precommit` and inspect the complete exit status/output.
6. Reproduce any failure from clean `origin/main` before classifying it as baseline;
   do not weaken gates or update baselines to hide a failure.
7. Request code review, address findings with reproduce-first discipline, then push
   a WIP PR. Do not deploy or merge without lead-flow authorization.
8. PR description must list implemented, explicitly skipped, verification evidence,
   known blockers, and the next slices (provider plugin, credential UI, workspace
   provision, Kanban integration, canary E2E).

Final done-condition: Plan B's two-fake exact-resource proof and zero-effect denial
proof are green, documentation is accurate, and the branch is left in a reviewable
WIP state without claiming the W29 canary loop is complete.
