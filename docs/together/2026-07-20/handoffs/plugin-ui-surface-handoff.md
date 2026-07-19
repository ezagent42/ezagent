# Handoff — Plugin UI self-declaration (UiSurfaceProvider) → zyli

**From:** Allen / coordinator · **To:** zyli (world read-side) + jjkysy line (kanban/hello migration) · **Date:** 2026-07-19
**Origin proposal:** PR #1468 (the `ui-surface-provider.md` handoff — can be merged/closed; this supersedes it with the grounded design).
**Full design + best-practice research:** `docs/superpowers/specs/2026-07-19-plugin-ui-surface-architecture-research.md`.

## The problem (X = a layering violation)
`world` (itself just a plugin, `apps/ezagent_plugin_world`) conflates three responsibilities that want separate layers: **plugin loading/registration**, **rendering (components+routing+action-admission)**, and **hosting the plugin's React components in world's own bundle**. Landing one plugin UI takes **4 edits to world** (page registry + action allowlist + physical `.tsx` in world assets + session-page special-casing like `isHelloSession`). `hello` is worse — hand-special-cased, not even in the registry. So `world` holds plugin-specific truth that should live in the plugin, breaking plugin isolation.

## Decisions (Allen, 2026-07-19) — these are DECIDED, not open
1. **Shell = demote `world` in place** (Option 1, strangler). NOT a new `ezagent_plugin_shell` layer for v1. Strip world's plugin-specific hardcoding until world is a thin *enumerating shell*; the generic render machinery + slot/anchor grammar + enumeration protocol strengthen in `ezagent_domain_ui`, which world consumes. (Extracting world→peer-plugin is a natural later continuation, not v1.)
2. **Composition model = HYBRID** — a data-described assembly graph (truth-in-plugin for *content*) with **"slot/anchor" as a node kind in the grammar** (B's ergonomics; positions are themselves data, the shell owns no fixed slot enum). This is Backstage's proven model. NOT pure slot-based (Grafana's, where the host re-owns positions).
3. **Renderer bundle-loading v1 = build-time codegen enumeration.** A `mix` task enumerates `PluginRegistry.list_all/0` and generates the imports / `PLUGIN_PAGE_RENDERERS` / manifest (hand-edited today). NOT a runtime loader, and NOT an iframe transition (build-time codegen is neither — it satisfies "one unified migration, no iframe, world zero-hardcode" without runtime-loader risk, honoring the islands-spec "no runtime Node tier" decision). Runtime dynamic-`import()` + import maps is deferred behind a future hot-install gate.

## Scope split
- **zyli — world read-side:** reverse the page-registry + action-allowlist data source (compile-time constants → runtime enumeration of plugin `UiSurfaceProvider` declarations); the build-time codegen mix task; dissolve the session-page special-casing. Extend the existing #1117 `UiSurfaceProvider` / `PluginPageRegistry` / `SlotRegistry` (already a *partial* Approach A — nav is self-declared, fail-closed) to cover the `page` surface + the renderer face.
- **jjkysy / kanban line — plugin migration:** move `Kanban.tsx` (and hello's components) back into their own plugins; each declares its 4 surfaces (page / action-allowlist / data-fn / render) via `UiSurfaceProvider`; delete world-side hardcoding + the D6 exception list + hello's `isHelloSession` residues. One unified migration (no iframe stage — hello's original author has left, a transition state would become a third residue).

## The drift-prevention gate (REQUIRED — mirrors the read-plane enumerator gate)
Extend the 3 existing enforcers with a **new tooth: world source must contain no plugin-name literal** (`"kanban"`, `"hello"`, `KanbanData`, `KanbanActions`, …). The allowlist starts non-empty and shrinks to `[]`; the **empty-allowlist red build names every remaining hardcoded plugin touch-point in world** (a live debt inventory), green only when world holds zero plugin-specific truth. Plus fail-closed: any action served without a plugin declaration is rejected. This is what prevents the next plugin from re-accreting hardcoding (hello was the cautionary third-residue case).

## Next step
Coordinator (cc) will formalize the research into an implementation plan (task-by-task, TDD) and codex-review it before zyli starts. This handoff + the research doc are the design of record.
