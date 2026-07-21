# Realtime Refresh Signals Return

Date: 2026-07-21
Branch: `codex/realtime-refresh`
Base: `origin/main` at `fe2906431`
Handoff: `docs/together/2026-07-21/handoffs/realtime-refresh-signals.md` (PR #1496)

## Summary

Implemented the World-side consumer contract for the two generic session-event
signals proposed in the handoff:

- `{:view_changed, %{plugin: key, entity_uri: uri}}` resolves the declared
  plugin page, invokes its data builder's `refresh_state/2` callback with the
  current caller-scoped context, and pushes the returned partial
  `world:state` to React.
- `{:caps_changed, entity_uri}` reloads `EntityCaps` only when the event is for
  the currently signed-in entity, rebuilds the current route state, and pushes
  the refreshed state so permission affordances update without a browser
  reload.

`WorldLive` now retains the current route needed for the capability-triggered
rebuild. Unknown plugin keys are ignored. A registered page with a missing or
invalid `refresh_state/2` declaration fails explicitly rather than silently
allowing a broken real-time surface.

Kanban's page data builder implements `refresh_state/2` as its plugin-owned
partial board-state projection. The registry test makes this callback part of
the page declaration contract.

## Boundary Notes

The target `origin/main` did not contain the handoff's historical
`{:kanban_changed, ...}` handler; it exists on the separate Kanban migration
line. Consequently this change adds the generic World consumer without
introducing or preserving a Kanban-specific handler. The Kanban producer-side
migration still needs to broadcast `:view_changed` after successful writes and
`:caps_changed` after approval changes, as assigned in the handoff.

## Tests Added

- `plugin_page_refresh_test.exs` covers a valid plugin-owned callback, a
  missing callback fail-closed result, and an unknown page.
- `plugin_page_registry_test.exs` verifies every registered page data builder
  is loadable and exports `refresh_state/2`.

## Verification

- Touched Elixir files formatted and syntax-checked.
- `git diff --check` PASS.
- `POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/plugin_page_refresh_test.exs apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs` PASS (`15 tests, 0 failures`).
- `mix precommit` was started after PostgreSQL recovery but the local command
  runner terminated it at its 64-second execution limit before completion; it
  did not report a code, compile, or database failure before that limit.