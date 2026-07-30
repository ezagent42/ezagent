# Remove World Layout Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox ('- [ ]') syntax for tracking.

**Goal:** Remove World’s configurable layout editor and make every World route render only its fixed single-surface layout.

**Architecture:** 'LiveStateBuilder.layout_for_route/3' remains the sole layout builder and constructs a one-component layout from the resolved route. 'WorldLive' bootstraps after route resolution with that same layout. The layout behavior, FS resource type, capability grant, renderer, and dispatch event are deleted rather than feature-flagged.

**Tech Stack:** Elixir/Phoenix LiveView, React/TypeScript, ExUnit, pnpm.

## Global Constraints

- Do not read, migrate, or support persisted 'world-layouts' files.
- Do not add dependencies.
- All World routes use one component; Chat uses 'sessions_table'.
- Follow test-first red/green cycles, and preserve the existing Phoenix layout wrapper.

---

### Task 1: Lock down fixed route layouts at bootstrap

**Files:**
- Modify: 'apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs'
- Modify: 'apps/ezagent_plugin_world/lib/ezagent/world/live_state_builder.ex'
- Modify: 'apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex'

**Interfaces:**
- Consumes route maps with 'component' and 'title'.
- Produces a one-component JSON layout from 'LiveStateBuilder.layout_for_route/3'; no 'can_manage_layout' field.

- [ ] **Step 1: Write the failing Chat bootstrap regression**

  Add this assertion to the existing Chat root routing test:

  ~~~elixir
  state = world_state(html)
  assert [component] = state["layout"]["components"]
  assert component["type"] == "sessions_table"
  refute Map.has_key?(state, "can_manage_layout")
  refute html =~ "layout_editor"
  ~~~

- [ ] **Step 2: Verify RED**

  Run 'mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs:55'.

  Expected: it fails because the current bootstrap fallback contains 'layout_editor' or emits 'can_manage_layout'.

- [ ] **Step 3: Implement the fixed bootstrap**

  Remove 'bootstrap_layout/1'. Once 'handle_params/3' resolves a route, build its initial state using the existing fixed route-layout map:

  ~~~elixir
  %{
    "version" => 1,
    "scope" => URI.to_string(scope_uri),
    "components" => [
      %{
        "id" => component,
        "type" => component,
        "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 8},
        "props" => %{"title" => title}
      }
    ]
  }
  ~~~

  Remove 'LayoutManager.validate_layout/2' from the builder and delete 'put_can_manage_layout/3', 'can_manage_layout?/3', and their state fields.

- [ ] **Step 4: Verify GREEN**

  Run 'mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs'.

  Expected: all routing tests pass after removing obsolete layout-management helpers/assertions.

- [ ] **Step 5: Commit**

  Run 'git add apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs apps/ezagent_plugin_world/lib/ezagent/world/live_state_builder.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex && git commit -m "refactor(world): use fixed route layouts"'.

### Task 2: Remove server layout management and persistence

**Files:**
- Delete: 'apps/ezagent_plugin_world/lib/ezagent/world/layout_manager.ex'
- Delete: 'apps/ezagent_plugin_world/lib/ezagent/world/behavior/layout.ex'
- Delete: 'apps/ezagent_plugin_world/lib/ezagent/world/layout_bootstrap.ex'
- Delete: 'apps/ezagent_core/lib/mix/tasks/ezagent.world.migrate_layouts.ex'
- Delete: 'apps/ezagent_plugin_world/test/ezagent/world/layout_manager_test.exs'
- Delete: 'apps/ezagent_plugin_world/test/ezagent/world/migrate_layouts_test.exs'
- Delete: 'apps/ezagent_plugin_world/test/support/resource_type_case.ex'
- Modify: 'apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex'
- Modify: 'apps/ezagent_plugin_world/lib/ezagent/world/dispatch_contract.ex'
- Modify: 'apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex'
- Modify: 'apps/ezagent_core/lib/ezagent/plugin.ex'
- Modify: 'apps/ezagent_core/lib/ezagent/uri_query/scan/home_path_exceptions.ex'
- Modify: 'apps/ezagent_core/test/architecture/arch_baseline_manifest.exs'
- Delete or revise only-layout resource-type tests under 'apps/ezagent_plugin_world/test/ezagent/world/'.

**Interfaces:**
- Removes 'Ezagent.World.LayoutManager', 'Ezagent.World.Behavior.Layout', 'Ezagent.World.LayoutBootstrap', and 'mix ezagent.world.migrate_layouts'.
- Produces World metadata that declares no 'world-layouts' resource type and dispatches no 'layout.manage' action.

- [ ] **Step 1: Write the failing boundary test**

  Amend the existing plugin contract test to assert the removed declarations are absent:

  ~~~elixir
  refute "layout.manage" in Ezagent.World.DispatchContract.direct_actions()
  refute Enum.any?(EzagentPluginWorld.Application.resource_types(), &match?({"world-layouts", _}, &1))
  ~~~

  If either function is private, make the same assertion through its existing public dispatch/plugin contract; do not export an API only for a test.

