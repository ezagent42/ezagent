# Return: PR #1508 Kanban workbench + Manage navigation

> **Task:** PR #1508 — Kanban workbench polish and admin-session navigation
> **Branch:** `codex/kanban-ui-polish`
> **PR:** https://github.com/ezagent42/ezagent/pull/1508
> **Dev:** codex
> **returned_at:** 2026-07-22 18:11 +0800
> **deadline:** 2026-07-22 23:59 +0800
> **deadline_status:** deferred
> **rebase base:** `origin/main` @ `240d00e0f`

## What changed

- Rebased the PR onto current `origin/main` and resolved the sole conflict by
  applying the Kanban workbench changes to the component's new plugin-owned
  location, `apps/ezagent_plugin_kanban/assets/src/Kanban.tsx`.
- Preserved the World navigation change: `/overview`, `/admin`, and `/admin/*`
  use LiveView navigate; ordinary allowlisted World destinations still patch.
- Updated the Kanban detail regression test after the latest main moved both the
  component and its `mode` selection into the Kanban plugin.
- Added this return artifact.

## DoD reconciliation

| # | DoD line | Status | Proof / open decision |
|---|---|---|---|
| 1 | PR branch is rebased onto current main and no longer has a merge conflict. | met | Rebased commit `4fcb3c5a9`; parent is `240d00e0f` (`origin/main` at rebase time). |
| 2 | Kanban detail workbench preserves its header, canvas, and empty-tree user-facing states after the component move. | met | `node apps/ezagent_plugin_world/assets/test/kanban_detail_mode_test.mjs` passes; it asserts `data-world-kanban-workbench`, `data-world-kanban-canvas`, and `data-world-kanban-empty-tree` in the plugin-owned component. |
| 3 | The Kanban plugin page retains its operate/config mode selection after the move. | met | Same Node regression test asserts `world_page.tsx` selects `mode={pageState.kanban_uri ? "operate" : "config"}`. |
| 4 | Manage/admin destinations cross their LiveView-session boundary with navigate, while ordinary World navigation remains a patch. | met | `mix test apps/ezagent_plugin_world/test/ezagent/world/navigation_test.exs` — 9 tests, 0 failures. |
| 5 | Required deterministic machine gate is green on this rebased head. | deferred | `mix ci.fast` fails on current main's `EzagentCore.Invariants.PluginWorkspaceLocalityContractTest`: it reports pre-existing `world_live.ex` unknown-value locality findings. The failure is unrelated to this PR's navigation handler, but it prevents a valid green machine return. Lead decision required: fix/unblock the main baseline, then rerun CI on this head. |
| 6 | Frontend type checking is clean. | met | `corepack pnpm --dir apps/ezagent_plugin_world/assets run typecheck` exits 0. |

## Validation evidence

- `node apps/ezagent_plugin_world/assets/test/kanban_detail_mode_test.mjs` — pass.
- `mix test apps/ezagent_plugin_world/test/ezagent/world/navigation_test.exs` — 9 tests, 0 failures.
- `corepack pnpm --dir apps/ezagent_plugin_world/assets run typecheck` — pass.
- `mix ci.fast` — **not green**; see DoD item 5. The initial failure is the
  workspace-locality contract scan in `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` after rebasing to `240d00e0f`.

## Deferred / lead decision

The PR is rebased and its focused regressions pass, but it is not ready for a
green-gate merge claim. Please decide whether to first repair the current main
workspace-locality baseline (or otherwise establish the expected invariant
baseline), then rerun the deterministic CI gate on this PR.

## Method friction

The PR's Kanban component and page-mode ownership moved to
`ezagent_plugin_kanban` on main after the original commit. Rebase surfaced the
stale test paths; the regression test now follows the actual plugin boundary.

## Merge request

Push this rebased branch to update PR #1508 using `--force-with-lease`. Do not
merge until CI is green on the rebased head and the deferred gate decision is
resolved.
