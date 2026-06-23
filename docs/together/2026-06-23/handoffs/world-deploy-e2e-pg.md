# Handoff: World PostgreSQL Deploy + Full E2E Evidence

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** an independent developer (human + cc/codex)
> **Tracking:** `world-deploy-e2e-pg` · **Base:** `origin/main` @ `99f9eddb`
> **Status:** confirmed — world must be testable/deployable first, with full manual E2E evidence or a precise unsupported-step matrix by 18:00.

## 0. Mission

Make world reliably testable/deployable on the PostgreSQL substrate and produce
the shared E2E evidence flow for today's work. First determine whether current
`main` already supports the full flow. If not, return the support matrix early and
hand the missing product behavior to the world/hello or creator branch.

## 1. Required reading (before writing code)

1. Skill `ezagent-developer`.
2. `docs/guide/world-coordination.md`.
3. The `dev-together` skill and handoff standard.
4. `docs/guide/world-e2e-seed.md`.
5. `docs/together/2026-06-22/review.md` for PostgreSQL, agent-browser, and HSTS lessons.

## 2. Locked decisions (settled — do not re-litigate)

| # | Decision | Value |
|---|---|---|
| 1 | Deadline | 2026-06-23 20:00 +08:00. Start close-down at 18:00; if incomplete, return the smallest demonstrable artifact plus an unsupported-step matrix. |
| 2 | Scope | Deployment/runbook/evidence first. Do not make product UI changes unless the runbook itself is wrong. |
| 3 | Full E2E owner | This branch owns the checklist and environment. Product gaps discovered here are handed to `world-hello-convergence` or `socialware-creator-mvp`. |
| 4 | Merge model | PR into task branch; lead/admin merge only. No direct push to `main`. |

## 3. Architecture primer

World is host-routed through `apps/ezagent_plugin_world` and served by
`EzagentPluginWorld.WorldLive`. The existing runbook
`docs/guide/world-e2e-seed.md` predates the PostgreSQL-only migration and still
contains SQLite-era assumptions. `scripts/world_e2e_seed.exs` seeds admin login
and known session/member data. Hello's public page path is
`/socialware/customer?session_uri=...` for `public_view` sessions.

Relevant entrypoints:
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`
- `scripts/world_e2e_seed.exs`
- `docs/guide/world-e2e-seed.md`

## 4. Design (+ review status) & phased plan

Phase 0: Refresh the runbook for PostgreSQL.
- Remove or correct two-BEAM SQLite language.
- Document the PG setup, `EZAGENT_HOME`, host routing, ports, and clean restart.
- Keep the recipe reproducible for a fresh environment.

Phase 1: Run the support matrix on current `main`.
- Check every full E2E step below.
- Mark each step as supported, blocked, or needs product work.
- For blocked steps, identify the owning branch and exact missing behavior.

Phase 2: Produce evidence.
- If current `main` can pass, run the full manual flow and capture screenshots/transcript.
- If not, return the refreshed runbook plus support matrix by 18:00 so downstream branches can finish the product gaps.

## 5. Definition of Done (demonstrable artifact)

- [ ] Refreshed `docs/guide/world-e2e-seed.md` that works for PostgreSQL.
- [ ] Full manual E2E checklist evidence, or an 18:00 unsupported-step matrix with exact blockers.
- [ ] Screenshots/transcript for supported steps:
  1. register or log in;
  2. create a `cc` agent and complete its credential/login path;
  3. open a session and converse with the agent;
  4. create a routing table/session routing rule and verify team routing;
  5. create a hello page/app;
  6. open the external hello/customer link without login when public;
  7. see hello conversation/page state in the world session page;
  8. send messages across session/external hello surfaces and confirm both sides update.
- [ ] All touched-doc checks are clean. If code changes are needed, run the relevant focused tests and list any gates not run.

## 6. Discuss-first vs Deferred

**Discuss-first:** any Cloudflare/production credential requirement; any product UI change; any auth/capability change.

**Deferred:** product fixes for unsupported hello/creator behavior, targeted to `world-hello-convergence` or `socialware-creator-mvp`.

**Never deferred here:** the support matrix, runbook accuracy, and human-visible evidence for supported steps.

## 7. Conflict-avoidance

This task owns docs/runbook and evidence. It should not edit world UI except to
fix a demonstrably wrong runbook hook. If it discovers missing product behavior,
record it precisely and return early instead of expanding scope.

## 8. Merge model

PRs merge into `world-deploy-e2e-pg` first. Keep rebased on `main`. The lead
merges the task branch to `main` only after the DoD is met.

## 9. Gates, file/LOC estimate, open questions

Expected files: `docs/guide/world-e2e-seed.md` and possibly an evidence note under
`docs/together/2026-06-23/returns/`.

Open question for the return: which full E2E steps pass on current `main`, and
which must move to `world-hello-convergence`?
