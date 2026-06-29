# Design-System Adaptation Audit · 设计系统适配审计

> **Audit date:** 2026-06-28 · **Author:** Claude (frontend-design + ezagent-developer)
> **Design system source:** `/Users/h2oslabs/Workspace/ezagent-design` (entry `styles.css` + bundle `window.EzagentDesignSystem_b8e92c`)
> **App repo:** `/Users/h2oslabs/Workspace/esr-ng` @ `origin/main` (28368df6)
> **Scope:** every user-facing ezagent UI surface — the operator LiveView shell, the auth boundary, the customer/socialware SPA, the world console island, the hello island — measured against the Ezagent design system, plus an integration plan and open questions.

---

## 1. Current-surface inventory

The umbrella runs **five distinct styling regimes** across four rendering modes (LiveView HEEx, raw-HTML controller layout, two React-island flavors, one React SPA). There is **no shared token layer**; each surface defines its own.

| # | Surface | Files | Styling regime | Framework | Build |
|---|---|---|---|---|---|
| **S1** | Operator LiveView shell | `apps/ezagent_web/assets/css/app.css` · `components/layouts/root.html.heex` · `components/layouts.ex` | **Tailwind v4 + daisyUI** (vendored `vendor/daisyui.js` + `daisyui-theme.js`), `dark`+`light` daisyUI themes, heroicons plugin | Phoenix LiveView 1.1 | Hex `:tailwind` 4.1.7 + `:esbuild` 0.25.4 |
| **S2** | Auth boundary (login/register) | `apps/ezagent_web/lib/ezagent_web/auth_boundary_layout.ex` | **Raw inline `<style>`** heredoc — self-contained "design tokens + dark mode" CSS, no `app.css` link, no Tailwind | plain HTML (controllers) | none (inline) |
| **S3** | Customer / socialware SPA | `apps/ezagent_domain_socialware/assets/js/{customer_app,catalog_jsonrender,theme_shell}.mjs` · `controllers/socialware/customer_controller.ex` · `apps/ezagent_web/assets/css/customer.css` | **Tailwind v4 + daisyUI** `customer` light theme; React 19, `@json-render/shadcn` catalog; utility classes inline (`alert alert-error`, `chat chat-start`, `loading loading-dots`) | React 19 (plain `createElement`, no JSX) | esbuild `customer_app.js` + `:tailwind` profile `ezagent_web_customer` |
| **S4** | World console island | `apps/ezagent_plugin_world/assets/src/{styles.css,main.tsx,components/ui/*}` · `assets/js/world_renderer.js` · `lib/.../world_live.ex` | **shadcn/ui on Tailwind v4** — `components.json` (new-york / slate / cssVariables), `class-variance-authority`, `cva` button, own `:root`/`.dark` token block | React **18.3.1** + TS | **Vite** lib mode → `priv/static/assets/world/{main.js,world.css}`; dev server on 5173 |
| **S5** | Hello island | `apps/ezagent_plugin_hello/assets/src/{main,registry,catalog}.{tsx,ts}` · `assets/js/hello_renderer.js` | **Inline React style objects** (deliberately *no* Tailwind/daisyUI — see `registry.tsx` comment) + `@json-render/shadcn` catalog | React 19.2.3 + TS | **Vite** lib mode → `priv/static/assets/hello/main.js` |
| **—** | Shared HEEx primitives | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/{components,primitives}.ex` + `*_shell.ex` | **shadcn-*inspired* HEEx** (hand-written, not the CLI) — zinc palette, `rounded-md`, `shadow-sm`, inline Tailwind utility classes; scanned by `app.css` `@source` | Phoenix.Component | compiled with S1 |

**React integration model (no library):** there is **no `LiveReact`, no `react_phoenix`, no `react_ujs`** in `mix.lock`. Islands are mounted by hand-rolled `phx-hook`s (`WorldRenderer`, `HelloRenderer` in `apps/ezagent_web/assets/js/app.js`) that dynamically `import()` a Vite-built ESM bundle and call a `mountX(el, opts)` export; the world hook also injects a `<link>` to the island's CSS. React is a per-island `package.json` devDep (S4 pins 18.3.1; S3/S5 pin 19.2.3) — **not** a single shared instance.

**Design-system integration status:** grep for `EzagentDesignSystem` / `ezagent-design` / `design_system` across `apps/` returns **zero** code hits on `main`. The only references are in `docs/together/2026-06-24/plan.md` (line 74: "extract design tokens … into one theme layer; json-render components reference tokens, never hardcode styles") and `docs/notes/*`. **No adaptation has started in code.**

---

## 2. Per-surface gap audit

The design system's contract (from `DESIGN.md`, `PRODUCT.md`, `tokens/*.css`, `_ds_manifest.json`):

- **Colors:** De Stijl primaries — `--red #D81830`, `--blueink #0048A8`, `--yellow #FFD400`, `--jade #0FA06E`; single interactive `--blue/--accent #0B5CFF`; warm-gray ground `--ground #E8E8EB`; white `--card #FFFFFF`; ink ramp `--ink #17171B … --ink-4`. **No gradients.** Wash + deep-text pairs for status.
- **Type:** Inter (Latin, 800/500/450) · **Noto Serif SC** (CN headings, 600) · Noto Sans SC (CN UI) · **Space Mono** (data/overlines). Sentence case; ALL-CAPS only for mono overlines.
- **Elevation:** white cards, `--r-lg 22px`, six-layer `--shadow-card`; "edges made of light, not lines" — borders avoided.
- **Radii:** 10/16/22/squircle-18/pill-999. **Buttons, inputs, badges are pills.**
- **Voice:** bilingual `中文 · English` with interpunct; person = 你/you; product = Ezagent.
- **Dark:** `:root[data-theme="dark"]`.
- **Component bundle:** `_ds_bundle.js` is a **global-attach IIFE** (`window.EzagentDesignSystem_b8e92c = …`), not an ES module; each component self-injects its CSS (string → `<style>`) that references the token custom properties.

### S1 — Operator LiveView shell (daisyUI)

| Dimension | Design system | Current (cited) | Gap |
|---|---|---|---|
| Brand color | `--red/--blueink/--yellow/--jade` primaries; cobalt `--accent` | daisyUI `--color-primary` is theme-dependent: **purple** in dark (`oklch(58% 0.233 277)` `app.css:35`), **orange/coral** in light (`oklch(70% 0.213 47.6)` `app.css:70`); `--color-accent` is purple-magenta in dark (`app.css:39`) / black in light (`app.css:74`) | **No De Stijl primaries anywhere.** Primary action color is purple-or-orange (never cobalt). No yellow/jade/vermilion brand axis. |
| Neutral ground | `--ground #E8E8EB` (warm-ish gray), white cards | daisyUI `--color-base-100: oklch(98% 0 0)` = near-white (`app.css:66`); cards == background | Ground is white-on-white, not the gray-ground/white-card lift. No floating-card depth. |
| Interactive color | **One-voice rule:** cobalt is the *only* clickable color | `--color-primary` purple used for buttons/links; `--color-secondary` also purple (`app.css:35-38`) | Multiple interaction colors; violates One-Voice. |
| Shadows | six-layer `--shadow-card`; "borders before lines" forbidden | no custom shadow tokens; daisyUI `--depth:1` (`app.css:57`); `ezagent_domain_ui` explicitly "subtle shadows (shadow-sm)" + "border border-zinc-200" (`components.ex:69,73`) | No floating elevation; structure carried by 1px borders — directly opposite the Light-Edge rule. |
| Radii | 10/16/22 + **pill** buttons/inputs/badges | daisyUI `--radius-box:0.5rem`, `--radius-field:0.25rem` (`app.css:51-53`); HEEx `.button` = `rounded-md` (`components.ex:49`) | No 22px cards, no pills. Tight 4-8px corners everywhere. |
| Type | Inter + **Noto Serif SC** (CN headings) + **Space Mono** | **Geist** + **JetBrains Mono** — `--font-sans:"Geist"`, `--font-mono:"JetBrains Mono"` (`app.css:117-120`); Google Fonts link in `root.html.heex:12-15` | Wrong font families. No CN serif (no Chinese heading voice). No Space Mono. |
| Bilingual | `中文 · English` interpunct; 你/you | English-only labels; `<html lang="en">` (`root.html.heex:2`) | No zh·en voice. |
| Dark theme | `:root[data-theme="dark"]` | **same selector** `data-theme="dark"` (`app.css:102`, `root.html.heex:35`) | ✅ **Compatible** — the dark-mode *selector* already matches. (Values still need swapping.) |
| Gradients | forbidden | `.ez-dot-grid` uses `radial-gradient(...)` for a dot texture (`app.css:139`) | Borderline — it's a dot-grid texture, not a fill gradient. Acceptable as "点彩-adjacent" but worth confirming; no fill gradients found. |

### S2 — Auth boundary (inline `<style>`)

Self-contained raw-HTML layout (`auth_boundary_layout.ex`) with its own inline "design tokens + dark mode" `<style>` block. Same gaps as S1 (no brand colors, no Inter/Noto/Space-Mono, no pills, no floating shadow) **plus** it's a parallel token island — it will need to either link `styles.css` or be rewritten to consume the tokens, ending the duplication.

### S3 — Customer / socialware SPA (daisyUI `customer` theme)

Same daisyUI gaps as S1 (purple primary, no primaries, wrong fonts, `rounded-md`, border-as-edge). Additional:
- **React 19 + `@json-render/shadcn`** renders pages from a JSON spec — the component *catalog* (`catalog_jsonrender.mjs`) is the leverage point: swapping the catalog's styled components for design-system components (or restyling the `@json-render/shadcn` set onto the tokens) propagates to every customer page at once.
- `data-theme="customer"` is a **third** theme name (vs `dark`/`light` on S1) — a 4th styling variant to reconcile.

### S4 — World console island (shadcn/zinc)

| Dimension | Design system | Current (cited) | Gap |
|---|---|---|---|
| Tokens | `--ground/--card/--ink/--accent/--r-lg/--shadow-card` etc. | shadcn `:root` block: `--background:oklch(1 0 0)`, `--primary:oklch(0.208 0.042 265.755)` (slate), `--accent:oklch(0.968 0.007 247.896)` (gray-muted), `--radius:0.625rem` (`styles.css:12-32`) | **Variable-name collision on `--accent` + `--card`** — DS `--accent`=cobalt action color (`tokens/colors.css:48`), shadcn `--accent`=gray hover bg (`styles.css:26`); DS `--card`=white (`:11`), shadcn `--card`=oklch white (`:16`). Both load on world pages → last-wins clobbers silently. (DS does *not* define `--background`/`--foreground`/`--radius`; daisyUI uses the `--color-*` prefix and is disjoint — see §3-B.) |
| Brand color | De Stijl primaries + cobalt | neutral slate/zinc; `--destructive:oklch(0.577 0.245 27.325)`; emerald/red/sky/amber accents in `primitives.tsx` | No brand axis. |
| Radii | 22px cards + **pill** controls | `--radius:0.625rem`→10px; `rounded-md`/`rounded-lg` in `primitives.tsx` | No 22px, no pills. |
| Shadows | six-layer floating | shadcn defaults (`shadow-sm`); `--edge` not used | No floating elevation. |
| Type | Inter + Noto Serif SC + Space Mono | no `--font-*` set (inherits shadcn/Tailwind defaults = system stack) | No brand type; no CN serif. |
| Dark | `:root[data-theme="dark"]` | `.dark` class (`styles.css:10,34`) via `@custom-variant dark` | **Selector mismatch** — world uses `.dark` class; DS + S1 use `data-theme="dark"`. Two dark-mode triggers on one page. |
| Bilingual | zh·en | English-only component copy | No zh·en. |
| React version | (bundle expects React) | **18.3.1** while S3/S5 + DS kits use **19** | Version split — the DS bundle's React expectation must be verified against 18 (see open questions). |

### S5 — Hello island (inline styles + `@json-render`)

Deliberately CSS-framework-free ("inline styles … so the island renders self-contained inside the world LiveView operator shell — which does NOT ship the customer SPA's daisyUI build", per `registry.tsx`). Gaps:
- Inline style objects hardcode colors/sizes — **no token layer at all**; every value is a literal. Hardest to migrate mechanically (no CSS to sed).
- `@json-render/shadcn` is the catalog; same leverage as S3.
- An `island.css` "mirroring shadcn semantic tokens" exists only in worktrees, **not on `main`** — so on `main` there is no shared token file for hello.

### Shared HEEx primitives (`ezagent_domain_ui`)

`components.ex` moduledoc states the design intent verbatim: *"neutral zinc palette … tight border-radius (rounded-md, not rounded-2xl) … subtle shadows (shadow-sm) … semantic color use (primary, success, danger)"* (`components.ex:8-13`). Variants: `bg-zinc-900`, `bg-emerald-600`, `bg-red-600`, `border-zinc-200` (`components.ex:69-86`). **This is the anti-pattern the design system explicitly rejects** (zinc palette, `rounded-md`, `shadow-sm`, borders-as-edge). It is also the single highest-leverage HEEx layer (scanned by `app.css`, used by every LiveView shell), so retargeting it onto DS tokens moves S1 + S2 + the LiveView half of S4 at once.

---

## 3. Integration model — `styles.css` + `window.EzagentDesignSystem` for Phoenix + React islands

The design system ships two artifacts:

1. **`styles.css`** — imports-only entry; pulls `tokens/{fonts,colors,typography,spacing,effects,base}.css`. Defines **only CSS custom properties** (`--ground`, `--accent`, `--r-lg`, `--shadow-card`, `--font-ui`, …) + a `base.css` reset. No component rules.
2. **`_ds_bundle.js`** — a **global-attach IIFE** (`window.EzagentDesignSystem_b8e92c = window.… || {}`) containing 19 React components (Button, Input, Card, Badge, Tabs, Dialog, …). Each component `ensureStyle()`s its own CSS (a JS template string → injected `<style>`) whose selectors are namespaced `.ez-btn`, `.ez-input`, … and which reference the **token custom properties**. So components only render correctly *if the token layer (`styles.css`) is linked first*.

### What this means concretely

**A. Token layer (all surfaces).** Link `styles.css` once per HTML document, in the layout `<head>`, **before** any Tailwind/daisyUI build. For the LiveView shell that's `root.html.heex`; for the customer SPA it's the `customer_controller.ex` heredoc; for the auth boundary, the inline layout. The tokens then flow into every CSS rule and every DS component. Because DS tokens are plain `:root{}` custom properties, they coexist with Tailwind v4 — but see the **collision** caveat below.

**B. The `--accent` / `--card` collision (DS ↔ shadcn only; narrower than it first appears).** Verified: the design system defines bare `--accent` (cobalt, `tokens/colors.css:48`) and `--card` (white, `:11`); shadcn's world `styles.css` defines bare `--accent` (gray-muted, `:26`) and `--card` (`:16`) — **these two names collide** with different values/semantics (DS `--accent` = the action color; shadcn `--accent` = hover bg). daisyUI is **not** a party: it uses the `--color-*` prefix (`--color-accent`, `--color-primary`, …) and defines no bare `--accent`/`--card`/`--background`/`--foreground`/`--radius`. The DS does not define `--background`/`--foreground`/`--radius` either. So the collision is real but **narrow** — DS↔shadcn on 2 tokens, and only on pages where the world island's shadcn stylesheet loads. Resolution options:
   1. **Namespace the DS tokens** — ship the design system under a `:root[data-ez]` or `.ez` scope so DS tokens don't shadow the framework's. DS components already use `var(--accent)` etc., so they'd need that scope on their host. Cleanest but requires a DS-side change.
   2. **Retire the framework token layer** — once a surface is fully on the DS, drop daisyUI/shadcn tokens so there's one `--accent`. This is the end-state; the collision is only a *transition* problem.
   3. **Alias, don't redefine** — point daisyUI `--color-primary` / shadcn `--primary` at the DS tokens (`--color-primary: var(--blue)`) so the frameworks read DS values. Lowest-effort bridge; keeps daisyUI utility classes working.

   Recommended: **(3) during migration, (2) as end-state.** This needs a decision from Allen (open question Q1).

**C. The bundle is a global `<script>` IIFE, not an ESM import.** `_ds_bundle.js:3-5` is `(() => { const __ds_ns = (window.EzagentDesignSystem_b8e92c = …) … })()` — not `import`-able from a Vite ESM island. Each component is wrapped in `try{(()=>{…})()}catch(e){__ds_ns.__errors.push(e)}` and calls bare **`React.createElement(…)`** with **no** `require`/`import`/`window.React`/shim. So: the bundle *loads* without React, but **calling any component throws `ReferenceError: React is not defined`** unless `window.React` exists. A Vite island's React is an ES module scoped to the island — it does **not** populate `window.React`. Therefore:
   - **Global-`<script>` path is unusable for any React surface.** Even on LiveView pages without an island, you'd need a `window.React = React` bridge (which *then* risks a second React instance). Avoid.
   - **Vite React islands (S4/S5) — mandatory:** vendor `components/**/*.jsx` source into the island's Vite build and `import { Button } from '@/ezagent-ds/Button'`. The island's single React compiles them — no global, no second instance, tree-shakeable, typed. **This is not a preference; it is the only sound path.**

**D. React version (world 18 vs others 19).** The DS `.jsx` sources `import React from 'react'` with no version pin in `_ds_manifest.json`. Vendored into a Vite build, they compile against whichever React the island's `package.json` pins — so world (18.3.1) and hello/customer (19.2.3) each compile their own copy. The components are stateless-presentational (no hooks beyond `createElement`), so 18/19 compatibility is likely trivial; gate on a compile before claiming parity.

**E. daisyUI / shadcn removal sequencing.** daisyUI and shadcn aren't just tokens — they ship component *classes* (`btn`, `alert`, `chat`, `card`, `modal`) used across `ezagent_domain_ui` HEEx and the customer SPA JS. You can't delete the plugins until every `btn`/`alert`/`card` class is replaced. So the migration is: **tokens first** (alias daisyUI/shadcn tokens → DS tokens so colors/radii shift instantly), **then** component-class replacement (swap `btn` → DS `Button` / `.ez-btn`), **then** plugin removal.

### Concrete wiring (end-state, website-first)

```
root.html.heex <head>:
  <link rel="stylesheet" href="/assets/ezagent-ds/styles.css">   ← token layer, FIRST
  <link rel="stylesheet" href={~p"/assets/css/app.css"}>         ← Tailwind v4 (daisyUI tokens ALIASED to DS)
  <script defer phx-track-static src={~p"/assets/js/app.js"}>
  ← NO global _ds_bundle.js here — unusable for React (see §3-C).
     DS React components reach islands ONLY via vendored source, not the global bundle.
