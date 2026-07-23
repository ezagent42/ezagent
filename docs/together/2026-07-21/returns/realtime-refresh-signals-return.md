# Realtime Refresh Return

Date: 2026-07-23
Branch: `codex/realtime-refresh`
Base: `origin/main` at `ac32cfe51`

## Delivered

World now treats post-commit `Ezagent.SliceChange` as the only refresh transport.
The generic refresh mechanism is declaration-driven:

- `UiSurfaceProvider.refresh_surfaces/0` declares a renderer component, the URI
  source it observes, and its caller-scoped `refresh_state/2` builder.
- `RefreshSurfaceRegistry` dynamically combines those declarations with
  registered plugin pages. Invalid standalone declarations are fail-closed.
- `WorldLive` subscribes by the declared URI source, deduplicates a pending
  `{surface, uri}` refresh, and defers the state projection by 25 ms. This lets
  low-latency events such as `chat:message` reach the browser before a persisted
  state read can occupy the LiveView mailbox.
- React receives a generic `world:surface_state` envelope and shallow-merges its
  partial state. It has no refresh branch for a particular plugin or template.
- Session creation keeps route navigation as the only source of selected-session state. It emits the generic `world:session_created` completion acknowledgement solely to clear “creating…” immediately; the subsequent `handle_params` route state selects and renders the new session. This applies uniformly to every template/socialware and prevents a stale client state from overriding the route.
- The World conversation renderer declares itself through the same registry.
  `ConversationSessionState.refresh_state/2` supplies its caller-authorized
  projection. The old direct session route rebuild and the old page-only
  `PluginPageRefresh` mechanism are removed.

Identity SliceChanges still reload caps only through `PresenterCaps`, then
rebuild the active route; no mount-snapshot caps are reused.

## Verification

- `ERL_FLAGS='+S 8:8' MIX_ENV=test mix compile` — PASS.
- `ERL_FLAGS='+S 8:8' mix test ...refresh_surface_registry_test.exs
  ...world_slice_change_refresh_gate_test.exs ...plugin_page_registry_test.exs`
  — PASS, 21 tests / 0 failures.
- Touched Elixir files were formatted and `git diff --check` passed.

The WSL worktree has no `pnpm` executable, so the React TypeScript check was not
run here. This is an environment limitation, not a type-check failure.

## #1472 boundary discovered during rebase

Latest `origin/main` already contains the core #1472 page declaration, dynamic
page registry, and generated static plugin-page renderer manifest. It still has
legacy World frontend/session special cases for specific plugins/templates
outside the refresh mechanism. Those must be migrated before a repository-wide
"no plugin names in World" drift gate can be enabled honestly. This PR does not
hide or allowlist those existing cases; it removes plugin/template knowledge from
the new refresh path and records the remaining #1472 migration as separate work.