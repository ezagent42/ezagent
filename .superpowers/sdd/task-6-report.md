# Task 6 report — exact Git proof before sidecar instantiate

## RED

- Added real-Git mutation coverage for commit drift, branch drift, origin drift, and an untracked dirty file.
- Added a complete-proof requirement and a pre-start ordering assertion that observes the row in `:starting` with the issued claim token from inside the proof runner.
- Focused RED command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`
- Observed 7 failures, including mutation verification returning `:ok`, incomplete proof reaching Git, the old generic `:workspace_not_ready` result, and the opaque completion claim hiding the Workspace token. This also exposed that `PreStart` returned `start_token` rather than `start_claim_token`.

## GREEN

- `GitRunner.verify/1` now requires cache/worktree/remote/commit/branch and checks exact origin, NUL porcelain registration, HEAD, `symbolic-ref -q HEAD`, and status including untracked files.
- Checkout mismatch is `:workspace_checkout_mismatch`; non-empty status is `:workspace_not_clean`.
- `PreStart.prepare/1` claims `:starting` first with a bounded lease, verifies proof loaded from that row, and returns `{row_id, start_claim_token}`. Proof failure calls `Store.fail_start/4` with that token; a lost claim returns `:sidecar_start_claim_lost` without a fallback cleanup transition.
- Runner selection is compile-time test-only; production resolves directly to `GitRunner`.
- Persisted governed `remote_url` as non-secret proof. Without durable expected origin, checking `remote get-url origin` would be tautological after mutation.
- Preserved argv-only execution, anonymous credential hardening, bounded commands, canonical worktree parsing, and provision duration accounting. Start lease is the bounded Git duration plus 10 seconds safety.

## Verification

- Focused exact-proof plus signed E2E: 36 tests, 0 failures.
- Full Workspace suite: 295 tests, 0 failures.
- `mix format` completed for all touched Elixir files.
- `git diff --check`: clean.
- Existing suite warnings remained (test behavior callback warnings, socialware/skill seed notices, intentional recovery warnings, and asynchronous sandbox disconnect logs); no test failures.

## Self-review

- Exact proof comes from the durable starting row, not authored content or the opaque ref.
- Origin proof required a small schema/migration extension beyond the brief's initial file list; it stores only an anonymous URL, never credentials.
- The unrelated handoff file remains untracked and unstaged.
