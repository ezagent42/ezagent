# Scenario 41: Seller — land on a gallery product, try it, enter world, fork it

**Category**: 6 — Socialware / templates (discover → try → fork)
**Status**: 🚧 design spec — clickable-mock-recordable NOW against `docs/website-demo/flywheel/`;
real-site tier PENDING (gallery landing + fork-from-product trigger not wired). Not ✅.
**Author**: Claude (with ruihua), 2026-07-09 — homesite flywheel seller arc S0–S3
(`docs/rh/homesite/product/2-旅程.md` J-S). Extends scenarios 36 (anon browse) & 39
(config-fork) with the **gallery landing point** they don't cover.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

A **seller** (value-first business owner, e.g. agency 李复制) arrives from outside, lands on
a **gallery product** (demo: the `expert-recruit` hire socialware), tries it anonymously,
then enters world and **forks** the session to become owner of their own copy. This is the
demand arc's entry (S0→S3); fork itself (`session.fork_config`) is already shipped — the gap
is the gallery landing + the fork-from-product trigger.

## Pre-conditions

- Recording target: `docs/website-demo/flywheel/` served from repo root.
- Seller starts anonymous (fresh browser); logs in at the fork step.
- Shipped (reference): `public_view` + `AnonUser` anon lifecycle (scenario 35);
  **`session_fork_action`** user-facing fork (Conversation.tsx:713 → `config_fork.ex`),
  gated by `:create_session`, caller becomes owner (scenario 39).

## Actors

- **Seller (anon → login)**: `entity://system/user/anon-<rand>` → real user on fork.
- **Surfaces**: gallery (`gallery.html`) → product detail (`product-detail.html`) → the
  product's `public_view` face (demo: `../recruit-v2.html`) → world (MOCK:
  `world-step.html?mode=fork`).

## Steps

1. **Land from outside** — deep-link (Instagram etc.) into the gallery / a product detail
   (`product-detail.html?sw=expert-recruit`). **[W-G1]** the detail is served by the catalog API.
2. **Try** — click `试用 · Try` → the product's `public_view` face (demo: `recruit-v2.html`);
   experience the value anonymously (draw → prompt score → expert market).
3. **Decide to own it** — back on detail, click `Fork 复制成我的 · Fork this`. **[W-G3]**
   this deep-links into world and triggers `session_fork_action` on the product's session.
4. **Fork → own session** — in world (demo: `world-step.html?mode=fork`), the config is
   copied into a NEW session; **the seller becomes owner** (no history). Anon→login happens
   here (`anon→login takeover`).
5. (continues in scenario 42 — customize + publish back.)

## Expected outcomes

- Step 2: an anonymous visitor reaches the product's `public_view` face without login.
- Step 3→4: the fork copies **config, not history**; a NEW `session_uri` is created with the
  seller as `owner` — NOT a join into the same session (that's the scenario-38 "share" path;
  fork ≠ join is the load-bearing distinction).
- The source product is unaffected (fork is a copy).

## Failure modes to test

- **Fork becomes a join** — clicking Fork adds the seller to the SAME session instead of
  spawning a new owned one → the two-path semantics (38 join vs 39/41 fork) are broken.
- **Fork not reachable from the product** — `session_fork_action` exists but no UI path
  triggers it from a gallery product (**W-G3** gap) → seller can't own a copy.
- **Anon try gated** — the `试用` face demands login for a read-only view (anon lifecycle leak).

## Cross-references

- Demo: `docs/website-demo/flywheel/{gallery,product-detail}.html` + `recruit-v2.html` + `world-step.html?mode=fork`.
- Handoff: `docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md` (W-G1/W-G3).
- Prior scenarios reused: **35** (anon access), **36** (anon browse + login gate),
  **39** (config-fork → new owned session). This scenario adds the **gallery landing**.
- Design: `docs/rh/homesite/` (seller arc S0–S3); persona 李复制 (`08 §2`).

## Notes

- Fork (W-G3 body) is **already ✅** — do not rebuild it; wire the trigger from the product page.
- Status 🚧 until live test + runbook + screenshot + sign-off.
