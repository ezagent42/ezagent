# Return: project_cwd default + World UI surface fixes

> **Task:** project-cwd-default-world-ui
> **Branch:** `fix/project-cwd-default-world-ui-0701`
> **PR:** https://github.com/ezagent42/ezagent/pull/1122
> **Dev:** codex
> **returned_at:** 2026-07-01 17:40 +0800
> **deadline:** 2026-07-01 23:59 +0800
> **deadline_status:** on_time

## What Changed

- File-flavor agents (`cc`, `cc-headless`, `codex`, `codex-remote`) now accept an empty `project_cwd` and default it to the per-agent `config_dir`.
- Non-empty custom `project_cwd` values still flow through backend validation and may only live under the agent config dir or `EZAGENT_ALLOWED_CWD_ROOTS`.
- World Create Agent UI now offers a default directory mode plus a custom directory mode driven by backend-provided allowed roots.
- Full-bleed World surfaces now use the viewport height instead of the previous fixed `666px` shell height.

## DoD Reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Product contract is approved: the UI states what the directory is for, where it lives, and the difference between `project_cwd` and `config_dir`. | deferred | No explicit lead approval was recorded in this branch. The implemented V1 is narrower: empty cwd defaults to `config_dir`; custom cwd is allowed only through existing backend roots. |
| 2 | Backend rejects unsafe paths and traversal through tests, not just UI checks. | met | `apps/ezagent_core/test/ezagent/sandbox/config_dir_test.exs` covers defaulting and outside-root errors; existing `validate_project_cwd/2` remains the enforcement point. |
| 3 | Backend can create a project directory under an allowed root, or returns a visible, stable error when roots are not configured. | deferred | Directory creation under roots was not implemented. This return keeps the narrower default-to-config-dir behavior and exposes allowed roots for custom paths. |
| 4 | Create Agent UI no longer requires the operator to guess a raw host path. | met | `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` renders default/custom mode cards and submits `cwd: ""` for default mode. |
| 5 | Invalid input produces a visible error in the form; no silent `data-last-dispatch`-only failure. | met | `Ezagent.World.IdentityData.create_error_message/1` maps `{:cwd_outside_allowed_roots, cwd}` to a visible Chinese error. |
| 6 | E2E proof includes screenshots plus host-side command output showing the resolved directory. | not-met | Browser automation evidence was not captured in this return. Verification used structural frontend tests, build, and focused backend tests. |
| 7 | `mix precommit` and `mix ezagent.check_invariants` pass on the final stack. | not-met | `mix ezagent.check_invariants` passed. `mix precommit` ran and exited `2` because `Ezagent.Integration.HomeMigrationTest` requires missing `pg_dump`. |

**Method friction:** The original 2026-07-01 plan called for a broader product contract (`existing` + `create under allowed root`). The implementation that was available to merge from the sibling worktree was a narrower contract. The return should have had a fresh, branch-specific DoD before coding rather than inheriting the broader clarify-first plan verbatim.

## Verification

- `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs` — passed.
- `env POSTGRES_PORT=5432 mix test apps/ezagent_core/test/ezagent/sandbox/config_dir_test.exs apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs` — passed, 40 tests, 0 failures.
- `mise exec node@22 -- pnpm --dir apps/ezagent_plugin_world/assets build` — passed.
- `git diff --check` — passed.
- `mix ezagent.check_invariants` — passed.
- `env POSTGRES_PORT=5432 mix precommit` — failed with 2 failures in `apps/ezagent_core/test/integration/home_migration_test.exs`, both `{:missing_executable, "pg_dump"}`. Subsequent umbrella apps, including `ezagent_plugin_world`, `ezagent_web`, and `ezagent_cli`, reported 0 failures.

## Merge Request

PR #1122 has been rebased onto `origin/main` and should be reviewed/merged directly into `main`.
