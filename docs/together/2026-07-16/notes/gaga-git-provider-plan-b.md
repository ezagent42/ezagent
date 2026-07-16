# gaga — Git Provider V1 Plan B execution ledger

**Date:** 2026-07-16

**Track:** agent development bootstrap — provider-neutral Git domain spine

**Owner:** gaga / Tasks 0–11 implementation stack

**Worktree:** `/home/huangjiajia/ezagent/.worktrees/plan-b-task11-integration`

**Branch:** `test/git-task-dispatch-integration`

**Baseline/head at Task 0 start:** `3ce1439afec1a1cfffd624fdff8667bb6f5b80a2`

**Stacked dependency:** Plan A PR #1423; this branch contains its landed decision
record and does not claim #1423 is merged to `origin/main`.

## Scope and honesty boundary

Tasks 0–11 implement and locally prove the provider-neutral, in-memory
`ezagent_domain_git` spine. Task 11 adds only integration/support tests; it does not
add an external provider or broaden the production boundary.

No GitHub plugin, credential/token work, checkout/worktree provisioning, Kanban
integration, canary, #1360, AgentRuntime ARB, EntityCaps, bridge join, SSH callback,
merge operation, deployment, or merge is authorized or claimed.

## Environment probe

Plan A's focused probe baseline on the stacked dependency is **7 tests, 0 failures**
(2 OS-process isolation tests plus 5 pure Git Data request-plan tests), recorded in
`docs/together/2026-07-16/notes/gaga-git-provider-plan-a.md`. Task 0 adds no runtime
code or tests; its verification is documentation/static consistency only.

## Task status

| Task | Status | Result |
|---|---|---|
| Preflight/read required evidence | complete | Read Task 0 brief, local design/plan, Plan A decisions/design/plan and daily records; inspected current Git terminology and W29 prototype |
| Task 0 contract freeze | complete | Exact Plan A structs, callbacks/actions, and error union frozen; five auxiliary closed shapes corrected per architecture review |
| Task 1 independent app scaffold | complete | Empty OTP supervision tree; exact approved umbrella deps `[:ezagent_core]`; dependency boundary test GREEN |
| Tasks 2–9 domain implementation | complete | closed values/errors, adapter contract/registry, ephemeral Resource lifecycle, exact signed-cap fixture, authorized ActionSet dispatch, and atomic boot registration are present in the inherited stack |
| Task 10 structural gates | parallel/open at Task 11 start | owned by the parallel core-gate slice; Task 11 does not edit its files or claim its result |
| Task 11 integration proof | complete locally | real boot + pre-spawned Resource + two synchronized fakes + exact signed Cap + real Invocation/Router; exact routing/no cross-call, no-cap zero effects, stale zero mutation |
| Task 12 verification/review/WIP handoff | open | no full precommit, CI, broad review, or WIP PR claimed; merge/deploy are separate lead-authorized operations |
| External provider/operational breadth | out of scope | no GitHub, credentials, checkout/worktrees, Kanban, canary, merge, deploy, or #1360 final mount claimed |

## Changes

- tracked the refined Plan B design and executable plan;
- recorded exact incremental Tasks 2–3 assertions and absence of merge/SSH callbacks;
- proposed closed `CreateChangeRequest`, `ChangeRequestId`, `CommitSha`, `Check`,
  and `Review` contracts with repository evidence;
- created this durable ledger and an explicitly WIP return skeleton.
- scaffolded the normally discovered `apps/ezagent_domain_git` OTP application;
- added a domain-local architecture test enforcing the exact inward dependency and
  forbidding provider, Phoenix, socialware/Kanban, and workspace-provision deps.

## Commands and results

```text
git status --short --branch                         -> feat/git-domain-spine, clean at start
git rev-parse HEAD                                  -> 3ce1439afec1a1cfffd624fdff8667bb6f5b80a2
rg (Git type/W29 terminology and prototype evidence) -> evidence cited in tracked design
git diff --check                                    -> PASS (no output)
targeted rg consistency                             -> PASS; required contracts/exclusions present
```

## Task 1 TDD evidence

```text
mix test test/architecture/dependency_boundary_test.exs
  RED -> 1 test, 1 failure; actual [] != expected [:ezagent_core]

mix compile
  GREEN -> Generated ezagent_domain_git app; exit 0

SHELL=/bin/bash mix test test/architecture/dependency_boundary_test.exs
  GREEN -> 1 test, 0 failures

SHELL=/bin/bash mix test \
  apps/ezagent_core/test/architecture/undeclared_umbrella_dep_test.exs \
  apps/ezagent_core/test/invariants/layer_purity_test.exs
  GREEN -> 4 tests, 0 failures
```

The first post-change focused-test attempt was environment-blocked before ExUnit by
`erlexec` because `SHELL` was unset; rerunning with `SHELL=/bin/bash` passed. The
architecture-gate run emitted existing local seed-state warnings and passed.

## Review-fix change entry

Task 0 review fixes applied after commit `c7de2619d`:

- removed request-side `CreateChangeRequest.base_ref`; stored-policy-bound
  `RepositoryRef.base_ref` is authoritative;
- added authoritative policy `allowed_head_ref`, exact normalized equality before
  registry lookup, and explicit expected-base-SHA concurrency semantics;
- added total check normalization with `:action_required`/`:other` and a complete
  non-green W29 projection rule;
- changed `Review` to a submitted/latest event, removed `:pending`, renamed
  `author` to display-only `author_label`, and made `external_id` the sole event
  dedupe coordinate;
- updated the executable plan, exact Tasks 2–3 assertions, return skeleton, and
  ignored execution report consistently.

## Historical Task 1 checkpoint

