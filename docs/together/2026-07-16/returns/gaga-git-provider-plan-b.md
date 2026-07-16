> **Task:** gaga — Git Provider V1 Plan B domain spine
> **Branch:** `test/git-task-dispatch-integration`
> **Stacked on:** Plan B Tasks 0–9 base `c1ecc1a2d`
> **PR:** none
> **Dev:** gaga / Codex
> **returned_at:** 2026-07-16 22:01 +0800
> **deadline:** 2026-07-16 23:59 +0800
> **deadline_status:** deferred
> **Status:** Task 11 locally verified; Task 12 full precommit/CI/PR handoff is explicitly deferred

# Return summary

Tasks 0–11 now form a locally verified provider-neutral, in-memory Git domain
spine. Task 11 proves the exact-resource authorization and adapter-dispatch path
through real application boot, Resource lifecycle, Invocation, Router, and Kind
runtime. Task 12 and all external-provider/operational completion remain open. No
deployment or merge is authorized.

## DoD reconciliation

| # | DoD line | Status | Proof / open decision |
|---|---|---|---|
| 1 | Track refined Plan B design and executable plan | met for Task 0 | tracked spec/plan files on this branch |
| 2 | Freeze Plan A four structs, five callbacks/actions, and full error union | met for Task 0 | tracked design exact Elixir contracts |
| 3 | Freeze five minimum provider-neutral auxiliary shapes | met for Task 0 | architecture review fixes applied: stored base/head authority, total check normalization, submitted/latest review events |
| 4 | Record exact Tasks 2–3 assertions; keep SSH/merge absent | met for Task 0 | tracked design §13.1 and adapter section |
| 5 | Scaffold and boundary-test the domain app | met for Task 1 | focused test 2/0; compile exit 0; undeclared-dependency/layer-purity gates 4/0 |
| 5a | Freeze Task 2 construction and limit API | met | approved contract through review fixes at `f93487535` |
| 5b | Implement provider-neutral values | met for Task 2 | strict RED; full domain app 16/0; warning-clean compile; final applicable core static gates 12/0 |
| 6 | Boot real Git supervisors/registrations and pre-spawn the authoritative ephemeral Resource | met for Task 11 | `git_task_dispatch_test.exs` asserts all real processes and five boot bindings before `TaskAccessSupervisor.ensure_started/1` |
| 7 | Use two synchronized fakes, Task 7 exact held-admin signed artifact, and real Invocation/Router | met for Task 11 | integration proof passes for both providers with receiver-bound `Cap.verify_for/2` fixture |
| 8 | Prove exact normalized routing with zero cross-provider call | met for Task 11 | provider A/B return distinct normalized `RepositoryRef` values; synchronized mailbox assertions exclude the other adapter |
| 9 | Prove no-cap zero registry/Resource/provider effects | met for Task 11 | denial is `{:error, :unauthorized}`; diagnostics and policy slice are byte-for-byte equal; no call/mutation message |
| 10 | Prove stale-base zero provider mutation | met for Task 11 | selected B callback is observed, `:stale_base` returned, no mutation or A callback observed |
| 11 | Deterministic cleanup | met for Task 11 | adapter unregister and Resource teardown are registered with `on_exit`; no sleep or shared probe process |
| 12 | PR-head CI green, rebased main, full precommit, PR/review/merge/deploy | deferred | Task 12 was explicitly excluded; open decision for lead is whether/when to run the external machine-return flow |

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

Task 2 pre-RED review amendment freezes the constructor/error/config boundary and
promotes Plan A's tested prototype limits as operator-configurable, domain-owned V1
defaults. This is documentation only and remains architecture-review-required; no
Task 2 test, compile, precommit, CI, or readiness result is claimed.

Task 2 review fixes further freeze non-raising pre-child config validation, fixed
non-echoing unknown-field handling, exact URI/ref rules, upstream capture ownership
for filesystem kind, and shared lowercase V1 SHA-1 validation. The proposed
`ObjectId` rename was not selected because Plan A's exact `ChangeRequest.head_sha`
field and approved `CommitSha` auxiliary name are frozen; the shared validator
prevents a raw-string bypass. Re-review is still required before RED, and no Task 2
test or production result is claimed.

After approval, Task 2 captured RED for missing value structs and a separate
path-control-byte regression, then reached GREEN: focused Task 2 14/0 and
`mix compile --warnings-as-errors` exit 0. Final verification expands to the full
domain app at 16/0 and applicable core dependency/layer/URI gates at 12/0. Full
precommit, CI, PR readiness, provider integration, deployment, and merge are not
claimed.

Task 2 review fixes captured 14/3 RED for unsafe nested SHA acceptance and two
forged-input crashes, then GREEN at full domain app 17/0. The Error union assertion
now parses actual union AST with an extra-member negative fixture. Warning-clean
compile and applicable core dependency/layer/URI gates 13/0 pass; full precommit/CI
is still not claimed.

## Deferred boundary

GitHub plugin/API, credentials/tokens, checkout/worktrees, Kanban, canary, #1360
Layer B final mount, real PR/CI/review/merge, full precommit, deployment, and merge
remain out of scope. This return proves only a provider-neutral in-memory domain
spine and is not a valid machine-gated final return until Task 12 is authorized.

## Task 11 environment, commands, and blockers

- Environment: local Linux worktree, Elixir 1.19.2, `SHELL=/bin/bash`; dependencies
  and build artifacts reused from `/home/huangjiajia/ezagent/{deps,_build}` because
  the isolated worktree had no local dependency tree.
- TDD RED: after resolving that environment prerequisite, the focused umbrella
  integration run reached ExUnit and failed 3/3 at adapter registration with
  `{:invalid_adapter_module, SynchronizedGitAdapterA}`. Missing dependencies and
  unset `SHELL` were recorded only as environment blockers, not counted as RED.
- TDD GREEN: `mix test apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`
  passed 3 tests, 0 failures.
- Full domain: `mix test apps/ezagent_domain_git/test` passed 83 tests, 0 failures.
- Static gates: `mix ezagent.arch.scan` passed all counters and
  `mix ezagent.check_invariants` passed all in-scope invariants. The inherited
  Tasks 2–9 base is not fully static-green: `ezagent.doc.scan` reports exactly 20
  undocumented public defs in existing `ezagent_domain_git/lib` code (424 > 404),
  and hard-fail `ezagent.uri_query.scan` reports six existing domain-value findings
  (three positional URI reads, three tenant-derivation heuristics). Task 11 adds no
  `lib` code and does not weaken a baseline or hide these failures.
- Blockers: Task 11's implementation proof has no blocker. The two inherited
  static-gate failures require an owned follow-up before Task 12 can claim a valid
  machine return. Full precommit, CI, PR, rebase-to-current-main, review, merge,
  canary, and deployment were intentionally not run in Task 11.

**Method friction:** The worktree did not contain `deps/` or `_build/`, and direct
app-only execution cannot load `Ezagent.Identity.read_held_caps/1`, which Task 7's
real held-admin fixture requires. The truthful focused command therefore runs from
the umbrella root with the shared local dependency/build paths and `SHELL` set.

## Merge request

Commit the Task 11 slice on `test/git-task-dispatch-integration` and return its SHA
to the lead. Do not push, open a PR, merge, deploy, or present this as Task 12/CI
completion.
