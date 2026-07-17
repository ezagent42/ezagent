# Task 5 report — deterministic fetched task branch

## Status

Implemented on baseline `1bcd504908d99edd8371159a3dfb2ca4c786fd11`.

## TDD evidence

- RED runner: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`
  - 16 tests, 3 failures.
  - Expected failures: fixed fetch command absent; moved/new refs returned no `resolved_base_commit`; worktrees remained on the old detached/DWIM path.
- RED persistence: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`
  - 36 tests, 1 failure.
  - Expected failure: prepared proof reached Provisioner but the ready row stored `resolved_base_commit` and `local_branch_ref` as `nil`.
- GREEN focused suite: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`
  - 54 tests, 0 failures.

## Command ordering and security probes

The argv probe asserts this exact prepare order:

1. bare clone when needed
2. `remote get-url origin`
3. fetch with only `+refs/heads/*:refs/ezagent/origin/heads/*` and `+refs/tags/*:refs/ezagent/origin/tags/*`
4. exact namespaced head probe
5. exact namespaced tag probe
6. `rev-parse --verify <resolved-ref>^{commit}`
7. worktree ownership listing
8. deterministic `branch -f`
9. attached `worktree add`

Every command is a binary argv list with credential helpers disabled, the fixed anonymous environment, no shell option, no credential material, no inherited environment, no caller-selected fetch refspec, and no `allowed_head_ref` in a Git plan. Real local Git fixtures prove moved refs and new refs are fetched through a reused cache. Further probes prove head/tag ambiguity fails closed and a deterministic branch checked out in another worktree is not reset.

## Persistence and duration

- `resolved_base_commit` accepts only a full lowercase 40- or 64-hex object ID.
- `local_branch_ref` is derived from the first 24 lowercase SHA-256 hex characters of `provision_id` plus generation.
- Both fields are required by `Store.ready_values/1`, persisted by `mark_ready`, and returned by Provisioner.
- Maximum provision duration now budgets eleven bounded command groups: clone, remote check, fetch, two ref probes, resolve, branch-owner verification, branch update, worktree add, and two ready verification commands.

## Files

- `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`
- `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex`
- `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`
- `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`
- `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs`
- `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

## Concerns

- Focused test startup emits pre-existing socialware/skill seed warnings; they are unrelated to this change.
- No push, merge, rebase, deploy, or precommit was run.
