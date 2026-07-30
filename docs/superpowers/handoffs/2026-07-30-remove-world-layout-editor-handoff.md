# Handoff: Remove World Layout Editor

> **Date:** 2026-07-30 · **From:** Codex · **To:** independent developer
> **Tracking:** user-requested removal · **Base:** `main` @ `81a90855c`
> **Status:** confirmed design; implementation partially complete and uncommitted.

## 0. Mission

Completely remove the unused World layout-editor feature. World routes must use fixed, single-surface layouts; no user can see, manage, persist, or dispatch a configurable layout.

## 1. Required reading

1. Skill `ezagent-developer`, especially UI and CapBAC references.
2. Skill `elixir-phoenix-helper`.
3. `docs/guide/world-coordination.md`.
4. Skill `dev-together`.
5. `docs/superpowers/specs/2026-07-30-remove-world-layout-editor-design.md`.
6. `docs/superpowers/plans/2026-07-30-remove-world-layout-editor.md`.

## 2. Locked decisions

| Decision | Value |
|---|---|
| Product behavior | No layout editor for any user, including admins. |
| Persistence | Do not read, migrate, or retain compatibility for `world-layouts` files. |
| UI layout | Every World route uses its existing fixed single-component layout. |
| Delivery | Commit the completed work on `codex/remove-world-layout-editor`, push, and open a draft PR. |

## 3. Current implementation state

Worktree: `.worktrees/remove-world-layout-editor` on branch `codex/remove-world-layout-editor`.

Already changed:

- Deleted `LayoutEditor.tsx`, `LayoutManager`, Layout behavior/bootstrap, the layout migration task, and storage-only tests.
- Removed the editor renderer, browser dispatch, slot-registry entry, direct action, resource registration, behavior registration, and layout capability state.
- Chat bootstrap now begins as a single `sessions_table` layout; its new regression assertion passes when run in isolation.
- Removed several layout-only Web tests and resource-registration setup helpers.

Do not discard these changes. They are currently uncommitted.

## 4. Remaining work

1. Remove all remaining runtime/test references reported by:

   ```bash
   rg -n -i 'layout_editor|layout\.manage|LayoutManager|world-layouts|can_manage_layout|onManageLayout|LayoutBootstrap' apps/ezagent_plugin_world apps/ezagent_core apps/ezagent_web/test
   ```

   Core generic examples/comments may retain generic slug-prefix examples only if they do not describe the removed feature; remove World-specific baselines and home-path exceptions.

2. Remove the `world-layouts` setup helper in `apps/ezagent_web/test/ezagent_web/world_admin_route_gate_test.exs`.

3. Update slot manifest/mount tests so the manifest is synchronized with `Ezagent.World.SlotRegistry`.

4. Run focused tests. The full `world_host_routing_test.exs` currently has a pre-existing async bootstrap/sandbox timing failure: background tasks outlive the test owner, and the header-switcher assertion reads an empty workspace list. Diagnose before changing it; do not mask it.

5. Frontend checks require Node 22.13+ because installed pnpm 11 imports `node:sqlite`; this environment has Node 20.19.4. Use the project’s supported Node runtime if available, then run:

   ```bash
   pnpm --dir apps/ezagent_plugin_world/assets install --frozen-lockfile
   pnpm --dir apps/ezagent_plugin_world/assets test
   pnpm --dir apps/ezagent_plugin_world/assets build
   ```

6. Run `mix format --check-formatted`, `mix precommit`, review the diff, commit, push, and open the requested draft PR.

## 5. Definition of Done

- [ ] No runtime code exposes `layout_editor`, `layout.manage`, `LayoutManager`, or `world-layouts`; proof: scoped ripgrep audit is empty.
- [ ] Chat’s initial rendered state has exactly one `sessions_table` component and no layout-management state; proof: `WorldHostRoutingTest` regression test.
- [ ] React manifest, renderer, fixtures, and mount gate have no layout-editor entry; proof: frontend test/build under supported Node.
- [ ] Removed resource type, behavior, capability, and migration have no stale test/baseline reference; proof: compilation and relevant test suites.
- [ ] `mix precommit` and CI are green on the pushed, rebased branch.
- [ ] Draft PR is opened against `main` with verification results and any environment limitation explicitly stated.

## 6. Discuss-first and deferred

**Clarify-first:** not needed for the mechanical removal already approved by the user.

**Do not defer:** removal completeness, manifest parity, tests, or CI gates.

**Environment blocker:** Node upgrade/switch is required for frontend validation; flag it in the PR only if no supported runtime is locally available.

## 7. Conflict avoidance

This task owns World plugin layout modules, World React renderer/manifest/fixtures, directly related tests, and the design/plan/handoff documents. Avoid unrelated World UI refactors.

## 8. Merge model

Commit only on `codex/remove-world-layout-editor`; never merge directly to `main`. Open a draft PR after verification.

## 9. Known verification evidence

- `mix compile` passed after removing the stale plugin behavior registration, with unrelated existing warnings.
- The isolated Chat bootstrap regression first failed against the old two-component layout and passed after the fixed bootstrap change.
- Full `world_host_routing_test.exs` currently fails due to the async database sandbox timing issue described above.
