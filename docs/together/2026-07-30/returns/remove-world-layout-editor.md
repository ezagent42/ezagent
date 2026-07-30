> **Task:** remove-world-layout-editor
> **Branch:** `codex/remove-world-layout-editor`
> **PR:** https://github.com/ezagent42/ezagent/pull/1649
> **Dev:** codex
> **returned_at:** 2026-07-30 16:53 +0800
> **deadline:** 2026-07-30 23:59 +0800
> **deadline_status:** deferred

## What changed

- Removed the World layout editor renderer, its browser dispatch action, the layout
  behavior/bootstrap/manager, the persisted resource type, and its migration task.
- Changed World bootstrap and route state to use the route-defined, single-surface
  layout. Chat now starts with one `sessions_table` component.
- Removed layout-only tests, fixtures, registry entries, and stale core scan/baseline
  anchors. Added a typed-slot gate that keeps the removed renderer and manifest entry absent.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | No runtime code exposes `layout_editor`, `layout.manage`, `LayoutManager`, or `world-layouts`. | met | Scoped `rg` audit has no World-specific runtime references; the only remaining `world-layouts` hits are core's generic slug-prefix examples. |
| 2 | Chat initially renders exactly one `sessions_table` and no layout-management state. | met | `mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs:37` — 1 test, 0 failures. |
| 3 | React manifest, renderer, fixtures, and mount gate have no layout-editor entry. | met | Node 22.23.1: frontend `pnpm test` — 8 files / 39 tests passed; `pnpm build` passed; Elixir slot tests — 10 tests passed. |
| 4 | Removed resource type, behavior, capability, and migration have no stale baseline reference. | met | `mix test apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs` — 10 tests, 0 failures; scoped audit above. |
| 5 | `mix precommit` and CI are green on the pushed, rebased branch. | deferred | Branch is based at `81a90855c353aae7ed832a5b988bb5dff711ccc5` (current local `main`) and pushed. Local `mix precommit` was started but its long-running output session closed after compilation, so no reliable exit status exists; PR CI URL/status was unavailable when queried (GitHub TLS handshake timeout). Lead/CI must run and record this gate. |
| 6 | Draft PR is opened with verification and environment limitation stated. | met | https://github.com/ezagent42/ezagent/pull/1649 |

## Verification

- PASS: `mix format --check-formatted`
- PASS: `mix test apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs` — 10 tests, 0 failures.
- PASS: `mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs:37` — 1 test, 0 failures.
- PASS: `mise exec node@22.23.1 -- corepack pnpm --dir apps/ezagent_plugin_world/assets install --frozen-lockfile`
- PASS: `mise exec node@22.23.1 -- corepack pnpm --dir apps/ezagent_plugin_world/assets test` — 8 files / 39 tests passed.
- PASS: `mise exec node@22.23.1 -- corepack pnpm --dir apps/ezagent_plugin_world/assets build`
- PASS: `git diff main...HEAD --check`
- KNOWN FAILURE: full `world_host_routing_test.exs` triggers the documented asynchronous LiveView task / SQL Sandbox-owner timing failure. It leaves initial state at `sessions_table`, producing unrelated route assertions such as empty header workspaces. This task does not mask or relax those assertions.
- UNVERIFIED: local `mix precommit` final result and PR CI status (see DoD line 5).

## Open decisions

- Lead/CI: run `mix precommit` and `mix ezagent.check_invariants` on PR #1649, record the CI run URL/status, and adjudicate the existing World async sandbox failure before merging.

## Merge request

- Commit: `e4b85aa19 refactor(world): remove layout editor`
- Branch: `codex/remove-world-layout-editor`
- Draft PR: https://github.com/ezagent42/ezagent/pull/1649
- Rebase base: `81a90855c353aae7ed832a5b988bb5dff711ccc5` (`main` at return time).
- Merge order: standalone mechanical removal; it can be stacked after current `main` gates pass.

**Method friction:** The handoff's required local `mix precommit` gate had no reliable final result because the long-running command's output session closed after compilation. The same task already documented a separate full World-routing-suite SQL Sandbox timing issue. The return preserves both as explicit lead/CI gates rather than treating partial verification as completion.
