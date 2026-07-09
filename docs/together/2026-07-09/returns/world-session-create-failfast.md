# Return — world session create fail-fast + loading

> **Task:** world-session-create-failfast
> **Branch:** `fix/world-template-ux-1270-1273`
> **PR:** #1276
> **Dev:** claude
> **returned_at:** 2026-07-09 17:15 +0800
> **deadline:** 2026-07-09 23:59 +0800
> **deadline_status:** deferred

## What is done

- cc flavor now probes the installed `claude` before spawning and returns a clear `unsupported_claude_dev_channels` error when the binary does not advertise `--dangerously-load-development-channels`.
- `create_session` now carries an explicit `deadline_ms: 60000` through workspace dispatch so the server-side wait matches the user-facing flow.
- World UI now sets `session_create_pending` immediately on create, keeps the form busy, disables duplicate submits, and shows a loading state until the server responds.
- The session-create error message now maps the unsupported Claude dev-channel case to a concise operator-facing Chinese message instead of surfacing the low-level timeout chain.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | cc flavor fails fast when installed Claude Code does not support the cc bridge dev-channel flag | met | [spawn_plan.ex](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex:61) + [cc_agent_spawn_invariant_test.exs](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_spawn_invariant_test.exs:266); `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_spawn_invariant_test.exs` |
| 2 | session creation uses an explicit longer deadline and the UI shows loading/blocks duplicate submits | met | [workspace.ex](/home/lenovo/workspace/ezagent/apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:826) + [conversation_actions.ex](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:25) + [main.tsx](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/assets/src/main.tsx:153) + [Conversation.tsx](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:568) + [SessionsTable.tsx](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/assets/src/components/SessionsTable.tsx:173); `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`, `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`, `npm --prefix apps/ezagent_plugin_world/assets run build` |
| 3 | machine gate: CI green on PR head and rebased onto current main | deferred | Rebased onto `origin/main` at `63877f42`; GitHub Actions on PR #1276 are queued, not green yet. Run: `https://github.com/ezagent42/ezagent/actions/runs/29007398490` |

**Method friction:** the cc flavor assumption was too optimistic for this environment: the installed Claude Code advertises no development-channel support, so the real fix is fail-fast with a clear operator error rather than waiting for the session path to time out. The return gate also needed a rebase onto the current `main` before it could be treated as a valid handoff.

## Merge request

PR #1276, branch `fix/world-template-ux-1270-1273`, rebased onto `origin/main` (`63877f42`). The branch is ready for CI to settle; the remaining follow-up is to watch the queued checks and decide whether to merge or defer.
