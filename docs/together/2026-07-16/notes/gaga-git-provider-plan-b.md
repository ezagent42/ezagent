# gaga — Git Provider V1 Plan B execution ledger

**Date:** 2026-07-16

**Track:** agent development bootstrap — provider-neutral Git domain spine

**Owner:** gaga / Task 0 implementer

**Worktree:** `/home/huangjiajia/ezagent/.worktrees/git-domain-spine`

**Branch:** `feat/git-domain-spine`

**Baseline/head at Task 0 start:** `3ce1439afec1a1cfffd624fdff8667bb6f5b80a2`

**Stacked dependency:** Plan A PR #1423; this branch contains its landed decision
record and does not claim #1423 is merged to `origin/main`.

## Scope and honesty boundary

Task 0 is architecture/design documentation only. It freezes Plan A's four structs,
five adapter callbacks/actions, and full error union, and proposes the five minimum
auxiliary shapes that Plan A left undefined. It changes no production code, tests,
dependencies, lockfile, `.gitignore`, or Plan A PR file.

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
| Task 1+ production implementation | deferred | Must not start until #1423 lands and the branch is rebased onto current main |
| CI/rebase/dev-together return | deferred | Not claimed by this initial Task 0 documentation slice |

## Changes

- tracked the refined Plan B design and executable plan;
- recorded exact incremental Tasks 2–3 assertions and absence of merge/SSH callbacks;
- proposed closed `CreateChangeRequest`, `ChangeRequestId`, `CommitSha`, `Check`,
  and `Review` contracts with repository evidence;
- created this durable ledger and an explicitly WIP return skeleton.

## Commands and results

```text
git status --short --branch                         -> feat/git-domain-spine, clean at start
git rev-parse HEAD                                  -> 3ce1439afec1a1cfffd624fdff8667bb6f5b80a2
rg (Git type/W29 terminology and prototype evidence) -> evidence cited in tracked design
git diff --check                                    -> PASS (no output)
targeted rg consistency                             -> PASS; required contracts/exclusions present
```

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

## Blocker

Production Task 1+ remains deferred until stacked dependency #1423 lands and this
branch is rebased. CI/rebase/return/deploy/merge completion is not claimed.
