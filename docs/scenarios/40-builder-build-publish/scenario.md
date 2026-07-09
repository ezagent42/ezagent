# Scenario 40: Builder — build a socialware, publish it to the homesite gallery

**Category**: 6 — Socialware / templates (author → publish → discover)
**Status**: 🚧 design spec — clickable-mock-recordable NOW against `docs/website-demo/flywheel/`
(gallery/world-step/publish-landing); real-site tier PENDING (gallery catalog UI +
publish entry not built). Not ✅ (no invariant test + no sign-off).
**Author**: Claude (with ruihua), 2026-07-09 — from the homesite flywheel builder arc
(`docs/rh/homesite/product/2-旅程.md` J-B). Supersedes the rough `product/2` J-index reservation.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

A **builder** (technical creator, tool-first) builds a socialware product in world+hello,
then **publishes it to the homesite gallery** where it becomes a discoverable, try-able,
fork-able card. This is the supply arc's payoff (B4→B5) and it feeds the flywheel: the
published product is what a seller lands on in scenario 41.

## Pre-conditions

- Recording target (near-term): `docs/website-demo/flywheel/` served from the repo root.
- The builder is a signed-in user with `:create_session` / template-author caps.
- Backend already shipped (reference, don't rebuild): socialware = config-only
  `Ezagent.Socialware.Definition`; publish CR `ConfigGovernance.Socialware`
  (`open_cr → stage_definition → publish_cr`, public scope admin-gated);
  discover `DefinitionRegistry.list/1` + `lookup/2`.

## Actors

- **Builder**: `entity://system/user/<builder>` — real user, template author.
- **Surfaces**: world+hello build workbench (MOCK in demo = `world-step.html?mode=build`);
  the homesite **gallery** (`flywheel/gallery.html`) + **publish landing**
  (`flywheel/publish-landing.html`).

## Steps

1. **Enter the build workbench** — from the gallery, click `发布你的产品 · Publish yours`
   → world+hello build surface (demo: `world-step.html?mode=build`).
2. **Describe → generate (hello)** — one-sentence prompt → hello generates a `public_view`
   product face (demo: mocked hello panel + member chips).
3. **Publish** — click `发布进 gallery · Publish` → **[W-G2]** the socialware publish CR is
   opened/staged/published so the homesite catalog can see it.
4. **Confirmation** — lands on `publish-landing.html`; the new product card animates into
   a mini-gallery.
5. **Appears in gallery** — return to `gallery.html`; the builder's product is now a live
   card (title / author / version / `public_view` badge).

## Expected outcomes

- After step 3, the Definition is published to the registry (public scope) with a stable
  `name` + `version` + **`owner`** (**[W-G5]** owner field).
- Step 5: `gallery.html` lists the new product via the catalog API (**[W-G1]**); its card
  shows `public_view · live` and the correct author + version (**[W-G4]**).
- A seller (scenario 41) can now land on this product.

## Failure modes to test

- **Publish silently no-ops** — the CR isn't opened/published; product never reaches the
  catalog. "If it fails, who knows?" → must surface an error, never a silent drop.
- **No owner** — published Definition has no author → gallery card can't attribute it and
  S5 reflow can't credit the seller (**W-G5** gap).
- **Not discoverable** — published but the catalog API (**W-G1**) doesn't list it → it
  exists only as an install-picker row, not a browsable product.

## Cross-references

- Demo: `docs/website-demo/flywheel/{gallery,world-step,publish-landing}.html`.
- Handoff: `docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md` (W-G1/W-G2/W-G4/W-G5).
- Specs (don't redesign): `docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md`
  (P0 version-identity, P1 catalog), `2026-07-03-socialware-manifest-design.md` (manifest §2).
- Design: `docs/rh/homesite/` (flywheel builder arc B4/B5).

## Notes

- **Status is 🚧 on purpose.** The gallery catalog UI + the homesite-reachable publish entry
  are intended-but-not-built; the demo records them against mock surfaces. Do NOT mark ✅
  until a deterministic/live test + runbook + agent-browser screenshot + sign-off exist.
