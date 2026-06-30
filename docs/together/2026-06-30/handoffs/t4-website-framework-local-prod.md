# Handoff: T4 website framework + hello page local/prod attempt

> **Date:** 2026-06-30 · **From:** allen · **To:** zhaomato
> **Tracking:** `T4-website-framework-local-prod` · **Base:** `origin/main`
> **Status:** confirmed — framework first, content polish later.

## Mission

Coordinate with ruihua and ship the official website framework first: consistent
style, consistent columns, a hello page, and backend/world connectivity. Test
locally first, then coordinate with Allen to attempt rollout on
`app.ezagent.chat`.

## Required reading

1. #1090 website demo.
2. #1099 hello `render_card` work.
3. #1083 design-system migration.
4. `docs/guide/world-coordination.md`
5. Ruihua handoff for content/columns.

## Definition of Done

- [ ] Website framework has consistent style and columns.
- [ ] Hello page exists and connects to backend/world locally.
- [ ] Local test evidence is attached before production attempt.
- [ ] Production attempt on `app.ezagent.chat` is coordinated with Allen and recorded.
- [ ] Concrete content/interaction polish remains separable for ruihua follow-up.

## Discuss-first

Stop before changing production routing/deployment without Allen. Coordinate
before touching shared world styles.

## Merge model

Use branch `feat/website-framework-hello-prod-0630`; return local/prod evidence.
