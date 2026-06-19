# Frontend unification — synthesis & recommendation (loom-branch + Vercel `json-render`)

**Date:** 2026-06-19 · **Requested by:** Allen (research-only, decide later) · **Status:** research; **recommend nothing be built yet.**

Supersedes the two component reports it folds together:
- `2026-06-19-frontend-socialware-unification-research.md` (main-only; missed loom)
- the loom-branch (`feat/loom-vertical`) feasibility study + the Vercel-`json-render` library identification (this note reconciles both).

**Allen's actual thesis (corrected framing):** *don't* run json-render at runtime as the in-house 145-LOC renderer does — instead **author the UX business-logic as JSON, compile/convert it into the same front-end mechanism loom uses, and run admin as "a socialware"** on one unified rendering layer, retiring the LiveView/loom dual-maintenance.

---

## TL;DR recommendation

**The thesis is now *technically achievable* — but only because the missing piece turns out to be an off-the-shelf library, not because it's cheap. Do NOT retire LiveView yet. Adopt `@json-render/*` on the *customer/generative* surface first; defer the admin migration behind a de-risk spike.**

Two findings, from the two studies, lock together:

1. **(loom study) The blocker is a client-side interaction layer that does not exist in-house.** The in-house `json_render.mjs` (145 LOC) and loom's node model are **display-only** — `{type, props, children}` → `createElement`. No events, no bindings, no validation, no actions. Loom *avoids* needing them: every customer interaction is converted to a **chat-message POST**, the agent reasons over it, and **regenerates a whole new page tree**. So loom proves *generative + chat-roundtrip customer UI*, NOT *deterministic data-driven admin*. To express admin (server-validated form round-trips, live-mutation tables, cap grants, PTY) you'd have to **build a second UI framework** (event/binding/validation/theming) on top of a deliberately minimal renderer.

2. **(Vercel study) That second UI framework already exists, mature and Apache-2.0: `vercel-labs/json-render`.** This is the real library Allen was thinking of (15.5k★, `@json-render/*` v0.19.0, multi-framework). It is a **data-driven runtime interpreter** — LLM (or a human) emits a JSON tree constrained by a Zod `defineCatalog(...)`, a `<Renderer spec registry/>` maps nodes to real components — **with exactly the event/action/binding/validation layer the in-house renderer lacks**, plus shadcn components, progressive streaming, devtools. Crucially it needs **no Node/RSC tier beside the BEAM** (unlike AI SDK RSC, which is *paused*, and v0, which is closed-source codegen). It runs entirely in ESR's JS frontend over `/api/v1` + Phoenix Channels.

So the two reports don't conflict — the loom study says "you'd have to build framework X," the Vercel study says "framework X is `@json-render/*`, here it is." That **removes the strongest objection** (rebuilding a UI framework). It does **not** remove the rest of the cost.

---

## What's already done (the part Allen most wants — and it's server-side)

The **data-driven backend is already unified.** Every mutation — PTY input, every LV `handle_event`, and the auto-derived `POST /api/v1/:kind/:action` — converges on `Ezagent.Invocation.dispatch` (CapBAC-enforced), and `lv_cli_parity_test.exs` *enforces* that every mutating LV event has a CLI/dispatch counterpart. **The gap Allen wants closed is entirely client-side rendering**, not backend logic. There is no "two ways to perform a mutation" duplication to delete; only two *presentation* layers, and admin presentation genuinely differs from customer presentation.

---

## The honest residual cost (what adopting json-render does NOT pay for)

Even with `@json-render/*` supplying the framework, retiring LiveView still requires:
- **Cookie→cap auth bridge (the hidden cost).** `/api/v1` wants `Authorization: Bearer esr_pat_…` + `X-Ezagent-Entity-URI`; admin browser sessions authenticate via a **session cookie** with no PAT. A cookie→short-lived-token bridge for a data-driven admin SPA **does not exist today** — net-new, and the item most likely to be underestimated.
- **Port ~13,500 LOC across ~25 `*_live.ex`** to catalog/spec form, incl. the 3-layer theming atoms (`ui-contract.md`), `uri_picker`, cmdk, live-mutation tables.
- **PTY over a Channel.** xterm is today an LV `phx-hook` over the LV socket; outside LV it must be rebuilt on a Phoenix Channel as a single registered catalog component, re-proving `agents_pty_input_dispatch_test` (audit-row == input-byte invariant).
- **Rebuild `lv_cli_parity`** as API+frontend parity tests on the new substrate.

One-time cost: **high**. Ongoing saving: **modest** (the two surfaces stay conceptually distinct — operator-deterministic vs customer-generative — so daily work doesn't actually collapse to one).

---

## Recommended path (phased, low-regret)

1. **Adopt `@json-render/*` on the CUSTOMER / generative surface first** — replace the in-house 145-LOC `json_render.mjs` with the mature library where it is a *perfect* fit (agents emit catalog-constrained JSON; guardrails, streaming, shadcn for free). This is the genuine win, low risk, and it *exercises* the event/action/auth-bridge machinery in the surface that needs it least dangerously.
2. **Build the cookie→cap auth bridge** once, as shared infra, during (1).
3. **De-risk spike for admin:** build **one mutating admin surface** (routing add-rule *or* a cap grant — both are live-mutation + server-validated, the representative hard case) as a json-render page over `/api/v1`, **mounted beside the existing LV** (strangler; do not delete the LV; do not pick a read-only list — that would falsely "succeed"). Measure the real per-surface cost against the working LV. **Decision gate here.**
4. **Only if the spike proves cheap** (current evidence says it won't): port read-mostly LVs → live-mutation LVs → PTY-over-Channel (hardest, last) → retire LV only after every surface has a tested spec equivalent and parity is green on the new substrate.

**Net:** say *yes* to `@json-render/*` as the rendering layer **on the customer surface now**; treat "admin as a socialware / retire LiveView" as a **deferred, spike-gated** decision — the framework objection is gone, but the migration cost (auth bridge + 13.5K LOC + PTY + parity) is real and should be measured on one surface before committing.

**Caveat:** `@json-render/*` is **v0.19.0 (pre-1.0)** — adopting it means tracking a young dependency with likely API churn.

### Key files / sources
- in-house renderer (display-only): `apps/ezagent_domain_socialware/assets/js/json_render.mjs`; React precedent `…/customer_app.js` + `apps/ezagent_web/lib/ezagent_web/socialware/customer_channel.ex`
- UI-agnostic contract: `apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex`; parity `apps/ezagent_core/test/invariants/lv_cli_parity_test.exs`
- PTY: `apps/ezagent_web/assets/js/hooks/pty_terminal.js`; `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/{terminal,terminal_view,terminal_seam}.ex`
- admin (~13.5K LOC / ~25 files): `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*_live.ex`
- loom (branch `feat/loom-vertical`): `apps/ezagent_plugin_loom/lib/ezagent_plugin_loom/{node_types,customer_spa,page_store,web_plug,tool}.ex`
- library: `github.com/vercel-labs/json-render` (Apache-2.0, `@json-render/*` 0.19.0); AI SDK RSC = *paused*; v0 = proprietary codegen (build-time authoring aid only)
