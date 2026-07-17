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

## Secret-scanner follow-up

The original regex scanner under-counted parenthesized migration calls. This follow-up replaces it with `Code.string_to_quoted!/1` plus AST traversal of actual local `field` and `add` call nodes, including nested module/block forms while excluding comments and string contents.

- Explicit schema files scanned: 1 task-workspace provision schema.
- Explicit migration files scanned: 4 (`17001000`, `17002000`, `17003000`, `17004000`).
- Actual schema field calls: 30.
- Actual migration add calls: 30 (correcting the earlier regex-derived count of 5).
- Supported and mutation-tested forms: `field(:name, ...)`, `field :name, ...`, `add(:name, ...)`, and `add :name, ...`.
- Mutation coverage proves `credential_ref` is rejected in all four forms, exact lifecycle names are allowed, `claim_token_credential_ref` is still rejected, and deceptive comment/string contents are not treated as calls.
- RED: boundary test compilation failed because the AST extractor/classifier did not exist.
- GREEN: boundary 11 tests, focused Task 8 16 tests, and complete hardening suite 108 tests; all had 0 failures.