```

World/hello islands (Vite): vendor `ezagent-design/components/**` into `apps/ezagent_plugin_world/assets/src/ezagent-ds/` and `import` directly; the host layout's linked `styles.css` already provides the tokens document-wide (the island renders inside the LiveView shell and inherits them), so the island's own `styles.css` need not re-`@import` them.

---

## 4. Phased plan

### Phase 0 — Foundations (this week, website-first)
1. Vendor `ezagent-design` into the repo (git submodule or copied `priv/static/assets/ezagent-ds/{styles.css,tokens/*,_ds_bundle.js}` + `components/**` source). Confirm license (Apache 2.0 — fine).
2. Link `styles.css` in `root.html.heex` head, **before** `app.css`.
3. **Resolve the collision** (Q1): alias daisyUI `--color-primary`→`var(--blue)`, `--color-base-100`→`var(--ground)`, `--color-base-content`→`var(--ink)`, etc. in `app.css`. One mechanical pass. Instantly recolors the whole LiveView shell + all `ezagent_domain_ui` HEEx.
4. Swap the font link: Geist+JetBrains-Mono → Inter+Noto Serif SC+Noto Sans SC+Space Mono (Google Fonts URL in `styles.css`'s `fonts.css` already encodes this).
5. Retarget `ezagent_domain_ui/components.ex` variants: `bg-zinc-900`→`bg-[var(--accent)]`, `rounded-md`→`rounded-[var(--r-pill)]`, `shadow-sm`→`shadow-[var(--shadow-card)]`, `border-zinc-200`→remove (use `shadow-[var(--edge)]`). Highest leverage — moves S1+S2+LiveView-half-of-S4.
6. Rewrite `auth_boundary_layout.ex` inline `<style>` to `@import`/link `styles.css` instead of duplicating tokens.
**⚠ Interim hazard (Phase 0 ↔ Phase 2):** linking `styles.css` globally in `root.html.heex` sets DS `--accent`/`--card` document-wide at page load. But the world island (`world_renderer.js` ~line 13) **late-injects** its shadcn `styles.css` (`:root` block, `apps/ezagent_plugin_world/assets/src/styles.css:12-32`) at mount time — that block is **global, not scoped** — and re-clobbers `--accent`/`--card` back to gray **document-wide** on world pages. Between Phase 0 landing and Phase 2 completing, world pages see DS-at-load → shadcn-after-mount (flicker + reverted tokens). **Mitigation:** ship Phase 0's global link + Phase 2's world-island token retarget atomically, OR scope the DS tokens (`.ez`/`data-ez`) until Phase 2 lands, OR defer the global link until Phase 2.
**Gate:** operator shell + auth pages render in brand colors, Inter/Noto/Space-Mono, pills, floating cards. No React changes yet. (World pages may stay off-brand until Phase 2 — acceptable if scoped/atomic.)

### Phase 1 — Customer SPA (parallelizable with Phase 0)
The customer SPA renders from a standalone HTML doc (`customer_controller.ex` heredoc) with its own `customer.css` `<head>` — **not** inside `root.html.heex`. So it has no token-clobber interaction with Phase 0's global link and can proceed in parallel.
7. Alias `customer.css` daisyUI `customer` theme tokens → DS tokens (same aliasing pass as step 3).
8. Restyle the `@json-render/shadcn` catalog in `catalog_jsonrender.mjs` to consume DS tokens (or swap to DS components vendored as ESM). One catalog change → every customer page restyles.
**Gate:** customer/socialware pages on-brand.

### Phase 2 — World island (shadcn → DS)
9. Vendor `ezagent-design/components/**` into the world Vite build; replace `components/ui/{button,primitives}.tsx` shadcn variants with DS components (or retarget the `cva` tokens to DS custom properties).
10. **Resolve the `.dark` vs `data-theme="dark"` split** (Q3): make the world island read `data-theme` from the document (already set by `root.html.heex`'s theme script) instead of a `.dark` class, so dark mode is unified.
11. Resolve React 18→19 (Q2): bump world to React 19 to match S3/S5/DS kits, OR confirm the DS components compile under 18.
**Gate:** world console on-brand; one dark-mode trigger.

### Phase 3 — Hello island (inline styles → DS)
12. Hardest: hello's inline style objects have no token layer. Either (a) introduce `island.css` (the worktree-only file) reading DS tokens and replace inline literals with `var(--…)` references, or (b) migrate the `@json-render` catalog the same way as S3 (shared work with Phase 1).
**Gate:** hello pages on-brand.

### Phase 4 — Cleanup
13. Remove daisyUI plugin + `vendor/daisyui*.js` once no `btn`/`alert`/`card`/`chat` classes remain (grep-gated).
14. Remove shadcn `components.json` + `class-variance-authority` once world primitives are DS-based.
15. Delete the per-surface `:root` token blocks (world `styles.css` shadcn block, auth inline block) — `styles.css` is the single source.

---

## 5. Open questions for Allen

- **Q1 — Collision strategy.** Approve the "alias daisyUI/shadcn tokens → DS tokens during migration, retire them as end-state" approach (§3-B)? Or do you want the DS tokens namespaced (`.ez`/`data-ez`) to avoid ever colliding? Aliasing is lower-effort but means two token vocabularies coexist until cleanup; namespacing is safer but needs a DS-side change.
- **Q2 — (Resolved by code review; recorded for ratification.)** The bundle uses bare `React.createElement` with no React shim (`_ds_bundle.js:60+`), so it requires a global `window.React` and is **unusable for Vite islands** — an ESM-imported React doesn't populate `window.React` → `ReferenceError` at render. **Decision: vendor `components/**/*.jsx` source into each island's Vite build.** Remaining ask: ratify, and confirm the vendored components compile under React 18 (world) as well as 19 — likely trivial (stateless-presentational), gate on a compile.
- **Q3 — Dark-mode selector unification (mechanically trivial — confirming go-ahead).** `root.html.heex:35` already sets `data-theme` via the theme script; the world island can read `document.documentElement.dataset.theme` today. Standardizing on `data-theme="dark"` and dropping the world `.dark`/`@custom-variant dark` convention is a one-liner per island. Confirming the go-ahead, not an open design question.
- **Q4 — Fonts.** The DS ships Inter + Noto Serif SC + Noto Sans SC + Space Mono via Google Fonts CDN (`tokens/fonts.css`). The current shell uses Geist + JetBrains Mono (also Google Fonts). Switching adds 2 CN font families (heavier payload). OK to load all four DS families app-wide, or scope CN fonts to surfaces that render Chinese?
- **Q5 — daisyUI removal timing.** daisyUI component classes (`btn`, `alert`, `chat`, `card`, `modal`) are used across HEEx + customer SPA. Full removal (Phase 4) is gated on replacing every class. Is keeping daisyUI as a *token-only* bridge (alias its theme vars to DS, stop using its component classes) an acceptable intermediate, or do you want it gone ASAP?
- **Q6 — `@json-render/shadcn` vs DS components.** The customer SPA + hello render pages from a JSON spec via `@json-render/shadcn`. Should the catalog be (a) restyled onto DS tokens (keep `@json-render/shadcn`, just retarget its CSS), or (b) replaced with the DS's own React components as the `@json-render` catalog? (a) is less churn; (b) gives the pill/floating-shadow component behavior for free.
- **Q7 — `.ez-dot-grid` radial-gradient (low-priority, likely a non-issue).** `app.css:139` is a 1px-dot *texture* (transparent gaps), not a fill gradient. DESIGN.md §6's No-Gradient rule targets gradient *fills*; a dot pattern is adjacent to the DS's own ColorPoints ("scattered solid color-dots"), not to a banned fill. Likely acceptable as-is; revisit only if it reads as noise on a brand surface.
