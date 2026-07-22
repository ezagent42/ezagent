# Plugin UI-surface architecture — research + design

> **Research + design doc** (2026-07-19). Establishes how a plugin should
> contribute UI (page / nav / session-tab / actions) **without editing
> `world`**. Grounds the recommendation in (a) the in-repo state — every code
> claim is `file:line`-verified per the project's "doc WHY must be
> code-verified" norm — (b) industry practice (VS Code, Backstage, Grafana,
> Obsidian, micro-frontend loaders), and (c) the socialware philosophy
> (ONE Kind + composable behaviors, self-declaration, plugin isolation,
> fail-closed, truth-in-plugin-not-host). **No code is written by this doc.**
>
> **On the referenced proposal (PR #1468 / `ui-surface-provider.md`):** that
> file does **not** exist in-repo, and `#1468` is not in git history. The real
> current substrate is **#1117** (`62820c38d` — "World-side plugin UI-surface
> substrate"). This analysis is grounded in the #1117 code + the #1117-era
> design doc (`board-entry-and-modular-ui.md`, commit `d9b939f73`), NOT in a
> proposal doc. Allen should reconcile the #1468 reference against this.

---

## 0. TL;DR

- **X problem.** `world` (itself just a plugin — `apps/ezagent_plugin_world`)
  conflates three responsibilities that want to be separate layers:
  **(a) plugin loading/registration**, **(b) rendering** (components +
  routing + action admission), **(c) hosting** the plugin's React components
  inside world's own esbuild bundle. A plugin that wants a UI must edit world
  in **4 places**. `kanban` pays this tax; `hello` is worse — it is
  hand-special-cased and not even in the registry.
- **Recommendation: the HYBRID** — a **data-described assembly graph**
  (Approach A) in which **"slot"/"anchor" is a first-class node kind in the
  grammar** (Approach B's ergonomics), so the shell never owns a fixed *enum*
  of positions. One line of why: it is the only option that keeps
  **truth-in-plugin** (A) *and* gives the plugin a stable place to attach (B)
  **without the shell re-owning "what positions exist"** — and it is the
  minimal delta from what #1117 already built (`PluginPageRegistry` +
  `SlotRegistry` + `UiSurfaceProvider` are already a partial A).
- **Bundle-loading — v1 is build-time enumeration, not a runtime loader.**
  A generated barrel/manifest, produced by enumerating
  `Ezagent.PluginRegistry.list_all/0`, writes the imports +
  `PLUGIN_PAGE_RENDERERS` entries that are hand-edited today. Pure static
  esbuild; **no new runtime**. Runtime dynamic-`import()` + **import maps**
  (over Module Federation) is a **gated later optimization** for hot-install /
  independent deploy — deferred exactly the way the frontend-islands spec
  deferred compile-to-page.
- **Drift-prevention gate** — *extends* the three existing enforcers
  (`slot_mount_gate_test.exs`, `PluginPageRegistry.by_action/1`,
  `plugin_page_registry_test.exs`). The **new tooth**: a
  **plugin-name-literal** check — world source must contain **no** `"kanban"`
  / `"hello"` / `KanbanData` / `KanbanActions` literal. Allowlist starts
  non-empty (kanban + hello) and shrinks to `[]` as touch-points migrate; the
  empty-allowlist **red build names every remaining hardcoded touch-point.**
- **Top open decision for Allen:** shell = **demote `world` in place** (world
  becomes the thin enumerator) vs **extract a new `ezagent_plugin_shell` layer
  below world**. Recommendation: demote-in-place (YAGNI / strangler);
  extract only if a second full-app peer to world ever appears.

---

## 1. The X problem, precisely

`world` is **not special** — it is one plugin among 25 apps
(`apps/ezagent_plugin_world`, peer to `ezagent_plugin_kanban`,
`ezagent_plugin_hello`, …). Yet it has quietly become the **UI host** that
every other plugin's UI must be threaded through. Three responsibilities are
fused inside it:

| Responsibility | What it should be | How world fuses it today |
|---|---|---|
| **(a) Loading / registration** | "which plugins exist" — a catalog | Correctly delegated: `Ezagent.PluginRegistry.list_all/0` (core) is the SoT. ✅ |
| **(b) Rendering** — components + routing + action admission | a data-described mapping from *what a plugin declares* → *how it is placed/dispatched* | Fused into **world-owned, world-hardcoded** registries (`PluginPageRegistry`, `SlotRegistry`) + a **world-hardcoded** React switch. ❌ |
| **(c) Hosting** — the plugin's components live in a bundle | the plugin ships its own pixels | The plugin's `.tsx` files **live inside world's `assets/src/components/`** and are **statically imported by world's `main.tsx`**. ❌ |

**The 4 edits to land one plugin UI (pinned to `file:line`, kanban as the
worked example):**

1. **Server registry (Elixir, in world).**
   `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex:30-43`
   — add a `@pages` entry (route + `detail_route` + `nav` + `data_builder` +
   `renderer_families` + `action_prefixes` + `actions` + `actions_module`),
   **and** the per-plugin action allowlist at
   `plugin_page_registry.ex:28` (`@kanban_actions` — the literal `kanban.*`
   allowlist, 20 actions).
2. **Slot registry + regenerated manifest (Elixir SoT + generated JSON, in
   world).** `Ezagent.World.SlotRegistry` → regenerate
   `apps/ezagent_plugin_world/assets/src/slots.manifest.json`
   (the kanban slot at `slots.manifest.json:67-72`) via `mix world.slots.manifest`.
3. **Frontend registry (world's `main.tsx`).**
   `apps/ezagent_plugin_world/assets/src/main.tsx:11`
   (`import {Kanban} from "./components/Kanban"`),
   `main.tsx:916-930` (the `PLUGIN_PAGE_RENDERERS` literal entry), **and**
   `main.tsx:33` (`FULL_BLEED_FAMILIES` set literally contains `"kanban"`).
4. **Ship the component into world's bundle.**
   `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx` +
   `KanbanCanvas.tsx` physically live in **world's** asset tree and are built
   by **world's** esbuild.

**`hello` is the canonical anti-pattern — strictly worse than kanban.** It is
not even in the registry; it is hand-special-cased:

- `apps/ezagent_plugin_world/assets/src/main.tsx:14` imports `WorldHello`;
  `main.tsx:467-470` renders `<WorldHello>` as the **fallthrough** when no
  layout components match.
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:225`
  `const isHelloSession = state.is_hello === true || sessionUri.includes("/hello/")`
  — a hardcoded string sniff — gates a `"page"` tab
  (`Conversation.tsx:219-225, 746, 948`). The #1117-era design
  (`board-entry-and-modular-ui.md §2`) names this verbatim:
  > 反面教材（要消灭，不要复制）：现有 session 的 `"page"` tab 是**为 hello
  > 硬塞**的临时 tab … kanban **不该再硬塞第二个**。

So the problem is not merely "4 edits" — it is that **the host holds
plugin-specific truth** (component names, action strings, position flags, and
a session-type string sniff), which is precisely what the socialware
philosophy forbids (truth-in-plugin-not-host). Every new plugin UI deepens the
host's coupling to specific plugins.

---

## 2. Current state is a *partial* solution — credit what #1117 built

The task is **not** greenfield. #1117 already moved the codebase halfway to
Approach A, and any recommendation must build on it, not re-derive it:

- **`Ezagent.World.UiSurfaceProvider`**
  (`apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`) — a
  **duck-typed self-declaration** convention: a plugin defines a plain
  `nav_surfaces/0` / `session_tabs/0`; world reads them by *enumerating
  installed plugins* and guarding with `function_exported?/3`, so a plugin
  carries **no compile dependency on world** (`ui_surface_provider.ex:20-41`).
  Enforcement is **read-time + fail-closed**: `valid_nav_surface?/1` /
  `valid_session_tab?/1` skip malformed entries rather than crash the UI
  (`ui_surface_provider.ex:88-124`).
- **`WorkspacePluginData.plugin_nav_surfaces/0` +
  `plugin_session_tabs/1`** (`workspace_plugin_data.ex:496-554`) — the generic
  enumerate-and-serialize path; "没插件就没入口" is already true for **nav**.
- **`PluginPageRegistry`** (`plugin_page_registry.ex`) — a
  **data-described** page = one row (route + data-builder + action allowlist +
  renderer key). `world_live.ex:649` loops `PluginPageRegistry.pages()` to
  generate per-page `state_for_route/3` clauses; `world_live.ex:275` routes
  dispatch through `by_action/1` (fail-closed admission,
  `plugin_page_registry.ex:88-96`).
- **`SlotMountGateTest` + `SlotRegistry`** — a **typed-slot gate**: the React
  renderer dispatches purely on a slot's `renderer_family` and **throws** on an
  unregistered type (no silent fallback) — `main.tsx:36-45, 1027-1031`, gate at
  `slot_mount_gate_test.exs`.

**What #1117 left fused (the actual gap):** the registries are **compile-time
constants that live in world** and are **hand-edited per plugin**
(`plugin_page_registry.ex:22` literally says
"编译期常量起步；插件自声明协议（`UiSurfaceProvider` 扩展）留给 follow-up"),
the **frontend renderer + component hosting** are entirely world-owned
(edits 3 + 4 above), and **`page`/`hello` never made it into the mechanism at
all**. This doc designs that follow-up.

---

## 3. Industry practice (how mature systems self-register UI + isolate + allowlist)

| System | Registration model | Isolation | Allowlist / security | Loading | What we take |
|---|---|---|---|---|---|
| **VS Code** — contribution points | **Declarative JSON** in `package.json > contributes`; host reads the manifest at startup and prepares UI. UI is *declared*, not imperatively mounted. | Extension host is a **separate process**; extensions **cannot touch the workbench DOM**; webviews run in a **randomly-generated sandboxed URL**. | The manifest *is* the allowlist — only declared contributions are honored. | Lazy `activationEvents`. | **Declaration = data, read by the host; the host owns placement, the extension owns intent.** This is Approach A/B's shared core. |
| **Backstage** — frontend extension tree | Plugins call `createFrontendPlugin` and provide **extensions**; each extension **attaches to a parent** and may have children; the app wires all into **one extension tree**. Attachment points are themselves extensions. | JS-level (single bundle), но structural: an extension only sees its parent's data. | `extensionOverrides` (high-priority replace); inputs are typed. | Build-time (app is composed at build). | **≈ Approach A with slot-as-primitive** — positions ("attachment points") are *nodes in the tree*, not a fixed host enum. This is the hybrid, proven at scale. |
| **Grafana** — UI extension points | Host (or a plugin) declares an **extension point id** (e.g. `grafana/dashboard/panel/menu`); plugins **register** links/components to that id via `configureExtension*`. If both are installed, wiring is automatic — "no need for either app to include custom logic." | Plugin panels are sandboxed; the host **decides how to display** registered content. | Registration keys on a **known extension-point id** — unknown ids render nothing (fail-closed). | Runtime (plugins load as separate bundles). | **≈ Approach B (pure slots)** — clean ergonomics, but the **host owns the fixed set of extension-point ids**; a genuinely new position requires a host change. |
| **Obsidian** — plugin API | Imperative `this.addRibbonIcon` / `registerView`. | **None** — plugins inherit full app + filesystem access; "Restricted Mode" is a trust gate, not a sandbox. | Trust-based; community `Safe JS` retrofits a Web Worker sandbox. | Runtime. | **Cautionary tale** — no declaration + no isolation = no fail-closed. The opposite of what we want. |
| **Micro-frontend loaders** (Module Federation / import maps / single-spa / Web Components) | Runtime module boundaries. **Module Federation**: webpack host loads a remote manifest, "solves management not just loading," best at *org scale / hundreds of MFEs / independent deploy.* **Import maps**: a **web-platform primitive** (HTML spec, ~94.5% support), *no lock-in, no runtime overhead* — "solves loading, not management." **single-spa**: app lifecycle (mount/unmount), best for *multi-framework* coexistence. **Web Components + native `<slot>`**: browser-native content projection; framework-agnostic custom elements. | Varies; iframe/WC give the hardest boundary. | The host's registry of remotes/import-map entries is the allowlist. | **Runtime.** | **Loading choice only** (§5). MF is webpack-coupled + "management" complexity we don't need for a single-release umbrella; import maps are the right *runtime* tool **if/when** hot-install is required. |

**Two cross-cutting lessons:**

1. The systems that scale (VS Code, Grafana, Backstage) all make **the
   declaration a piece of data the host reads** — never imperative code the
   host must be edited to accommodate. Obsidian's imperative + no-isolation
   model is the one nobody recommends.
2. **Runtime module-loading (MF/import-maps) is orthogonal to
   self-registration.** You can have full self-registration with **build-time**
   bundling (Backstage does). Runtime loading is only *required* when plugins
   deploy independently of the host — which an Elixir umbrella compiled into
   one release does not.

---

## 4. The two approaches vs the socialware philosophy — scored

The philosophy (from `docs/superpowers/specs/2026-06-09-socialware-substrate-design.md`
and the project MEMORY north-stars):

- **P1 — ONE Kind + composable behaviors, instance-set-driven.** One Kind
  carries many apps; every enumeration/callback routes through the *declared*
  set; an out-of-set behavior never runs (fail-closed by construction).
- **Self-declaration.** The plugin declares what it contributes; the platform
  never edits or filters the declaration (mechanism implements declaration).
- **Plugin isolation.** "devs work on plugins without coordination; DI
  everywhere." A plugin must not compile-depend on the host.
- **Fail-closed.** Unknown/undeclared = nothing, never a permissive default.
- **Truth-in-plugin-not-host.** The host holds no plugin-specific truth.

### Approach A — "world = one composition (a data-described assembly graph)"

World is not special; it is *one* data-described assembly of components. Adding
a plugin UI = adding rows of data that some enumerator composes.

| Criterion | Score | Why |
|---|---|---|
| ONE-Kind / composable | **Strong** | The assembly graph *is* the composition; world is one graph among possible graphs — directly the P5 "one Kind, Templates differ" shape. |
| Self-declaration | **Strong** | Rows are declared by the plugin, enumerated by the host. |
| Plugin isolation | **Strong** | Enumeration + `function_exported?/3` ⇒ no plugin→host compile arrow (already true for nav). |
| Fail-closed | **Strong** | Unregistered key/route/action ⇒ `nil` (already `plugin_page_registry.ex:21`). |
| Truth-in-plugin | **Strong** | Host holds only the enumeration machinery. |
| **Ergonomics** | **Weak** | "Assembly graph" under-specifies **where** a component attaches. Without a placement vocabulary, every plugin invents ad-hoc `placement: {x,y,w,h}` — a new kind of drift. |

### Approach B — "slot-based shell (fixed slots: header/footer/nav/tab/page)"

The shell defines a fixed set of named slots; plugins declare which slots they
fill. This is Grafana's model.

| Criterion | Score | Why |
|---|---|---|
| ONE-Kind / composable | **Medium** | Slots compose, but the *slot set* is a host-owned schema, not itself composable. |
| Self-declaration | **Strong** | "I fill slot `nav` with X" is a clean declaration. |
| Plugin isolation | **Strong** | Declaration keys on a slot id; no compile arrow. |
| Fail-closed | **Strong** | Unknown slot id ⇒ nothing (Grafana-proven). |
| Truth-in-plugin | **Medium** | The plugin's *content* is truth-in-plugin, but **"what positions exist" is truth-in-host.** A new position type = a **shell edit** → the host re-accumulates authority. This is a softer version of the original X problem. |
| **Ergonomics** | **Strong** | Best DX; the industry default (VS Code menus, Grafana extension points). |

### The HYBRID — slot/anchor as a *node kind inside* A's assembly graph

Keep **A's data-described assembly graph as the single source of truth**, and
make **"slot"/"anchor" one declared node kind in that graph's grammar** (B's
ergonomics). Crucially: **positions are themselves data in the assembly**, not
a fixed enum the shell owns. A plugin declares `{anchor: "left-rail", fill:
nav_surface}`; the *anchor* `left-rail` is itself a row another composition
declared — the shell ships a *default* composition (with the familiar
left-rail / conversation-tab-bar / page-outlet anchors) but owns no closed set.
Adding a genuinely new position = adding an anchor row, **not** editing the
shell's schema.

| Criterion | Score | Why |
|---|---|---|
| ONE-Kind / composable | **Strong** | Anchors are composable rows; the shell's layout is just the default composition. |
| Self-declaration | **Strong** | `{anchor, fill}` is a clean declaration; both sides are data. |
| Plugin isolation | **Strong** | Same enumeration + `function_exported?/3`; no compile arrow. |
| Fail-closed | **Strong** | Unknown anchor ⇒ nothing; unknown fill type ⇒ throw (existing `SlotRegistry` behavior). |
| Truth-in-plugin | **Strong** | The host holds **neither** content **nor** the position enum — both are data. Fixes B's soft leak. |
| Ergonomics | **Strong** | A plugin still just says "fill this named anchor" — B's DX, without B's shell-owns-positions cost. |

**This is Backstage's proven model** (extension tree where attachment points
are themselves extensions) and it is **the minimal delta from #1117**:
`PluginPageRegistry` rows *are* assembly rows; `SlotRegistry` families *are*
the fill-type vocabulary; `UiSurfaceProvider` *is* the self-declaration path.
The hybrid just (i) unifies them into one grammar with an explicit `anchor`
node kind, (ii) moves the rows from world-hardcoded to plugin-self-declared,
and (iii) folds `page`/`hello` into it.

**Recommendation: the HYBRID.** One-line why: *it is the only option that keeps
both truth-in-plugin (content **and** positions are data, not host schema) and
B's "just fill a named anchor" ergonomics — and it is the smallest step from
what #1117 already shipped.*

---

## 5. Sketch of the recommended design

### 5.1 The 4-surface self-declaration protocol

A plugin contributes UI by declaring (duck-typed, no world compile-dep — the
#1117 `UiSurfaceProvider` pattern, extended):

1. **`page/0`** — `[%{key, route, detail_route, anchor, fill, data_fn}]`.
   Replaces the hand-added `PluginPageRegistry.@pages` row. `key` is the
   component key (route ↔ renderer ↔ data). `anchor` names where it mounts
   (default composition provides `page-outlet`, `left-rail`,
   `conversation-tab`). `fill` names the renderer family (existing
   `SlotRegistry` vocabulary). `data_fn` is the read-model module (today's
   `data_builder`).
2. **`actions/0`** — `%{prefix => [action]}` — the **fail-closed action
   allowlist**, declared *by the plugin*, not stored as world's
   `@kanban_actions`. Admission stays "prefix is coarse, action is the fine
   allowlist, prefix hit still per-action-checked"
   (`plugin_page_registry.ex:88-96`) — but sourced from the plugin.
3. **`nav_surfaces/0` / `session_tabs/0`** — **already exist** (`UiSurfaceProvider`);
   fold them under the same `anchor` grammar (`left-rail`, `conversation-tab`).
4. **`render` (frontend declaration)** — the plugin ships its own
   `assets/src/*` component keyed to `key`; a **build-time enumerator**
   (§5.2) wires it into the bundle. No `main.tsx` edit.

All four are **read-time validated + fail-closed** (extend
`valid_nav_surface?/1` shape gates to `valid_page?/1`, `valid_action_set?/1`).

### 5.2 Runtime bundle-loading choice — **v1 = build-time enumeration**

**Decision: build-time codegen enumeration. No runtime loader in v1.**

- A `mix` task (peer to today's `world.slots.manifest`) enumerates
  `Ezagent.PluginRegistry.list_all/0`, reads each plugin's `page/0` + component
  entrypoint, and **generates** the artifacts that are hand-edited today: the
  `import` lines, the `PLUGIN_PAGE_RENDERERS` map, the `FULL_BLEED_FAMILIES`
  membership, and the merged `slots.manifest.json`. esbuild then bundles the
  result exactly as now. **Adding a plugin UI = 0 edits to world**; the build
  enumerates.
- **Why not import maps / Module Federation in v1?** Everything compiles into
  **one release**; there are no bare specifiers left to resolve at runtime, so
  import maps buy *nothing* today, and code-splitting via dynamic `import()`
  is a build-time esbuild feature that needs no map. Module Federation is
  webpack-coupled (the project uses esbuild) and solves "management, not just
  loading" — overkill for a single-release umbrella. This also honors the
  frontend-islands spec's **拍板'd "no runtime Node tier / SSR is a non-goal"**
  decision (`2026-06-19-frontend-islands-architecture-design.md §8, §10`).
- **Deferred (gated, not silently scoped out):** **runtime dynamic-`import()`
  + import maps** (over Module Federation) is the correct tool **iff** hot-install
  / independent plugin deploy becomes a real requirement — each plugin ships
  its own ESM bundle to `priv/static`, resolved by an import map keyed on
  `key`. Framed exactly like the islands spec framed compile-to-page: a later
  optimization behind its own decision gate, not v1 work.

### 5.3 World's demotion to a thin enumerating shell

- World keeps: the app shell chrome (header/nav frame), the LV socket, the
  `pushEvent → handle_event → Ezagent.Invocation.dispatch` boundary (the
  islands-spec crux, unchanged), and the **enumeration machinery**.
- World loses: every **plugin-specific literal** — `@kanban_actions`, the
  `PLUGIN_PAGE_RENDERERS` kanban entry, the `FULL_BLEED_FAMILIES` `"kanban"`
  membership, the `isHelloSession` sniff, the `WorldHello` fallthrough.
- Shell = **demote world in place** (recommended, §7-Q2), not a new layer:
  world *becomes* the thin enumerator. The static `PRIMARY_NAV_ITEMS`
  (`world_ia.js:1-6`, Chat/Agents/Manage/Overview) stays as world's **own**
  `nav_surfaces/0` declaration — world is just the plugin that happens to own
  the default composition, consistent with "world is not special."

### 5.4 Session-page lifecycle hooks — **subsume `isHelloSession` (explicit deliverable)**

This is not a footnote; collapsing the `page`/hello special-case is a
motivating goal (`board-entry-and-modular-ui.md §2`).

- Today: `session_tabs/0` mechanism exists for kanban's tab (visibility via a
  per-session `condition` predicate, `workspace_plugin_data.ex:540-554`), but
  hello's `page` tab is **hand-wired** in `Conversation.tsx:219-225` and never
  went through it — hello is *worse off than kanban*.
- Design: hello declares `session_tabs/0 => [%{id: "page", label: …, condition:
  &Hello.session_page?/1}]` and ships its own page renderer keyed to that tab.
  The `condition` predicate replaces the `state.is_hello ||
  sessionUri.includes("/hello/")` string sniff. "Add a session page tab" then
  means "a plugin declares a `session_tab` + condition" — **never** "edit
  `Conversation.tsx`."
- **Lifecycle hooks** the tab mechanism needs (all per-session, fail-closed):
  `condition(session_uri) -> bool` (visibility — exists), `mount(session_uri)`
  / `unmount(session_uri)` (subscribe/teardown for a stateful page), and the
  existing dispatch path for its actions. A predicate that raises ⇒ "not
  visible" (already the `session_tab_visible?` fail-closed rule).

---

## 6. Companion drift-prevention gate (REQUIRED)

**Frame: this extends three existing enforcers; only tooth #4 is net-new.**
Existing: `slot_mount_gate_test.exs` (static source enumerator — single mount
point, family parity, throw-on-unknown), `PluginPageRegistry.by_action/1`
(fail-closed action admission), `plugin_page_registry_test.exs` (equivalence
lock: registry actions ≡ literal clauses). Model both the *positive-control +
negative-carve-out* discipline of `no_surface_read_dispatch_detector_test.exs`
and the *source-enumerator* discipline of `slot_mount_gate_test.exs`.

The new gate (`plugin_ui_self_declaration_gate_test.exs`) asserts four things:

1. **No plugin UI registered by editing world — the plugin-name-literal check
   (NEW TOOTH).** World source (`plugin_page_registry.ex`, `main.tsx`,
   `Conversation.tsx`, `slots.manifest.json`) must contain **no plugin-name
   literal**: no `"kanban"` / `"hello"` string, no `Ezagent.World.KanbanData` /
   `KanbanActions` module ref, no `isHelloSession`. Enforced against an
   **allowlist of known-still-hardcoded touch-points** that **starts non-empty**
   (the kanban + hello `file:line`s in §1) and shrinks to `[]` as each migrates.
   **The empty-allowlist red build names every remaining hardcoded touch-point**
   — the exact requested behavior: it is a live inventory of the debt, and it
   goes green only when world holds zero plugin-specific truth.
2. **No action served without a plugin declaration (fail-closed).** Scoped to
   actions **routed through the plugin-page admission path** (`by_action/1` or
   its successor) — *not* world's own core actions (`session.create`,
   `sessions.join`, `agents.create`, …), which reach dispatch through dedicated
   `handle_event` clauses and are out of this gate's scope. On that path,
   admission returns non-`nil` **only** if some *installed plugin* declared the
   action via `actions/0`. A synthetic
   **undeclared** action ⇒ `nil` (denied); a **declared** action ⇒ its plugin
   (positive control). No prefix-only pass-through (prefix hit is still
   per-action-checked).
3. **Detectors are not vacuous (positive control + negative carve-out).**
   Mirror the read-dispatch detector test: assert the literal-probe *matches* a
   synthetic `import {Kanban}` / `PLUGIN_PAGE_RENDERERS: {kanban:` fixture, and
   does **not** over-match world's own legitimate chrome (e.g. `WorkspaceSwitcher`,
   the generic `sessions`/`conversation`/`admin` families that are world's own
   surfaces, not plugin contributions).
4. **Registration is enumeration-derivable.** Assert the full page/nav/tab/action
   set is reproducible purely from `PluginRegistry.list_all/0` +
   `function_exported?/3` — i.e., a plugin that is *uninstalled* contributes
   *nothing* to any surface ("没插件就没 UI"), proving the host adds no
   plugin-specific truth of its own.

Gate #1's allowlist is the migration tracker: it is red-with-inventory until
world is a pure enumerator, then permanently green (regression lock).

---

## 7. Open decisions for Allen

1. **Bundle-loading选型.** Recommendation: **build-time enumeration for v1**
   (codegen barrel/manifest from `PluginRegistry.list_all/0`; no runtime
   loader), with **runtime dynamic-`import()` + import maps** (over Module
   Federation) **deferred behind a hot-install decision gate**. *Decision:
   accept the v1/deferred split, or is hot-install a v1 requirement that forces
   the runtime loader now?* Tradeoffs: build-time = zero new runtime, honors the
   islands-spec "no Node tier" 拍板, but plugin UI changes need a world rebuild;
   runtime = independent deploy + hot-install, but adds a loader + the
   management/versioning/fallback surface MF/import-maps carry, and reopens the
   "young dependency / one seam" risk the islands spec worried about.
2. **Shell = demote `world` in place vs a new `ezagent_plugin_shell` layer
   below world.** Recommendation: **demote in place** (world becomes the thin
   enumerator; YAGNI + strangler-consistent — no new app until a second
   full-app peer to world exists). *Decision: in-place, or pay for the extra
   layer now to make "world is just a plugin" structurally undeniable?*
3. **Align with #1394 Entity two-direction-caps?** *Hypothesis to rule on (NOT
   designed here — grounded only in the MEMORY summary of #1394, not its
   source):* model a UI-surface declaration as an **OUTBOUND** decision the
   plugin makes (authoritative "what I contribute"), reconciled by the shell as
   **INBOUND** held-surfaces (a reconcile-only projection) — i.e., UI
   registration becomes a cap, not just a duck-typed function, unifying it with
   the caps substrate and giving fail-closed admission a cryptographic spine.
   *Decision: is UI-surface-as-cap in scope for this line, or kept as the
   lighter duck-typed self-declaration for now?* Recommendation: **keep
   duck-typed for v1, flag the cap-alignment as a follow-up** once #1394 lands —
   verifying #1394 from source is out of scope for this question.

---

## 8. Cross-references (all `file:line` code-verified)

- Existing substrate (#1117): `apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`,
  `.../plugin_page_registry.ex`, `.../workspace_plugin_data.ex:496-554`.
- Frontend host: `apps/ezagent_plugin_world/assets/src/main.tsx`
  (`:11,14,33,467-470,916-930,1021-1031`), `.../components/Conversation.tsx:219-225`,
  `.../assets/src/slots.manifest.json`, `.../assets/js/world_ia.js:1-6`.
- Routing / dispatch: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:55-65,269-275,646-661`.
- Gates to mirror/extend: `apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs`,
  `.../plugin_page_registry_test.exs`,
  `apps/ezagent_core/test/invariants/no_surface_read_dispatch_detector_test.exs`.
- Frontend architecture (拍板 constraints): `docs/superpowers/specs/2026-06-19-frontend-islands-architecture-design.md`
  (§3 layering, §4 phx-hook→dispatch crux, §8/§10 no runtime Node tier).
- Socialware philosophy: `docs/superpowers/specs/2026-06-09-socialware-substrate-design.md` (P1/P5).
- #1117-era design (the `page`/hello "反面教材"): `board-entry-and-modular-ui.md` (git `d9b939f73`,
  `docs/discuss/2026-06-26-kanban-flow-redesign/board-entry-and-modular-ui.md`).

### Industry sources

- VS Code contribution points / manifest / security: <https://code.visualstudio.com/api/references/contribution-points>,
  <https://code.visualstudio.com/api/references/extension-manifest>,
  <https://vscode-docs.readthedocs.io/en/stable/extensions/our-approach/>
- Backstage frontend extension tree: <https://backstage.io/docs/frontend-system/architecture/index/>,
  <https://backstage.io/docs/frontend-system/architecture/plugins/>
- Grafana UI extensions / extension points: <https://grafana.com/developers/plugin-tools/how-to-guides/ui-extensions/ui-extensions-concepts>,
  <https://grafana.com/developers/plugin-tools/how-to-guides/ui-extensions/register-an-extension>
- Obsidian plugin security (cautionary): <https://obsidian.md/help/plugin-security>
- Micro-frontends — MF vs import maps vs single-spa vs Web Components:
  <https://feature-sliced.design/blog/micro-frontend-architecture>,
  <https://single-spa.js.org/docs/recommended-setup/>,
  <https://www.mercedes-benz.io/blog/2023-01-05-you-might-not-need-module-federation-orchestrate-your-microfrontends-at-runtime-with-import-maps>,
  <https://zephyr-cloud.io/blog/module-federation-vs-native-esm>
