# Handoff: T4 official website demo follow-up

> **Date:** 2026-06-30 · **From:** allen · **To:** zhaomato
> **Tracking:** `T4-website-demo-followup` · **Base:** `origin/main`
> **Status:** confirmed — continue from merged #1090.

## 0. Mission

Continue official website work from #1090, focusing on demo/content polish and
`@json-render` substrate compatibility, while avoiding operator World routing
and shared style conflicts.

## 1. Required reading

1. PR #1090 and `docs/website-demo/`
2. `docs/together/2026-06-29/review.md`
3. `docs/guide/world-coordination.md`
4. `docs/together/2026-06-29/returns/zyli-fp4-design-system.md`
5. Skill `ezagent-developer`

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | Boundary | Do not change operator World host routing in this task. |
| 2 | Style conflicts | Coordinate before touching shared `styles.css`. |
| 3 | Proof | Return screenshots plus exact surface boundary. |

## 3. Plan

1. Inspect #1090 demo surfaces and DS assumptions.
2. Make narrow website/demo or json-render substrate changes.
3. Capture screenshots of the result.
4. Document what was deliberately not touched.

## 4. Definition of Done

- [ ] Website/demo follow-up is viewable and has screenshots.
- [ ] `@json-render` compatibility impact is described.
- [ ] No operator World routing change is included.
- [ ] Any shared style change is coordinated and called out.
- [ ] PR/return includes commands run and residual follow-up items.

## 5. Discuss-first / defer

Discuss first before changing World operator routes, socialware external routes,
or shared world styles. Defer live deployment if domain/binding work is not in
scope.

## 6. Merge model

Use branch `feat/website-demo-followup-0630`. Return PR/evidence to lead.
