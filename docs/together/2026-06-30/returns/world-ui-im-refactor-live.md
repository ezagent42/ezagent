# Return: World UI IM Refactor Live

> **Task:** world-ui-im-refactor-live
> **Branch:** `docs/world-ui-redesign-prototype-0630` (worktree branch: `feat/world-ui-im-refactor-0630`)
> **PR:** https://github.com/ezagent42/ezagent/pull/1104
> **Dev:** Codex
> **returned_at:** 2026-06-30 20:03 +0800
> **deadline:** none for this production follow-up; original T3 demo deadline was 2026-06-30 17:00 +0800
> **deadline_status:** out_of_scope

## Summary

Extended the T3 IM-like World UI prototype into the production World shell on PR
#1104. The live app now defaults to Chat, uses the Chat / Agents / Manage primary
IA, moves Profile / My capabilities / Dark mode / Sign out into the account
menu, and renders conversation, agents, plugin, and admin surfaces in the same
IM-oriented frame that the prototype established.

This return is intentionally separate from `t3-ui-im-demo.md`: that earlier
return covered the docs-only prototype handoff. This one records the later
production implementation and its gate status.

## Artifacts

- PR: https://github.com/ezagent42/ezagent/pull/1104
- Implementation commits:
  - `b3484ba0` - `feat(world): align live UI with IM prototype`
  - `8cb04892` - `fix(workspace): honor create-agent dispatch deadlines`
- Plan and audit:
  - `docs/superpowers/plans/2026-06-30-world-ui-im-refactor.md`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/AUDIT.md`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/SMOKE_TEST_RESULTS.md`
- Browser evidence:
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/22-chat-default.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/23-workspace-menu.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/24-account-menu.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/25-conversation.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/26-agents.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/27-agent-new.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/28-plugins.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/29-admin.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/30-mobile-chat.png`
  - `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/31-mobile-agents.png`

## DoD reconciliation

| # | DoD line | status | proof / open decision |
| --- | --- | --- | --- |
| 1 | Add a pure World shell IA contract so the production shell exposes Chat / Agents / Manage consistently. | met | `apps/ezagent_plugin_world/assets/js/world_ia.js`; `node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs` passed. |
| 2 | Make Chat the default World route and preserve Phoenix host routing. | met | `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`; `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`; `POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`. |
| 3 | Move user-only actions into the account menu and keep workspace switching explicit. | met | Browser evidence `23-workspace-menu.png` and `24-account-menu.png`; `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs` passed. |
| 4 | Render Chat as an IM-style experience with session rail, conversation body, and member/context rail. | met | Browser evidence `22-chat-default.png`, `25-conversation.png`, and `30-mobile-chat.png`; `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs` passed. |
| 5 | Update Agents to use a directory/detail frame with expected create-agent fields and tabs. | met | Browser evidence `26-agents.png` and `27-agent-new.png`; structure test asserts flavor options, dynamic config fields, and Agents tabs. |
| 6 | Update Manage plugin/admin surfaces and make route gaps visible instead of silently broken. | met | Browser evidence `28-plugins.png` and `29-admin.png`; structure test asserts plugin cards, Knowledge Base route gap state, config-surface table, and admin subnav. |
| 7 | Verify mobile layouts do not overlap the topbar/title. | met | Browser evidence `30-mobile-chat.png` and `31-mobile-agents.png`; audit recorded `overlap=false` for Chat and Agents. |
| 8 | Use the host PostgreSQL service for DB gates and do not start Docker for test setup. | met | Audit records host PostgreSQL on `127.0.0.1:5432`, no Docker, and temp `pg_dump` / `pg_restore` wrappers through `/tmp/ezagent-pgtools`. |
| 9 | Run local verification through `mix precommit`. | met locally | `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix precommit` passed locally; targeted post-commit checks also passed. |
| 10 | Return only when PR machine gate is green and branch is rebased on current `main`. | not-met | GitHub `precommit + check_invariants` failed on PR head `8cb04892`: https://github.com/ezagent42/ezagent/actions/runs/28442314951/job/84283002988. Current `origin/main` observed as `d8ffd6c09d016fc52e71eb6aa5bba5c363d7fe6b`; branch merge-base was `23320282478194263e207ed305660a551219cc80`, so the PR branch was not rebased onto current main at return time. |

## Gate Status

Local verification passed before this return:

- `git diff --check`
- `mix compile`
- `npm run build` from `apps/ezagent_plugin_world/assets`
- `node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs`
- `node apps/ezagent_plugin_world/assets/test/world_ia_test.mjs`
- `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- `POSTGRES_PORT=5432 mix test apps/ezagent_core/test/e2e`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix test apps/ezagent_core/test/integration/home_migration_test.exs`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix test apps/ezagent_plugin_py/test/np_role_test.exs apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs`
- `PATH="/tmp/ezagent-pgtools:$PATH" POSTGRES_PORT=5432 mix precommit`

