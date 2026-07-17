# Task 8 report

Baseline: `6a3100d7ff574b386d4ffc5294d16ff13295e95b`

## RED evidence

- Focused structural/E2E run: 12 tests, 2 failures.
- Failures were the intended core-template vocabulary violation (`flavor_hook.ex`) and signed fixture returning `fresh?: false`.
- After correcting the exact-file scan helper, the boundary-only run showed both intended structural failures: core vocabulary and the `PreStart` application-env runner seam.

## Structural gates

- Production `pre_start_ref:` callers: exactly 1, allowlisted only as `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex`.
- Production `AgentStart.start(` callers: exactly 0.
- Core template forbidden-vocabulary offenders: 0.
- `PreStart` configurable-runner-seam offenders: 0.
- Parsed durable schema fields: 30.
- Parsed task-workspace migration `add` tokens: 5.
- Forbidden secret-field offenders after exact lifecycle-name handling: 0.
- Exact lifecycle names handled: `claim_token`, `start_token`, `start_claim_token`, `start_token_consumed_at`, `cleanup_reason`, `cleaned_at`.

## Signed fresh E2E

- Template Class returns `fresh?: true` and performs no lineage, inventory, workspace, or flavor-helper writes.
- `TemplateSpawn` owns workspace binding, lineage, and creation inventory.
- E2E asserts creation attempt, exact owner lineage, and durable `:sidecar_started` before cleanup.
- Cleanup asserts sanctioned retirement, exact Git/filesystem worktree absence, and terminal `:cleaned`.
- Existing commit, branch, and dirty-tree real-mutation cases remain in the signed E2E.

## GREEN evidence

- Focused structural/E2E/dependency run: 14 tests, 0 failures.
- Exact complete hardening suite from the brief: 106 tests, 0 failures.
- Renamed generic core attribute-hook suite: 7 tests, 0 failures.
- `git diff --check`: clean.

No push, merge, rebase, deploy, or `mix precommit` was run. The unrelated handoff file was preserved and excluded from the commit.
