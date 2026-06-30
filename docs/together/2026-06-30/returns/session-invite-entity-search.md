# Return: Session Invite Entity Search

> **Date:** 2026-06-30 09:49 CST · **From:** codex · **To:** lead
> **Tracking:** AM-2 · **Branch:** `feat/session-invite-entity-search-0630`
> **Status:** ready-for-review

## Summary

Implemented the conversation member invite picker and server-side entity search
for session invites.

## Changes

- Added `ConversationData.search_invitable_entities/4`.
- Added `world:entity_search` LiveView reply event.
- Revalidated `session.invite` submitted member URIs with
  `Ezagent.UI.UriOptions.valid_for?/4` before demand-spawn and join dispatch.
- Replaced the members panel raw URI-only invite form with a searchable entity
  picker in `Conversation.tsx`.
- Kept exact URI paste as a fallback; submit still flows through
  `session.invite`.

## Definition of Done

- [x] Invite form offers a searchable entity chooser instead of only a raw URI
      textbox.
- [x] Search includes registered users in the current workspace, including cold
      users.
- [x] Search includes live agents in the current workspace.
- [x] Existing session members are visibly disabled in the result list.
- [x] Final submit uses the existing `session.invite` dispatch.
- [x] Cross-workspace tampering is rejected server-side as
      `error:invalid_member_uri`.
- [x] Malformed URI handling remains covered by the existing invite test.
- [x] Tests cover cold registered users, live agents, search scoping, duplicate
      member marking, hook acceptance, and tampered submit rejection.

## Verification

Browser evidence:
`docs/together/2026-06-30/tests/session-invite-entity-search/browser-verification/`

```bash
MIX_ENV=test POSTGRES_PORT=5432 mix format --check-formatted apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex apps/ezagent_plugin_world/lib/ezagent/world/entity_search_actions.ex apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs --trace
npm run build
npm run check:mounts
node --test test/world_navigation_test.mjs
MIX_ENV=test POSTGRES_PORT=5432 mix ezagent.arch.scan
MIX_ENV=test POSTGRES_PORT=5432 mix ezagent.check_invariants
```

All commands above passed locally.

`pnpm run build` and `pnpm run check:mounts` were attempted first, but the local
global pnpm requires Node.js v22.13+ and this machine is on Node.js v20.19.4
(`ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite`). The same project scripts passed via
`npm`.

Current branch browser re-verification added:

- `07-current-invite-picker-e2e-test-result.png` — typeahead search for
  `entity://system/agent/e2e-test` returns a selectable result.
- `08-current-invite-after-e2e-test-submit.png` — submitting that result adds
  `e2e-test` to the session member list.
- `09-current-invite-existing-member-disabled.png` — searching `e2e-test` again
  shows the row disabled with `Already in session`.

Full local precommit was run after the focused checks:

```bash
MIX_ENV=test POSTGRES_PORT=5432 mix precommit
```

It exited 2 with three unrelated local-environment/long-running failures while
the affected world/web suites passed:

- `Ezagent.Integration.HomeMigrationTest` had 2 failures because local
  `pg_dump` is missing (`{:missing_executable, "pg_dump"}`).
- `Ezagent.PluginPy.NpRoleTest` had 1 real-subprocess timeout creating an
  `np` py-agent through `workspace.create_agent` after 5000ms.
- `ezagent_plugin_world` passed 95 tests, and `ezagent_web` passed 273 tests.

## Notes

- The search API is a LiveView reply surface, not a new HTTP controller.
- Search result validation and submit validation both derive caller/workspace
  from socket assigns; the client does not provide authority context.
- AM-1 user onboarding remains a separate clarify-first task.
