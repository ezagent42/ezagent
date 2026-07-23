# Realtime Refresh Return

> **Task:** realtime-refresh-signals
> **Branch:** `codex/realtime-refresh`
> **PR:** #1497
> **Dev:** Codex
> **returned_at:** 2026-07-23 16:39 +0800
> **deadline:** not recorded (out-of-scope follow-up)
> **deadline_status:** out_of_scope

Base: `origin/main` at `7e3ee6560`

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

## CI gate remediation (2026-07-23)

The PR's previous deterministic gate failed for two reasons introduced by the
realtime-refresh changes:

- the dynamic-receiver architecture contract requires every new dynamic plugin
  call site, and every intentional source-line relocation, to be explicitly
  audited; and
- the four public `RefreshSurfaceRegistry` functions increased undocumented
  public definitions from the cap of 404 to 408.

Commit `a568b3cfd` documents the four public registry functions and extends the
strict dynamic-receiver baseline. The baseline is still exact: the scanner finds
and expects 787 sites, and `mix ezagent.doc.scan` passes at 404/404 undocumented
public definitions. `mix precommit` completed locally before the commit.

The fresh GitHub CI run is [29991473292](https://github.com/ezagent42/ezagent/actions/runs/29991473292).
Its frontend regression job failed before the deterministic backend gate could
run, so that gate is currently **skipped**, not green. This is a separate CI
failure that requires the frontend job's failure to be diagnosed before the
return can be treated as machine-green.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Reconcile the realtime-refresh dynamic-receiver contract. | met | Exact scanner match: 787 audited sites; commit `a568b3cfd`. |
| 2 | Keep public API documentation within the repository cap. | met | `mix ezagent.doc.scan`: 404/404 undocumented public definitions. |
| 3 | Obtain green CI on the PR head. | deferred | CI run 29991473292 failed in the frontend job and skipped the backend gate; lead decision/diagnosis needed. |

**Method friction:** The initial return recorded focused tests but not the
repository-wide dynamic-receiver and documentation fitness functions. Any PR
that adds dynamic plugin dispatch should run those two checks before return.

## #1472 boundary discovered during rebase

Latest `origin/main` already contains the core #1472 page declaration, dynamic
page registry, and generated static plugin-page renderer manifest. It still has
legacy World frontend/session special cases for specific plugins/templates
outside the refresh mechanism. Those must be migrated before a repository-wide
"no plugin names in World" drift gate can be enabled honestly. This PR does not
hide or allowlist those existing cases; it removes plugin/template knowledge from
the new refresh path and records the remaining #1472 migration as separate work.
