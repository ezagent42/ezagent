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

## Review follow-up

### AgentStart mutation RED/GREEN

- Added a real-Git integration test in `task_workspace_signed_e2e_test.exs`. Each of `:other_commit`, `:other_branch`, and `:dirty_file` starts from its own genuinely provisioned ready row, mutates the worktree, calls actual `AgentStart.start/5`, asserts the exact mismatch/dirty error, observes no instantiate message, and proves the row is `:cleanup_pending`.
- Because the gate already existed when the missing integration test was added, RED used a temporary cleanliness mutation in `GitRunner.verify/1`. Command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs`. Result: 3 tests, 1 failure; the dirty worktree returned `{:ok, ...}` and reached instantiate. The mutation was then removed.
- Final focused GREEN command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`. Result: 37 tests, 0 failures.
- The signed E2E setup now explicitly installs and removes the Workspace pre-start implementation, eliminating suite-order dependence exposed by the full-suite run.

### Migration consolidation and roundtrip

- Read `mix help ecto.rollback` and `mix help ecto.migrate`; confirmed `--to` is inclusive for rollback and migrate.
- Rolled back the applied extra migration before deleting it: `MIX_ENV=test mix ecto.rollback --to 20260717005000` — exit 0, 05000 backward migration removed `remote_url`.
- Merged nullable `remote_url` add/remove into `20260717004000_harden_git_task_workspace_start.exs`. No changes were made to 01000, 02000, or 03000; 05000 no longer exists on disk.
- Rolled the local test DB back through 04000 and reapplied 04000 only. After consolidation, verified the final file in both directions with `MIX_ENV=test mix ecto.rollback --to 20260717004000 && MIX_ENV=test mix ecto.migrate --to 20260717004000` — exit 0; final `down` removed all five start-proof columns and final `up` restored them and the recovery index/constraint safely.

### Final verification and files

- Full Workspace command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test` — 296 tests, 0 failures.
- Formatting completed for the changed migration and integration test; `git diff --check` is clean.
- Follow-up files: modified `20260717004000_harden_git_task_workspace_start.exs`, deleted `20260717005000_add_remote_proof_to_git_task_workspace_provisions.exs`, modified `task_workspace_signed_e2e_test.exs`, and this report.

### Follow-up self-review

- Exactly one Plan C forward migration remains: 04000. Its `up` adds nullable `remote_url`; its `down` removes it after dropping the dependent recovery index and restoring the pre-start status constraint.
- The integration test uses actual provisioning, actual Git mutations, actual `AgentStart`, and the real production proof runner; only sidecar instantiate remains the established probe boundary.
- The unrelated handoff remains untouched and untracked.

## Singleton isolation follow-up

- `task_workspace_signed_e2e_test.exs` now snapshots `CorePreStart` with its registry `:implementation` call before installing Workspace `PreStart`.
- `on_exit` restores the exact captured module with `replace_for_test/1`; it restores `nil` only when the captured result was `{:error, :template_pre_start_not_registered}`. It no longer blindly clears a prior registration.
- A separate isolation test was not added because `CorePreStart` exposes no public implementation getter; the setup uses the same internal registry query that production `prepare/1` uses, and full-suite order independence is the behavioral assertion.
- Signed E2E command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs` — 3 tests, 0 failures.
- Three-file focused command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs` — 37 tests, 0 failures.
- Full Workspace command: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test` — 296 tests, 0 failures.
- `mix format` completed for the integration test; final `git diff --check` is clean.
