# Research note: world frontend state (for beautification + product-structure handoff)

> **Date:** 2026-06-22 · **Author:** Claude (background research subagent) · **For:** task #83 (+ informs #84, #85).
> **Base:** `origin/main` @ `b6818123`. READ-ONLY snapshot. world is under ACTIVE parallel dev — treat as a snapshot. `origin/world`/`origin/world-integrate` are STALE (0 ahead / 25 behind) — **main is the canonical world surface**.

## Headline findings
- **No `hello` plugin exists yet** (only the handoff doc + `WorldHello.tsx` splash + socialware's `json_render.mjs`). `@json-render` direction is research-only today.
- **Styling schism (the #1 beautification blocker):** `components.json` declares shadcn (new-york/slate) but **Tailwind is NOT installed/wired** and **shadcn is not used**. Real styling = `assets/src/styles.css`, **1657 hand-written lines** of `world-*` BEM classes + a few `:root` CSS vars (teal `#0f766e`). `ui/primitives.tsx` (~30 Tailwind-class components) is **dead/inert** (no Tailwind compiler); only `ui/button.tsx` is used (bridges to `world-button*` BEM). NOT shadcn, NOT Tailwind, NOT daisyUI. Light-only, no dark mode, no i18n.

## 1. Surfaces / routes
Single LiveView `EzagentPluginWorld.WorldLive` (990 lines), per-route on `host: "world."` behind `RequireEntity`. `route_for/2` parses path → `%{component, group}` selecting a React surface. Routes: `/`,`/sessions` (sessions_table / conversation), `/identities[/users|/agents|/agents/new|/agents/:uri[/caps|api-keys|extensions|terminal]]`, `/workspaces[/:name]`, `/plugins[/feishu/bindings|/auto/:kind]`, `/profile`, `/admin[/logs|registry|snapshots|templates|caps|settings|routing|audit/authz|sessions/:id/external_mirror]`.
React surfaces (`assets/src/components/`): `SessionsTable`(131), `Conversation`(707, **most polished** — mentions/uploads/members/routing/PTY toggle), `Identities`(503, 8 sub-surfaces), `WorkspacePlugin`(592), `Admin`(325, mostly a generic introspecting `DataTable`+JSON dump), `PtyTerminal`(134, xterm island), `LayoutEditor`(101), `WorldHello`(65), `ui/primitives`(355, dead)+`ui/button`(29). IA: flat 9-link sidebar; **no breadcrumbs/back-nav/workspace-switcher**; deep pages reached only via in-table links.

## 2. Design system
See headline. Coherent but bespoke `world-*` CSS. Aspirational shadcn scaffolding never adopted. Partial token discipline (repeated hardcoded hex). No dark mode (one `:root` override away). No i18n.

## 3. Layout system (big spec-vs-reality gap)
`Behavior.Layout` (cap-gated `:manage`) + `LayoutManager` (file-backed `$EZAGENT_HOME/world/layouts/<scope>.json`, 27-type allowlist) + `LayoutEditor.tsx` (vertical reorder only). **Reality:** persisted layout read ONLY for the `/sessions` landing; every other route gets a synthetic single-component layout; `can_manage_layout` hardcoded `false` except `/sessions`; the "12-col grid" is fake (`grid-template-columns: minmax(0,1fr)` single column, only `y`-ordering honored). The marquee "users arrange the UI" = reorder 2 cards on 1 screen.

## 4. Product structure awkwardness
Overlapping session surfaces (table vs conversation on same route; PTY reachable 3 ways); Identities overloaded (1 nav → 8 sub-surfaces, but Users/Agents ALSO top-level → 3 entry points); Admin = flat dump of 9 routes mostly identical generic table; Routing appears 3× (per-session / workspace / global admin) with no unifying model; missing connective tissue (no breadcrumbs, scope is display-only).

## 5. UI quality / pain points
- **Dead `primitives.tsx` barrel** — but **load-bearing for a gate**: `test/ezagent/world/primitive_coverage_test.exs` asserts each `ezagent_domain_ui` atom string appears in `primitives.tsx`. Can't delete without touching that test + the `ezagent_domain_ui` atom layer (`primitives.ex`).
- Admin surfaces are stubs (`DataTable` + `<pre>{JSON.stringify}</pre>`).
- Inconsistent buttons: `Button` primitive ignores a passed `size` (no size variant); raw `world-button-primary` is emitted but **has no CSS rule**.
- Uneven loading/empty/error states (Conversation good; admin dumps none). Partial a11y (aria labels yes; no cmdk focus trap; tables `min-width:760px` → mobile h-scroll). Hand-managed responsiveness.
- Most polished: Conversation. Least: admin/data surfaces.

## 6. @json-render alignment
Synthesis note `docs/notes/2026-06-19-frontend-unification-synthesis.md` (research-only): adopt `@json-render/*` on the customer/generative surface FIRST, build cookie→cap auth bridge once, **spike-gate** admin migration; do NOT retire LiveView yet; `@json-render` is **pre-1.0 (v0.19.0)**.
- **Most amenable** (data/list/form → near-trivial catalog entries): the whole Admin cluster, users/agents tables, entity_caps, api_keys, workspaces_list, plugins, the forms. The generic `DataTable` is a hand-rolled mini-renderer doing what @json-render does properly.
- **Least amenable** (bespoke interactive): PtyTerminal, LayoutEditor, Conversation composer.
- **Read:** the cheapest beautification IS the @json-render realignment — wire real Tailwind+shadcn so world's data/form surfaces share `@json-render/shadcn`'s vocabulary; making the dead barrel real satisfies `primitive_coverage_test` with live code + gives @json-render a ready registry. Caveat: pre-1.0; "alignment" = build world's component layer in the shadcn shape @json-render uses, NOT "convert now."

## 7. Build pipeline
Vite lib build → `ezagent_web/priv/static/assets/world/{main.js,world.css}`; `world_module_url` prod (`/assets/world/main.js`) vs dev (`http://localhost:5173/src/main.tsx` + watcher). Hydration via `WorldRenderer` hook → `mountWorld(el,{layout,state,caller,pushEvent,onServerEvent})`. State: server `push_event("world:state"/...)`; client `pushEventTo("world:dispatch",{action,args})` → `Invocation.dispatch` (CapBAC). Friction: deps pinned `latest`; bundle not committed; CSS is one 1657-line file; dead Tailwind tooling.

## Beautification + restructure opportunities (ranked)
1. **Resolve the styling schism** — adopt real Tailwind+shadcn (aligns @json-render, kills dead barrel honestly; requires updating `primitive_coverage_test` + `ezagent_domain_ui` atoms) OR formally commit to `world-*` BEM and delete the shadcn/Tailwind pretense. The half-state is the biggest confusion source. **(adopt-shadcn recommended, @json-render-aligned).**
2. **Make the layout system deliver (or descope it)** — real grid honoring x/w/h cross-route, or drop the "dynamic layout" promise.
3. **Productize the Admin cluster** — real tables/dashboards vs generic DataTable+JSON dumps (cheapest @json-render down-payment).
4. **Fix nav IA** — breadcrumbs/back-nav, workspace switcher, rationalize Identities/Users/Agents triple entry.
5. **Component-pattern consistency** — standardize Button (+ missing size variant + `world-button-primary` rule), unify forms, add dark mode (one `:root` override away).
6. **Tokenize fully + tidy build** — replace hardcoded hex with `--world-*` vars; pin deps; co-locate CSS.

## Open questions for the brainstorm
1. Is "100% shadcn/ui" still the goal, or has world permanently adopted bespoke `world-*`?
2. Does "world becomes a @json-render app" mean the whole console or only data/form surfaces (Conversation/PTY/LayoutEditor stay bespoke)? Synthesis implies the latter.
3. Invest in the layout feature (real grid/cross-route/drag) or descope?
4. Cookie→cap auth bridge — in scope, or keep LV-per-route holding the session?
5. Relationship between `ezagent_domain_ui` atom primitive layer (`primitives.ex`, `*_shell.ex`) and world's React primitives (coupled by `primitive_coverage_test` strings) — is the atom layer the intended source of truth?
6. Pre-1.0 `@json-render` (v0.19.0) acceptable to bet the admin console on?

**Cross-cutting (for #85 world coordination):** the single 1657-line `styles.css` + the single 990-line `WorldLive` + the `primitive_coverage_test` coupling are the highest-collision artifacts for parallel world work — beautification will hammer `styles.css`; new surfaces (agent-console) are more additive.
