> **Task:** gaga — Git Provider V1 Plan B domain spine
> **Branch:** `feat/git-domain-spine`
> **Stacked on:** Plan A PR #1423
> **Dev:** gaga / Codex
> **returned_at:** deferred — WIP skeleton only
> **deadline:** 2026-07-16 23:59 +0800
> **deadline_status:** deferred
> **Status:** WIP — Task 1 complete; CI/precommit/PR/merge completion is not claimed

# Return summary

Task 0 freezes the Plan A contract and its reviewed auxiliary-type amendment. Task
1 scaffolds an independent provider-neutral domain OTP app with exactly one inward
umbrella dependency, `ezagent_core`, and an executable dependency-boundary test.
Tasks 2–12 remain deferred. No deployment or merge is authorized.

## DoD reconciliation

| # | DoD line | Status | Proof / open decision |
|---|---|---|---|
| 1 | Track refined Plan B design and executable plan | met for Task 0 | tracked spec/plan files on this branch |
| 2 | Freeze Plan A four structs, five callbacks/actions, and full error union | met for Task 0 | tracked design exact Elixir contracts |
| 3 | Freeze five minimum provider-neutral auxiliary shapes | met for Task 0 | architecture review fixes applied: stored base/head authority, total check normalization, submitted/latest review events |
| 4 | Record exact Tasks 2–3 assertions; keep SSH/merge absent | met for Task 0 | tracked design §13.1 and adapter section |
| 5 | Scaffold and boundary-test the domain app | met for Task 1 | focused test 1/0; compile exit 0; undeclared-dependency/layer-purity gates 4/0 |
| 6 | Implement/test the remaining domain spine | deferred | Tasks 2–12 not started |
| 7 | PR-head CI green and rebased on main | deferred | explicitly not claimed by this WIP record |
| 8 | Return/merge/deploy complete | deferred | lead flow and external-state operations not authorized |

## Verification evidence

Task 0 `git diff --check` and targeted contract/exclusion `rg` checks pass. The
stacked Plan A environment probe is recorded as 7 tests, 0 failures; Task 0 itself
adds no runtime code/tests. CI/rebase/return completion remains deferred.

Review-fix verification additionally confirms request-side `base_ref`,
`Review.author`, and review `:pending` are absent, while `allowed_head_ref`, total
check projection, `author_label`, and stable-event dedupe rules are present.

Task 1 strict TDD captured the dependency boundary RED (`[]` versus
`[:ezagent_core]`), then GREEN after adding only the approved dependency. Focused
compile passed; the existing undeclared umbrella dependency and layer-purity gates
passed 4 tests. The first green-test attempt was environment-blocked by unset
`SHELL` during `erlexec` startup; `SHELL=/bin/bash` produced the reported pass.

Task 1 review fix: replaced the source-regex inventory with authoritative
`Mix.Project.config()[:deps]` tuple normalization. The focused suite now includes a
path-form forbidden-dependency fixture proving it is both inventoried and rejected
when `in_umbrella: true` is absent.

## Deferred boundary

GitHub plugin, credentials/tokens, checkout/worktrees, Kanban, canary, #1360,
AgentRuntime ARB, EntityCaps, bridge join, SSH, merge, Task 2+ production types and
behavior, full CI/precommit/PR return, deployment, and merge remain out of scope.
