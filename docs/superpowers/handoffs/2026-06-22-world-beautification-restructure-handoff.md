# Handoff (codex-reviewed — Allen-confirmed): world UI beautification + product-structure adjustment

> **Date:** 2026-06-22 · **From:** Claude (with Allen) · **To:** an independent developer (human + cc/codex)
> **Tracking:** task #83 · **Base:** `origin/main` @ `0987a7eb`
> **Status:** Allen-confirmed (big-bang shadcn; full scope; layout = typed-slot registration; gate = hard-fail; migrate all `world-*` this round) + codex-adversarially-reviewed (refined the *how*: registry-first, two-layer gate, staged-but-complete migration, a three-category slot model). Research: `docs/superpowers/notes/2026-06-22-world-state-research.md`. **MUST follow `docs/guide/world-coordination.md`** — highest-collision world effort.

## 0. Mission
Beautify `world` on a real **shadcn/Tailwind** foundation, adjust its product structure, AND **define + make real the layout system as a typed-slot registry with a hard-fail gate**, so the next phase's components depend on a stable contract that can't be bypassed (protecting the admin surface from divergence).

## 1. Current state (the starting reality — research-verified)
- **Styling schism:** `components.json` declares shadcn but **no `tailwindcss` dependency**, empty Tailwind config path, shadcn unused. Real styling = `assets/src/styles.css` (~1,657 `world-*` BEM lines); React imports it directly (`main.tsx:12`). `ui/primitives.tsx` is at **`assets/src/components/ui/primitives.tsx`** (note path) and mostly **dead/inert**; only `ui/button.tsx` is used — and `Button` lacks a `size` variant while callers pass `size` (`button.tsx:6-21`, `LayoutEditor.tsx:34`).
- **Layout is mostly inert + has no real slot contract:** `Behavior.Layout` accepts only `layout: :map` with **no slot-registration API** (`layout.ex:9-15`); `LayoutManager` validates a string `type` + opaque `props` against an allowlist (`layout_manager.ex:144-149`). Persisted layout drives **only** `sessions_table`; every other route gets a synthetic one-component layout (`world_live.ex:431-449`); `can_manage_layout` is hardcoded `false` on most routes (`world_live.ex:478-510`). `main.tsx`'s `renderLayoutComponent` is a hardcoded `type→TSX` chain with an **unknown-type fallback to `IdentitiesSurface`** (`main.tsx:333-400`) — the opposite of hard-fail.
- **Admin = stubs** (generic `DataTable` + JSON dumps); **nav IA gaps** (no breadcrumbs/back-nav/workspace-switcher; Identities/Users/Agents triple entry).
- **Coupling gotcha:** `primitive_coverage_test.exs` regexes atom strings out of `primitives.tsx`; the Elixir atom layer is **split** across `EzagentDomainUi.Components` (button/input/card) and `EzagentDomainUi.Primitives`.
- **Slot-boundary ambiguity:** `pty_terminal` is BOTH a registered layout type (`layout_manager.ex:29`) AND rendered nested inside `Conversation` (`Conversation.tsx:369`, `PtyTerminal.tsx:99`) — so "rendered outside the registry" is already ambiguous without a category model.

