# World coordination guide

> **Audience:** every developer (human or agent) whose work touches `apps/ezagent_plugin_world/` or the world frontend.
> **Status:** living document — update the in-flight registry (§5) when you start or finish world work.
> **Rule:** every handoff/plan/PR that touches world MUST link this file and include a "world conflict-avoidance" section derived from it.

## 0. Why this exists

`world` is the operator console and the single most-contended part of the codebase: multiple independent efforts touch it at once (UI beautification, an Agent Console feature, ongoing logic completion, and the eventual `hello`/`@json-render` convergence). Without coordination they collide on the same files. This guide is the shared contract that keeps parallel world work from blocking each other. **world development must never become the bottleneck that stalls other developers.**

## 1. The collision hotspots (know these before you edit)

These few artifacts cause most merge pain because they are large and central:

- **`apps/ezagent_plugin_world/assets/src/styles.css`** — a single ~1,657-line hand-written `world-*` BEM stylesheet. Any restyle hammers it. **Highest collision risk.**
- **`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`** — a single ~990-line LiveView holding routing + the `world:dispatch` handler + per-route state. Adding a surface touches it.
- **The `ezagent_domain_ui` ↔ React primitive coupling** — `apps/ezagent_plugin_world/test/ezagent/world/primitive_coverage_test.exs` asserts each `ezagent_domain_ui` atom string appears in `assets/src/ui/primitives.tsx`. Editing the primitive set means editing the test + the atom layer in lockstep.
- **Shared additive files** every new plugin/surface also edits: `config/config.exs`, `config/dev.exs`, root `mix.exs` (releases), `apps/ezagent_web/mix.exs`, `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`. These are append-only; coordinate by keeping edits minimal.

## 2. The rules

1. **Partition by surface.** world is componentized: each surface is a `*.tsx` in `assets/src/components/` + a route clause in `world_live.ex` + a `*_data.ex` (reads) / `*_actions.ex` (writes) pair. **Adding a NEW surface is additive and nearly collision-free.** **Re-styling or restructuring an EXISTING surface needs a declared owner** (see §5) — do not edit a surface someone else owns without coordinating.
2. **`styles.css` discipline.** During any beautification effort, either (a) serialize all `styles.css` edits to a single owner, or (b) co-locate styles per component as you migrate. Never have two efforts editing `styles.css` in parallel.
3. **Small PRs into the task branch; keep it rebased; the lead merges to `main`.** Per the standing handoff rule, work merges into the effort's own **task branch** (not `main` directly); the lead (Allen) merges the task branch → `main`. **Keep the task branch rebased on `main` frequently so it never rots** — `origin/world` / `origin/world-integrate` are the cautionary tale (0 ahead / 25+ behind main). Small PRs into the task branch + frequent rebase, never a months-long divergent branch.
4. **Never block on a sibling effort.** If your work needs a change to a surface another effort owns, prefer an additive seam (a new component/action) over editing theirs; if you truly must, coordinate the edit window via §5.
5. **Plugins reuse world's transport by pattern, not by edit.** A separate plugin (e.g. `hello`) that wants world's island bridge copies the `WorldRenderer`/`mountWorld` + `world:dispatch` pattern into its own bundle — it does **not** import world's bundle or edit world's files. world-internal edits are reserved for work that is genuinely *about* world.

## 3. The structural de-conflict: `@json-render` convergence

world is collision-prone because it is bespoke TSX + one giant CSS file. The long-term fix is the planned `@json-render` convergence (see the `hello` handoff and the frontend-unification synthesis note): as world's data/list/form surfaces become **data-driven `@json-render` specs over a shared component catalog**, adding features and restyling become **edits to catalog/specs (data)** rather than **merges of bespoke components (code)** — which structurally lowers the conflict rate.

Practical implication for any world work now: **build new surfaces and restyles in the shadcn shape `@json-render/shadcn` uses**, even before the formal convergence, so the later migration is "swap the renderer," not "rewrite the components." (Bespoke-interactive surfaces — PTY terminal, layout editor, conversation composer — stay hand-written.)

## 3a. The typed-slot layout gate (adding a world surface)

Every route-level world surface is a **typed slot** with one source of truth:
`Ezagent.World.SlotRegistry` (renderer-agnostic `{type, renderer_family,
data_source, category, title}`). The React renderer (`main.tsx`) dispatches on
`renderer_family` from a generated, checked-in `assets/src/slots.manifest.json`
— there is **no unknown-type fallback** (an unregistered type throws).

To add a route surface: add the slot to `SlotRegistry`, run
`mix world.slots.manifest`, add a route clause in `world_live.ex`, and (if it is
a new renderer family) a `case` in `main.tsx`'s renderer.