- [ ] **Step 2: Verify RED**

  Run 'mix test apps/ezagent_plugin_world/test/integration/plugin_contract_test.exs'.

  Expected: failure because the action and resource type are registered.

- [ ] **Step 3: Remove every server registration**

  Delete the three layout modules, migration task, and storage-only tests. Remove the resource type and authority helper from the plugin application; remove its bootstrap grant; remove 'layout.manage' from the direct-action contract and 'layout_editor' from the slot registry. Delete matching core plugin/home-path/architecture entries and revise tests whose only purpose was this resource type.

- [ ] **Step 4: Verify GREEN**

  Run 'mix test apps/ezagent_plugin_world/test/integration/plugin_contract_test.exs apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs'.

  Expected: pass with no undefined modules, tasks, resource types, or actions.

- [ ] **Step 5: Commit**

  Run 'git add -u apps/ezagent_plugin_world apps/ezagent_core && git commit -m "refactor(world): remove layout management"'.

### Task 3: Remove front-end editor and browser dispatch

**Files:**
- Delete: 'apps/ezagent_plugin_world/assets/src/components/LayoutEditor.tsx'
- Modify: 'apps/ezagent_plugin_world/assets/src/main.tsx'
- Modify: 'apps/ezagent_plugin_world/assets/src/slots.manifest.json'
- Modify: 'apps/ezagent_plugin_world/assets/scripts/check-mounts.mjs'
- Modify: 'apps/ezagent_plugin_world/assets/e2e/fixtures/world.e2e.fixtures.json'
- Modify: 'apps/ezagent_plugin_world/assets/e2e/world.spec.ts'
- Modify: 'apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs'

**Interfaces:**
- Removes 'LayoutEditor', 'WorldRenderContext.onManageLayout', 'WorldState.can_manage_layout', and the 'layout_editor' manifest entry.
- Produces a renderer with no path capable of emitting 'layout.manage'.

- [ ] **Step 1: Write the failing static front-end assertion**

  Update the mount/manifest script test with:

  ~~~javascript
  assert.equal(source.includes("LayoutEditor"), false)
  assert.equal(source.includes("layout.manage"), false)
  assert.equal(JSON.stringify(manifest).includes("layout_editor"), false)
  ~~~

- [ ] **Step 2: Verify RED**

  Run 'pnpm --dir apps/ezagent_plugin_world/assets test'.

  Expected: failure because the current renderer and manifest contain editor identifiers.

- [ ] **Step 3: Delete editor wiring**

  Remove the component import, context callback, dispatch event, renderer switch branch, permission field, manifest slot/family entry, mount expectation, fixture action, and component file. Keep generic ordered rendering because fixed route layouts still use it.

- [ ] **Step 4: Verify GREEN**

  Run 'pnpm --dir apps/ezagent_plugin_world/assets test' and 'pnpm --dir apps/ezagent_plugin_world/assets build'.

  Expected: both commands pass without TypeScript errors.

- [ ] **Step 5: Commit**

  Run 'git add -u apps/ezagent_plugin_world/assets apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs && git commit -m "refactor(world): remove layout editor renderer"'.

### Task 4: Audit, verify, and open the requested draft PR

**Files:**
- Modify: 'docs/futures/todo.md' only if it has an active layout-editor item now resolved.

**Interfaces:**
- Produces no live-code reference to 'layout_editor', 'layout.manage', 'LayoutManager', 'world-layouts', 'can_manage_layout', or 'onManageLayout'.

- [ ] **Step 1: Audit for complete removal**

  Run 'rg -n -i "layout_editor|layout\\.manage|LayoutManager|world-layouts|can_manage_layout|onManageLayout" apps config mix.exs'.

  Expected: no matches. Retain historical handoff material; edit only active documentation if needed.

- [ ] **Step 2: Run project verification**

  Run 'mix format --check-formatted' followed by 'mix precommit'.

  Expected: successful exits. If an unrelated existing failure appears, record its exact output before deciding whether it is in scope.

- [ ] **Step 3: Review and publish**

  Run:

  ~~~bash
  git status --short
  git diff main...HEAD --check
  git diff main...HEAD --stat
  git push -u origin codex/remove-world-layout-editor
  gh pr create --draft --base main --head codex/remove-world-layout-editor \
    --title "refactor(world): remove layout editor" \
    --body "## Summary
  - remove World layout editor, persistence, and capability flow
  - use fixed single-surface route layouts at bootstrap
  - remove related server and front-end tests/fixtures

  ## Verification
  - mix precommit
  - pnpm --dir apps/ezagent_plugin_world/assets test
  - pnpm --dir apps/ezagent_plugin_world/assets build"
  ~~~

  Expected: only intended files are in the diff and a draft PR URL is returned.

## Self-Review

- Spec coverage: Task 1 removes the visible bootstrap fallback; Task 2 removes behavior, capabilities, storage, and migrations; Task 3 removes the browser editor; Task 4 verifies absence and creates the requested PR.
- Placeholder scan: no compatibility path or unspecified test work remains.
- Type consistency: the retained layout is the existing JSON map with exactly one component; no public API is added.
