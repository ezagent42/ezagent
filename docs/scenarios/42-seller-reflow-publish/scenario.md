# Scenario 42: Seller — customize the fork, publish it back to the gallery (flywheel closure)

**Category**: 6 — Socialware / templates (customize → publish → reflow)
**Status**: 🚧 design spec — clickable-mock-recordable NOW against `docs/website-demo/flywheel/`;
real-site tier PENDING (publish-to-homesite entry + cross-user discovery). Not ✅.
**Author**: Claude (with ruihua), 2026-07-09 — homesite flywheel seller arc S4–S5, the
**closure** (`docs/rh/homesite/product/2-旅程.md` J-S5). This is where two dead funnels
become a flywheel.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

Continuing scenario 41: the **seller** customizes their forked session in world+hello into
their own product, then **publishes it back to the gallery**. The seller's product now sits
on the shelf as the *next* seller's landing point — the demand arc's output re-enters as
supply. This closure (`S5 → new B5`) is the load-bearing claim of the whole flywheel
(`model.md §0`).

## Pre-conditions

- Continues from scenario 41 (seller has a forked, owned session).
- Recording target: `docs/website-demo/flywheel/` (`world-step.html?mode=fork` →
  `publish-landing.html` → `gallery.html`).
- Publish CR `ConfigGovernance.Socialware` shipped; **owner field (W-G5)** needed for
  attribution.

## Actors

- **Seller (owner)**: real user, owner of the forked session.
- **Surfaces**: world+hello customize (MOCK: `world-step.html?mode=fork`) → publish landing
  (`publish-landing.html`) → gallery (`gallery.html`).

## Steps

1. **Customize** — in world+hello, adapt the fork to the seller's business (demo: 招人分诊 +
   到店接待 + 预约日历 for 李复制's agency clients).
2. **Publish back** — click `发布进 gallery · Publish` → **[W-G2]** publish CR opens/stages/
   publishes the seller's Definition; **[W-G5]** attributed to the seller as `owner`.
3. **Confirmation** — `publish-landing.html`: "your product is on the shelf"; card slots in.
4. **Reflow visible** — return to `gallery.html`; the seller's variant is now a live card
   **alongside** the source product — it is now a landing point for the next seller
   (i.e. a new B5 / a new scenario-41 S0).

## Expected outcomes

- Step 2: a NEW published Definition (distinct `name`/`version`) with the seller as `owner`,
  optionally recording `forkedFrom` provenance.
- Step 4: `gallery.html` (via catalog API **W-G1**) lists BOTH the source and the seller's
  fork — the flywheel closure is **shown**, not asserted (seed ∪ published).
- A subsequent seller can land on the seller's product and fork *it* (recursion — the loop
  actually turns).

## Failure modes to test

- **Reflow doesn't close** — the seller's published product isn't discoverable to the next
  seller (catalog **W-G1** gap) → it's "saved a template", not a turning flywheel.
- **No attribution** — published without `owner` (**W-G5**) → can't credit the seller;
  provenance/`forkedFrom` lost.
- **Self-serve vs moderation unresolved** — if publish is admin-gated (registry O-4), the
  seller can't self-publish → the demand→supply reflow stalls on a human gate.

## Cross-references

- Demo: `docs/website-demo/flywheel/{world-step,publish-landing,gallery}.html`.
- Handoff: `docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md` (W-G1/W-G2/W-G5).
- Specs: registry P0 (version-identity) / O-4 (self-serve vs moderation); manifest O-1 (owner).
- Design: `docs/rh/homesite/model.md §0` (the closure = the承重命题).

## Notes

- The closure `S5 == new B5` uses the **same** publish surface as scenario 40 (builder B5) —
  supply and demand arcs share the publish/gallery surface. Build it once.
- Status 🚧 until live test + runbook + screenshot + sign-off.