## 2. Decisions (Allen) + how (codex-refined)
- **(A) shadcn/Tailwind foundation** + **(b) full scope** (styling + admin productization + nav IA + the layout-system contract & gate).
- **Layout = typed-slot registration; gate = hard-fail; migrate ALL `world-*` this round.** Codex refinements to the *how* (all preserve those end-states):
  - **Registry-first:** define the real slot schema + source-of-truth registry **before** restyling.
  - **Three slot categories** (resolve the ambiguity): **layout slot** (route-level, participates in the hard-fail registry), **nested subcomponent** (owned by its parent, marked e.g. `data-world-subcomponent`, NOT in the registry), **shell chrome** (sidebar/header/command palette — `main.tsx:91-148` — explicitly outside the grid via a seed allowlist).
  - **Two-layer gate** (a plain Elixir test can't see React runtime): (1) an Elixir test comparing route component strings (`world_live.ex:612-799`) against a checked-in slot manifest → fail on unregistered route slots; (2) a JS/TS static check / lint rule banning top-level world surfaces from mounting except through the layout renderer. Both with an explicit **seed allowlist** for shell chrome.
  - **Staged-but-complete migration:** still migrate ALL `world-*` **this round**, but in recoverable stages, not one unrecoverable big-bang commit (see §3.1).

## 3. Workstreams

### 3.0 Define the typed-slot contract FIRST (gates everything)
- A real **slot schema** + a source-of-truth **registry**: `LayoutManager` owns registered slot specs (stable `type`, a props/data contract, a renderer family) — not just a string allowlist (`layout_manager.ex:10-38`). Make slots **renderer-agnostic catalog entries** (type + data contract + renderer family), so React renderers are one implementation — this is what makes the later world→`@json-render` convergence "swap the renderer," not "rewrite."
- `WorldLive.route_for/2` returns a registered slot id/type; `layout_for_route/2` reads/derives a **validated** layout for **every** route (not just `/sessions`); resolve `can_manage_layout` to a real per-route policy.
- `main.tsx` replaces the hardcoded `renderLayoutComponent` chain with a **registry-backed renderer**, and **removes the unknown-type→`IdentitiesSurface` fallback** (`main.tsx:399`) — unknown = fail, not silently render admin.

### 3.1 Styling foundation (staged-but-complete this round)
- **Stage 1:** wire Tailwind + shadcn (add the deps; real config) **without deleting `world-*`** — both coexist transiently.
- **Stage 2:** make the primitive barrel real (live shadcn at `assets/src/components/ui/primitives.tsx`); fix mismatches (`Button` `size` variant, the `world-button-primary` missing rule); update the split atom layer (`EzagentDomainUi.Components` + `.Primitives`) + `primitive_coverage_test` in lockstep (preserve the string list first, then swap to a registry comparison).
- **Stage 3:** migrate route surfaces **one cluster at a time behind the slot registry**.
- **Stage 4:** delete remaining `world-*` only after static reference scans are clean. End state = full migration (Allen's "全迁"), reached safely.
- Add dark mode (the `:root` var foundation is one override away) + finish tokenizing.

### 3.2 The gate (two-layer, hard-fail, seeded)
Build the two-layer gate from §2 + a documented seed allowlist (shell chrome + the three categories). Wire the Elixir layer into the fitness-function suite (`arch_baseline_manifest.exs` family); add the JS/TS layer to the frontend checks. Hard-fail once the registry + categories are in place; the seed allowlist is the only escape and must be explicitly logged/justified.

### 3.3 Admin productization
Replace the generic `DataTable` + JSON dumps with real shadcn tables/detail views + a meaningful dashboard. These are the **first catalog-shaped slots** (data/form — most `@json-render`-amenable).

### 3.4 Nav IA
Breadcrumbs + back-nav; a workspace switcher (scope is display-only today); rationalize the Identities/Users/Agents triple entry-point.

## 4. @json-render forward-shape (not the migration)
Do NOT convert world to `@json-render` this round (that's the separate world→hello Phase 3). But the slot contract (§3.0) being renderer-agnostic + shadcn-shaped is the down-payment. **Exclude Conversation, PTY, and LayoutEditor from any forced catalog shape** until a spike proves it; admin tables/forms are the catalog-amenable pieces.

## 5. world-coordination (mandatory — highest-collision effort)
Strictly follow `docs/guide/world-coordination.md`: declare owned surfaces in the in-flight registry; **serialize `styles.css` edits to one owner or co-locate per component as you migrate**; coordinate every existing-surface restyle with its owner / the active world-dev; small PRs into this task's branch, kept rebased on `main`.

## 6. Merge model & gates
- **Merge model:** split into PRs as needed (the stages map naturally to PRs); all PRs merge into this task's branch (e.g. `world-beautify`), never `main`; keep rebased on `main`; Allen merges the task branch → `main`.
- Gates: `arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test` + **the new two-layer layout gate** + the frontend checks (React build, `primitive_coverage_test`). Load skill `ezagent-developer`.

## 7. Decisions recap + residual
**Confirmed (Allen):** shadcn/Tailwind; full scope; typed-slot registration; hard-fail gate; full `world-*` migration this round; make primitives real; codex-reviewed.
**Codex-refined (the *how*, preserving the above):** registry-first; three slot categories (slot/subcomponent/shell); two-layer gate (Elixir route-manifest + JS/TS static) with a seed allowlist; staged-but-complete migration (full end-state, recoverable path); renderer-agnostic catalog slots.
**Residual for the implementer:** exact slot-spec fields + the registry API; the JS/TS gate mechanism (lint rule vs build-step manifest check); the precise seed allowlist; per-route `can_manage_layout` policy.

---
*Allen-confirmed + codex-reviewed 2026-06-22. The one judgment call surfaced to Allen: codex refined "big-bang" → "staged-but-complete within this round" (same full-migration end-state, recoverable path). Ready for an independent dev.*
