# gaga — Git Provider V1 Plan B execution ledger

**Date:** 2026-07-16

**Track:** agent development bootstrap — provider-neutral Git domain spine

**Owner:** gaga / Task 0–1 implementer

**Worktree:** `/home/huangjiajia/ezagent/.worktrees/git-domain-spine`

**Branch:** `feat/git-domain-spine`

**Baseline/head at Task 0 start:** `3ce1439afec1a1cfffd624fdff8667bb6f5b80a2`

**Stacked dependency:** Plan A PR #1423; this branch contains its landed decision
record and does not claim #1423 is merged to `origin/main`.

## Scope and honesty boundary

Task 0 freezes Plan A's contract. Task 1 adds only the independent
`ezagent_domain_git` OTP-app scaffold and its dependency-boundary test. The app has
no production Git domain types or behavior and depends inward only on
`ezagent_core`.

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
| Task 2+ production implementation | deferred | No value types, adapter, Resource, ActionSet, registry, migrations, provider plugin, UI, workspace, or Kanban code |
| CI/rebase/dev-together return | deferred | Not claimed by this Task 1 implementation slice |

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

## Current boundary

Task 1 is complete on the inherited Plan A stack. Full CI, `mix precommit`, rebase,
return readiness, deploy, and merge are not claimed. Task 2+ remains deferred.

## Task 1 review-fix entry

Review found the source-regex dependency inventory could miss valid Mix forms such
as `{:ezagent_domain_identity, path: ...}`. The gate now reads the authoritative
`Mix.Project.config()[:deps]`, normalizes valid two- and three-tuple dependency
forms, asserts the exact dependency names, and separately requires every
`ezagent_*` dependency to declare `in_umbrella: true`. A synthetic path-form
fixture proves the forbidden dependency is inventoried and reported without
mutating `mix.exs`.
