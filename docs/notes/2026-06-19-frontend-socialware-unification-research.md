# Frontend research: should LiveView be replaced to make ezagent-admin "a socialware"?

**Date:** 2026-06-19 · **Requested by:** Allen (research-only, before deciding) · **Status:** research; no implementation.

**Question (Allen's framing):** ESR has three layers — backend (`ezagent`) / business-logic
(`json-render`) / rendering (today LiveView for admin + React for the socialware customer
surface). If the rendering layer unifies on one mature JS framework (Next.js / React / Astro)
consuming `json-render`, then `ezagent`'s own admin UI could be developed **as a socialware**
(same stack as the customer apps), to support **socialware loom**.

## Recommendation

**The thesis does not hold — and ESR's socialware design already decided against it.** Keep
**LiveView for admin/internal**; keep **React + json-render for the agent-generated customer
surface**. This is the deliberate **dual-surface** decision locked in
`docs/superpowers/specs/2026-06-07-socialware-design.md` rev8 (§4.4): "operator/admin =
LiveView; customer = React + json-render SPA … unlocks arbitrary generated UI, **which
LiveView cannot**." The two surfaces serve two different needs on purpose.

If any JS frontend is adopted, it is **plain React-SPA** (extending the existing
esbuild/Phoenix-Channel/signed-token precedent), **not Next.js** (the named lead is the
weakest fit — SSR/RSC need a second runtime; SEO/SSR value ≈ 0 for an authed real-time admin),
and not Astro (wrong product shape).

## The crux: json-render is display-only (cannot express an admin UI)

`apps/ezagent_domain_socialware/assets/js/json_render.mjs` (145 LOC) is a recursive
`{type, props, children}` renderer with a 5-entry registry: `container`, `text`, `table`,
`code` (Sandpack), `__unknown`. The operator mirror (`page_view.ex`) supports fewer. There is
**no `input` / `form` / `on:` / event / action / mutation node**.

The admin UI needs the opposite: server-validated form round-trips, mutations (cap grants,
routing-rule add/delete, agent/template config), live tables (authz audit), member panels, and
the **xterm PTY terminal**. None are expressible as a display tree. Extending json-render to
cover them = rebuilding **loom** (the page-builder DSL: 41 components, RFC-6902 patch,
bindings/methods/events — `docs/superpowers/specs/2026-05-28-plugin-loom.zh_cn.md`), which is
**not even in esr-ng**.

**Why it shouldn't be extended (the deeper reason):** json-render exists so **agents generate
UI at runtime** (the customer page is composed turn-by-turn by the orchestrator). The admin UI
is **human-authored by ezagent devs**. Forcing hand-authored, mutation-heavy admin through a
declarative JSON DSL is strictly worse DX than HEEx/React. The honest cost of "admin as
socialware": rebuild ~15,500 LOC of mature admin (36 LiveView files) as json-render trees +
build loom-grade machinery — for worse DX. The gap is the entire event/action/input layer plus
a builder, not a small extension.

## Key correction: the UI-agnostic contract is `/api/v1`, not json-render

The framework-agnostic layer already exists, and it is the dispatch API, not json-render:
- `GET /api/v1` — catalog of `{kind, action, behavior, interface}` from `BehaviorRegistry`.
- `POST /api/v1/:kind/:action` — invoke any registered Behavior action (JSON args),
  **CapBAC-enforced** (`Authorization: Bearer esr_pat_…` + `X-Ezagent-Entity-URI` →
  `Entity.authenticate` → `Invocation.dispatch` with `ctx.caps`). Any plugin Behavior gets an
  HTTP endpoint for free.
- The `lv_cli_parity` invariant: every LV `handle_event` already has a `mix esr` CLI
  equivalent — the backend is *already proven* drivable without LiveView.

`json-render` is one narrow projection for the customer surface — not the universal contract.

## Corrected premises
- **"#65 CF Workers weighs heavily"** — inside esr-ng "#65" is Decision #65 (a SpawnRegistry
  invariant), unrelated to Cloudflare; the CF item is a cross-repo note and the tunnel was
  deferred. Regardless of frontend, the backend stays an **always-on BEAM** (Channels / PubSub
  / PTY / dispatch); CF can host static frontend assets only. CF does not move the decision.

## Comparison

| Dimension | LiveView (status quo) | React-SPA | Next.js (named lead) | Astro |
|---|---|---|---|---|
| socialware-unification / json-render fit | admin is HEEx by design (rev8) | admin still hand-authored React, not json-render → thesis still fails | same; SSR adds nothing | wrong shape |
| real-time (chat/session/presence) | native LV+PubSub | Channels (precedent exists) | Channels; SSR dead weight | fights real-time |
| PTY terminal (xterm) | works (`phx-hook=PtyTerminal`) | rebuild over a Channel | rebuild | rebuild |
| CapBAC API boundary | in-process dispatch | `/api/v1` (built) | `/api/v1` | `/api/v1` |
| #65 CF fit | needs always-on BEAM | static OK; backend still BEAM | static-export heavy; or 2nd runtime | static OK; backend BEAM |
| migration effort | 0 | high (~15,500 LOC admin) | high + 2nd runtime | high + wrong paradigm |
| incremental (strangler) | n/a | feasible per-route (Plug-mounted React precedent) | heavier | low value |
| what's lost | — | `lv_cli_parity`, 3-layer atom system, CmdK/shell/dark-mode, server form-validation | + 2nd runtime | + paradigm mismatch |

**PTY is the hard ceiling on every option** — xterm.js is a stateful bidirectional byte
stream, never a json-render node, and not easier on any JS framework (you lose the working hook).

## De-risk spike (only if Allen wants empirical proof of the gap)

Build **one MUTATING admin surface** (e.g. a cap grant `EntityCapsLive`, or routing-rule add
`RoutingLive`) as a React component over `/api/v1`, mounted alongside LV via Plug (strangler
beachhead). **Do not pick a read-only list** — a display-only spike would falsely "succeed";
the entire gap is the missing event/action/input layer. The spike makes the loom-grade cost
concrete before any commitment.

## Where the loom investment should go

socialware **loom = agent-generated UI** → that is the **customer surface**, which is **already
React + json-render** (the rev8 dual-surface boundary). Apply net-new frontend/loom effort
there (socialware P4), not to converting human-authored admin into a socialware.

### Key files
- json-render (display-only): `apps/ezagent_domain_socialware/assets/js/json_render.mjs`; `…/page_view.ex`; contract `…/behavior/surface.ex`
- React precedent: `apps/ezagent_domain_socialware/assets/js/customer_app.js`; `apps/ezagent_web/lib/ezagent_web/controllers/socialware/customer_controller.ex`
- UI-agnostic API: `apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex`
- Admin surface (~15,500 LOC / 36 files): `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*_live.ex`
- PTY: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/{terminal,terminal_view,terminal_seam}.ex`
- Decisive design: `docs/superpowers/specs/2026-06-07-socialware-design.md` rev8 §4.4 (dual-surface, locked)
- loom (not in esr-ng): `docs/superpowers/specs/2026-05-28-plugin-loom.zh_cn.md`
- 3-layer UI + `lv_cli_parity`: `.claude/skills/ezagent-developer/references/ui-contract.md`
