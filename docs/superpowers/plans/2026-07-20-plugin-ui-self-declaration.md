# Plugin UI Self-Declaration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make installed plugins the sole declarers of World pages, actions, navigation, session tabs, and statically bundled React renderers.

**Architecture:** `UiSurfaceProvider` owns declaration shape validation and diagnostics. `PluginPageRegistry` is a runtime projection of `Ezagent.PluginRegistry`; `WorldLive` performs generic runtime builder/action lookup. A Mix task converts the same projection into a checked-in static TypeScript renderer map. Kanban and Hello own their data/action/render declarations, while World retains only generic shell code.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, ExUnit, Mix tasks, React/TypeScript, esbuild.

## Global Constraints

- World must not contain `kanban`, `hello`, `KanbanData`, or `KanbanActions` literals after migration; the drift allowlist is empty.
- Declaration and dispatch are fail-closed: malformed, duplicate, unknown, or undeclared inputs are rejected with diagnostics, never admitted by fallback.
- Renderer imports remain static and generated at Mix build time; no iframe, dynamic runtime loader, or Module Federation.
- Preserve plugin-to-World compile independence: plugins expose optional functions and World reads them only through the core plugin registry.
- Run `mix format` on touched files, focused tests, then `mix precommit`.

---

### Task 1: Declare and validate complete UI surfaces

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_test.exs`
- Create: `apps/ezagent_plugin_world/test/ezagent/world/ui_surface_provider_diagnostics_test.exs`

**Interfaces:**
- Produces `pages/0`, `valid_page?/1`, and diagnostics for malformed declarations.
- Page declaration contains `key`, `route`, `detail_route`, `nav`, `data_builder`, `renderer_families`, `actions`, `actions_module`, and renderer import/export metadata.

- [ ] Write focused tests for valid page declarations and each rejected required field, including invalid renderer metadata and duplicate action values.
- [ ] Run the new tests and observe failures caused by missing strict validation/diagnostic API.
- [ ] Implement the minimal shape checks and read-time diagnostic representation; do not rescue malformed declarations into admission.
- [ ] Re-run the focused tests until green.

### Task 2: Make registry runtime, deterministic, and fail-closed

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex`
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/plugin_page_registry_test.exs`

**Interfaces:**
- Consumes `UiSurfaceProvider` validation and `Ezagent.PluginRegistry.list_all/0`.
- Produces `pages/0`, `by_key/1`, `by_route/1`, `by_action/1`, `diagnostics/0`.

- [ ] Write tests that installed plugin declarations supply page/action/nav/tab data, malformed and duplicate declarations produce diagnostics and no page, and undeclared actions return `nil`.
- [ ] Run the registry test file and observe the required failures.
- [ ] Replace all World page/action constants with sorted plugin-registry enumeration; reject duplicate key, route, renderer family, and action ownership rather than choosing a winner.
- [ ] Re-run the registry tests until green.

### Task 3: Route World pages and dispatch generically

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- Modify: `apps/ezagent_plugin_world/test/ezagent_plugin_world/world_live_test.exs` or the nearest existing route/dispatch test

**Interfaces:**
- Consumes `PluginPageRegistry.by_key/1` and `by_action/1`.
- Calls a declared builder through `state_for/2` and action module through `handle_dispatch/3` only after admission.

- [ ] Write failing tests for a declared page state route and rejection of an undeclared action.
- [ ] Run the focused tests and observe that compile-time generated clauses cannot serve runtime declarations.
- [ ] Replace the compile-time `for` clauses with one generic page-state branch and retain the unsupported-action error path.
- [ ] Re-run focused tests until green.

### Task 4: Generate and consume static renderer manifest

**Files:**
- Create: `apps/ezagent_plugin_world/lib/mix/tasks/world.renderers.manifest.ex`
- Create: `apps/ezagent_plugin_world/assets/src/generated/plugin-page-renderers.tsx`
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`
- Create: `apps/ezagent_plugin_world/test/mix/tasks/world_renderers_manifest_test.exs`

**Interfaces:**
- `mix world.renderers.manifest [--check]` writes a deterministic TypeScript module from `PluginPageRegistry.pages/0`.
- React imports only `pluginPageRenderers` and throws for an unknown declared renderer key.

- [ ] Write Mix-task tests that generated imports/map match the page declarations and `--check` identifies stale output.
- [ ] Run the tests and observe the task/module is missing.
- [ ] Implement deterministic generation using static import paths and update `main.tsx` to consume the generated map instead of plugin-specific imports/maps/family branches.
- [ ] Generate the checked-in module and re-run tests and TypeScript checks until green.

### Task 5: Move Kanban and Hello ownership into plugins

**Files:**
- Move: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex` → `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_data.ex`
- Move: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex` → `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_actions.ex`
- Move: relevant Kanban and Hello React components out of `apps/ezagent_plugin_world/assets/src/components/` into their owning plugin asset trees
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex`
- Modify: plugin Mix asset build configuration and affected plugin tests

**Interfaces:**
- Kanban and Hello application modules export their own valid surfaces and renderer paths.
- World only resolves declarations and does not reference plugin modules/components by name.

- [ ] Write migration tests that assert each plugin owns its declaration and all declared handlers/builders resolve.
- [ ] Run tests and observe World-owned references still exist.
- [ ] Move implementation and renderer assets, update declarations and static import paths, and remove Hello session-type sniffing.
- [ ] Re-run focused World, Kanban, Hello, and frontend tests until green.

### Task 6: Enforce zero plugin-name drift

**Files:**
- Create: `apps/ezagent_plugin_world/test/architecture/world_plugin_name_drift_test.exs`
- Modify: affected existing slot/manifest gate tests

**Interfaces:**
- Drift test scans World source with an empty allowlist and fails with paths/lines for plugin-specific literals.

- [ ] Write a failing drift-gate test using an injected forbidden literal fixture and an empty production allowlist.
- [ ] Run it to observe the forbidden World references.
- [ ] Remove the remaining references and preserve only generic protocol names in World.
- [ ] Run the gate until green, then run `mix world.renderers.manifest --check`, focused suites, and `mix precommit`.