At this checkpoint, Task 1 was complete on the inherited Plan A stack while Task 2+
remained deferred. This paragraph is preserved as execution history; the current
status is Tasks 0–11 locally implemented and verified as recorded above. Full Task
12 verification/review/WIP handoff is still open, and merge/deploy require separate
lead authorization.

## Task 2 pre-RED contract amendment

Task 2 stopped before RED because constructor signatures and configured limits were
not frozen. The review-required amendment now freezes an exact atom-keyed-map
`new/1` boundary for every value, a closed non-echoing `ValidationError`, and
domain-owned `ChangeLimits.current/0` defaults of 100 files, 1,000,000 bytes per
file, and 5,000,000 aggregate bytes. The defaults are promoted from Plan A's tested
prototype; operators may configure them, but agents and adapter/invocation arguments
cannot. `FileChange.validate_many/1` is the sole collection-limit boundary.

No tests or production code begin until architecture review approves this amendment.

## Task 2 contract-review fixes

Review adjudication closes the remaining ambiguity without starting RED. Limits are
a closed struct and runtime `current/0` result, validated non-raising before any app
child; unknown keys use fixed `:unknown_fields` with no echo. URI roles now separate
canonical Ezagent resource/entity axes from absolute provider web URLs. The ref
subset is exact and preservation-only. V1 SHA-1 validation is shared so both the
frozen `CommitSha.value` and Plan A-frozen `ChangeRequest.head_sha` normalize to
lowercase; SHA-256 needs a future contract revision.

`FileChange` represents captured UTF-8 regular-file bytes and has no kind/mode/
rename/delete axes. Symlink/submodule inspection stays at the upstream capture
boundary. The reviewer alternative to rename the SHA field/type to `ObjectId` was
not chosen because Plan A freezes `ChangeRequest.head_sha: String.t()` and the
approved auxiliary name `CommitSha`; shared validation closes the V1 bypass without
changing that exact contract. Re-review remains required before RED.

## Task 1 review-fix entry

Review found the source-regex dependency inventory could miss valid Mix forms such
as `{:ezagent_domain_identity, path: ...}`. The gate now reads the authoritative
`Mix.Project.config()[:deps]`, normalizes valid two- and three-tuple dependency
forms, asserts the exact dependency names, and separately requires every
`ezagent_*` dependency to declare `in_umbrella: true`. A synthetic path-form
fixture proves the forbidden dependency is inventoried and reported without
mutating `mix.exs`.

## Task 2 implementation

After contract approval at `f93487535`, strict TDD captured the expected missing
value-struct RED and a later path-control-byte RED. The final full domain app suite
passes 16 tests with warning-clean compilation. Applicable final core
undeclared-dependency, layer-purity, and URI-canonicalization gates pass 12 tests.

Only approved provider-neutral values, `Error`, `ValidationError`, runtime
`ChangeLimits`, collection validation, and pre-child application config validation
were implemented. Adapter, registry, Resource, ActionSet, provider, HTTP/
credentials, persistence, UI, and Kanban remain absent. Full precommit/CI/readiness
is not claimed.

## Task 2 review-fix implementation

Regression RED reproduced three findings: forged nested `CommitSha` accepted,
non-URI OperationContext input raised during workspace extraction, and forged
FileChange content raised in `byte_size/1` (14 tests, 3 failures). Fixes validate
URI roles before workspace access, require an exact lowercase SHA wrapper, and
revalidate FileChange invariants before limits. The Error union gate now parses the
actual `@type t` AST and an extra-member fixture proves drift detection. The
ValidationError callback spec now accepts tuple reasons.

Post-fix full domain app: 17/0; warnings-as-errors compile passes; applicable core
dependency/layer/URI gates: 13/0. Full precommit/CI remains unclaimed.

## Task 11 integration proof

Task 11 started from the integrated Tasks 0–9 base `c1ecc1a2d`; Task 10 ran in a
parallel slice and its core-gate files were not touched here. Strict TDD first added
the integration contract. Missing worktree dependencies and unset `SHELL` blocked
Mix before ExUnit and were not counted as RED. With `SHELL=/bin/bash` and the main
checkout's local `deps`/`_build`, the umbrella-root run reached the intended RED:
3 tests, 3 failures because the synchronized adapters did not exist. The minimal
test-support adapters/probe then produced GREEN: 3 tests, 0 failures.

The proof observes real `EzagentDomainGit.Application`, `BootRegistration`,
`AdapterRegistry`, `TaskAccessSupervisor`, and all five boot capability bindings;
pre-spawns an ephemeral policy Resource; uses only Task 7's held-admin, exact
receiver-bound signed artifact; and calls `Ezagent.Invocation.dispatch/1`. The two
fakes synchronize directly with the owning test process through the handler-built
idempotency coordinate, so absence assertions require neither sleep nor a shared
probe. Every adapter registration and Resource is cleaned with `on_exit` plus
explicit per-iteration teardown.

Verified scope remains provider-neutral and in-memory. There is no GitHub API,
credential, checkout/worktree provisioning, persistence claim, Kanban, canary,
real PR/CI/review/merge, deployment, or #1360 Layer B final mount. Task 12 full
precommit/CI/WIP-PR handoff remains open.

Fresh verification passed focused integration 3/0, full domain 83/0,
`ezagent.arch.scan`, and `ezagent.check_invariants`. Two inherited static debts are
recorded rather than concealed: `ezagent.doc.scan` is 424 > 404 due to 20 public
defs under existing domain `lib`, and hard-fail `ezagent.uri_query.scan` finds six
existing domain-value heuristics (three positional URI reads and three tenant
derivations). Task 11 changes test/docs only; it neither raises baselines nor edits
the inherited production value modules.