Two hard-fail gates enforce this (don't route around them):

- **Layer-1** (`slot_registry_test.exs`) — every `world_live.ex` route component
  ⊆ the registry; the checked-in manifest is in sync with the registry.
- **Layer-2** (`slot_mount_gate_test.exs`, mirror `pnpm check:mounts`) — surfaces
  mount ONLY through the renderer; renderer families == manifest families.

Three slot **categories** (the only ways to render):

1. `:layout_slot` — route-level, in the registry.
2. `:subcomponent` — parent-owned nested slot (e.g. the PTY inside Conversation).
   Mark it `data-world-subcomponent` and allowlist it in the Layer-2 gate.
3. `:shell` — universal chrome. The **seed allowlist** is `SlotRegistry.shell_chrome/0`
   (`world-sidebar`, `world-header`, `world-cmdk`) — the only sanctioned mounts
   outside the renderer.

## 4. Sequencing the current efforts

- **Active world-dev (beautification/logic completion):** do not interrupt; it lands continuously.
- **world UI beautification + product restructure (#83):** touches shared CSS and existing surfaces → **highest collision**. Gate it behind the styling-system decision (adopt real Tailwind/shadcn vs. perfect the bespoke `world-*` system) before broad edits.
- **Agent Console feature (#84):** primarily a **new** surface (additive) → can run largely in parallel; coordinate only its `world_live.ex` route clause and any shared-file edits.
- **`hello` Phase 0:** fully isolated (its own plugin) → parallel anytime. `hello` Phase 2-3 (world produces / becomes hello) is the convergence point and is an explicit, coordinated, separate effort — not done while world's active UI work is in flight.

## 5. In-flight world work registry (update me)

Keep this table current. Before starting world work, add your row; on finishing, remove it. "Owns" = the surfaces/files you are actively editing.

| Effort | Owner | Surfaces / files owned | Status |
|--------|-------|------------------------|--------|
| Manage admin cross-session navigation | codex (codex/kanban-ui-polish) | world_live.ex (world:navigate only), navigation.ex, navigation tests | in-flight |
| _active world-dev_ | (world dev) | UI polish + logic completion (assume `styles.css` + existing surfaces) | ongoing |
| world beautification + restructure (#83) | claude (`world-beautify`) | layout/slot system (`layout_manager.ex`, `behavior/layout.ex`, `world_live.ex` route+layout fns, `main.tsx` renderer), then `styles.css`, existing surfaces, design system, `primitives.tsx` + atom layer | ✅ MERGED to main (shadcn/typed-slot) |
| Agent Console (#84) | agent-console dev | Phase 0: standalone static demo (`apps/ezagent_web/priv/static/agent-console-demo/` + `static_paths` allowlist) — touches NO world files. Phase 1+: new `agent_console` surface + `*_data/*_actions` + `world_live.ex` route clause | Phase 0 demo merged (`#892`) |
| Agent Console CRUD (#84) | claude (`feat/agent-console-crud`) | identities/agents Delete + Create-hardening: `Identities.tsx` (agent components), `main.tsx` (renderer wiring), `world_live.ex` (`agents.delete` clause + helpers), `identity_data.ex` (additive); bound-gate via `EzagentDomainInstanceMessage.agent_live_sessions/1` | in-flight |
| hello (Phase 0, #81) | TBD | none in world (isolated plugin) | handoff merged |
| F9 external-mirror bind UI | zyli (`feat/product-gaps-f9-f12`) | `Admin.tsx` (ExternalMirror surface only — additive bind form + unbind col), `admin_actions.ex` (external_mirror.bind/unbind handlers), `admin_data.ex` (promote `external_mirror_bindings_for/1` public), `world_live.ex` (`@admin_actions` whitelist) | in-flight — no `styles.css`, no shared-surface conflict (agent-console-crud owns `Identities.tsx`, not `Admin.tsx`) |
| FP5 UI 巡检纯 UI 修复 | zyli (`zyli/fp5-ui-fixes-0626`) | S1-a `SessionsTable.tsx`、S7-a `admin_data.ex`(zyli F9 已 own)、S9 `kanban_data.ex` + kanban `application.ex`、S9b 同上、**S2-a 新建 Overview 面**:新建 `components/Overview.tsx`、`routes.ex`(`/`→overview)、`slot_registry.ex`+`slots.manifest.json`、`admin_data.ex`(kpis helper)、`world_live.ex`(**additive** overview 路由子句)、`main.tsx`(**additive** renderer case)。**无 `styles.css`、无 `Identities.tsx`** | in-flight — `world_live.ex`/`main.tsx` 仅 additive 新增(新 surface),与 agent-console-crud 的 `agents.delete`/`Identities.tsx` 零交集 |

## 6. The checklist every world-touching handoff must include

Copy this into the handoff's conflict-avoidance section:

- [ ] Linked this guide.
- [ ] Declared which surfaces/files the effort owns; added a row to §5.
- [ ] New surface (additive) vs. existing-surface edit (needs owner coordination) — stated which.
- [ ] `styles.css` edit plan (serialized owner or per-component co-location) if restyling.
- [ ] Work on the effort's task branch; small PRs into it; rebase on `main` often; the lead merges the task branch → `main`.
- [ ] Built in the shadcn/`@json-render` shape where the surface is data/form-shaped.
- [ ] Listed the shared additive files it will touch (config, mix, manifest).