GitHub PR checks at return time:

- `precommit + check_invariants`: failed on head `8cb04892`
  - URL: https://github.com/ezagent42/ezagent/actions/runs/28442314951/job/84283002988
  - Observed signature: CI created and migrated the test DB, umbrella tests completed with no test failures in the logged apps, then the job exited with code 2 after `tput: No value for $TERM and no -T specified`.
- `Return file advisory`: passing
- `Only repo owner may edit dev-together skill`: passing

Branch state at return time:

- PR head: `8cb04892d3fd2eb75315ca1d2403db3a1ca74cdc`
- Current `origin/main` observed locally: `d8ffd6c09d016fc52e71eb6aa5bba5c363d7fe6b`
- Merge base with `origin/main`: `23320282478194263e207ed305660a551219cc80`
- PR branch was mergeable but not rebased onto current `origin/main`.

This is not a valid green dev-together return until CI is green on the PR head
and the branch is rebased onto current `main`.

## Deferred Follow-ups / Open Decisions

- Lead should decide whether PR #1104 should remain the vehicle for the
  production UI implementation or whether the live refactor should be split from
  the original docs-only T3 prototype PR.
- Lead should decide whether the CI failure is a rerun-only environment issue
  around `tput` / missing `TERM`, or whether the precommit/check workflow should
  be patched to set `TERM` or avoid terminal-dependent output in CI.
- Knowledge Base plugin config still has a visible route gap. The UI now exposes
  the gap instead of hiding it; a separate task should either implement the route
  or remove/change the declared config surface.

## Method Friction

The original T3 handoff was a demo/prototype task. The production refactor grew
from the user request to continue unfinished work, so the live implementation did
not have its own daily handoff, deadline, or closed DoD before coding began. That
made the return accounting ambiguous and caused PR #1104 to shift from a
docs-only design artifact into an implementation PR.

The local DB gate was also initially misclassified as blocked because the project
default `POSTGRES_PORT=55432` was closed. The usable service was the host
PostgreSQL on `127.0.0.1:5432`, with Windows `pg_dump.exe` / `pg_restore.exe`
available through wrappers. Future handoffs that require DB gates should include
the environment discovery result before treating DB verification as blocked.

One dev-only runtime failure, `EzagentPluginWorld.WorldLive.__live__/0 is
undefined`, came from zero-byte dev BEAM artifacts and was fixed by cleaning the
dev build output. No source code change was needed for that symptom.

## Merge Request

Review PR #1104 as a production World UI implementation plus one load-sensitive
workspace dispatch timeout fix, not as a docs-only prototype. Do not merge until
the PR is rebased onto current `main` and `precommit + check_invariants` is green
on the PR head, or until the lead explicitly records a different close decision
for the CI `tput` failure.

Lead message:

> Returned `world-ui-im-refactor-live` on PR #1104. Local verification, browser
> audit, and host PostgreSQL `mix precommit` passed without Docker, but this is
> not a green dev-together return: GitHub `precommit + check_invariants` failed
> on head `8cb04892`, and the branch is not rebased onto current `origin/main`.
> Please decide whether to keep the production implementation in #1104 or split
> it from the original T3 docs-only prototype, then rerun/fix CI before merge.
