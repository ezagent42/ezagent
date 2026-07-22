# Realtime Refresh Signals Return

Date: 2026-07-21
Branch: `codex/realtime-refresh`
Base: `origin/main` at `fe2906431`
Handoff: `docs/together/2026-07-21/handoffs/realtime-refresh-signals.md` (PR #1496)

## Summary

Implemented the World-side consumer contract for the two generic session-event
> The custom-signal description retained below is historical. The active implementation is the SliceChange transport documented in the 2026-07-22 section.

signals proposed in the handoff:

- `{:view_changed, %{plugin: key, entity_uri: uri}}` resolves the declared
  plugin page, invokes its data builder's `refresh_state/2` callback with the
  current caller-scoped context, and pushes the returned partial
  `world:state` to React.
- `{:caps_changed, entity_uri}` reloads the current caller capabilities through
  `PresenterCaps` only when the event is for the currently signed-in entity,
  rebuilds the current route state, and pushes the refreshed state so permission
  affordances update without a browser reload.

`WorldLive` now retains the current route needed for the capability-triggered
rebuild. Unknown plugin keys are ignored. A registered page with a missing or
invalid `refresh_state/2` declaration fails explicitly rather than silently
allowing a broken real-time surface.

Kanban's page data builder implements `refresh_state/2` as its plugin-owned
partial board-state projection. The registry test makes this callback part of
the page declaration contract.

## Boundary Notes
## 2026-07-22 SliceChange Transport

This supersedes the custom signal transport described above. World now uses
only post-commit `Ezagent.SliceChange`: the active registered plugin detail
route subscribes to its entity URI, and its caller-scoped `refresh_state/2`
projection is rebuilt when that entity changes. A current user's `:identity`
slice change reloads `PresenterCaps` and rebuilds the current route.

Kanban and future plugins do not broadcast `view_changed`, `caps_changed`, or
plugin-specific refresh messages. SliceChange is content-free; data builders

The target `origin/main` did not contain the handoff's historical
`{:kanban_changed, ...}` handler; it exists on the separate Kanban migration
line. Consequently this change introduces no Kanban-specific handler or
producer broadcast. Kanban writes and Identity cap grants already emit
post-commit SliceChange events; World routes them by the active plugin entity

## Tests Added

- `plugin_page_refresh_test.exs` covers a valid plugin-owned callback, a
  missing callback fail-closed result, and an unknown page.
- `plugin_page_registry_test.exs` verifies every registered page data builder
  is loadable and exports `refresh_state/2`.

## 2026-07-22 Rebase and CI Repair

- Rebased the branch onto `origin/main` at `cce24e97b`; it is no longer behind
  main.
- Removed the rebase-introduced direct `EntityCaps.load/1` / mount-snapshot cap
  reads from `WorldLive`; refresh now uses the project-wide `PresenterCaps`
  source, satisfying the caps-dispatch invariant.
- Added the missing public-function documentation for
  `PluginPageRefresh.build_state/3`, returning the documentation coverage count
  to its checked-in cap (`404`).
- Verified that the PR diff contains no `.claude/skills/dev-together/` path and
  no common token/private-key signatures. The prior owner-only and gitleaks CI
  failures stopped during checkout, before their checks executed; they must be
  rerun from the new commit on GitHub.


## Verification

- Touched Elixir files formatted and syntax-checked.
- `git diff --check` PASS.
- `POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/plugin_page_refresh_test.exs apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs` PASS (`15 tests, 0 failures`).
- `mix precommit` was started after PostgreSQL recovery but the local command
  runner terminated it at its 64-second execution limit before completion; it
  did not report a code, compile, or database failure before that limit.