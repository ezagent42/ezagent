# Handoff: T6 production workspace and dev-team users

> **Date:** 2026-06-30 · **From:** allen · **To:** allen
> **Tracking:** `T6-production-workspace-dev-team` · **Base:** `origin/main`
> **Status:** production ops.

## Mission

Complete the production environment for current dogfood: create or use the
`ezagent` workspace on `app.ezagent.chat`, add all current dev-team users, and
smoke test real login/session access.

## Required reading

1. `docs/together/team.md`
2. Current production deployment notes.
3. Secrets policy: do not put credentials in docs or chat.

## Definition of Done

- [ ] Production `ezagent` workspace exists on `app.ezagent.chat`.
- [ ] Current dev-team users are added.
- [ ] Smoke test proves users can reach the workspace/session surface.
- [ ] Deployment gaps and follow-up tasks are listed.
- [ ] No secrets are written into docs, PRs, or Feishu.

## Discuss-first

Stop before broad production data migration or policy changes not needed for
today's dev-team workspace.

## Merge model

Use branch `ops/prod-workspace-dev-team-0630` for notes/config changes if needed;
otherwise return an ops report.
