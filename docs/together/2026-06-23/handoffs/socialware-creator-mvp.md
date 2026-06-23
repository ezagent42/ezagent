# Handoff: Socialware Creator MVP

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** an independent developer (human + cc/codex)
> **Tracking:** `socialware-creator-mvp` · **Base:** `origin/main` @ `99f9eddb`
> **Status:** confirmed — ship the smallest creator surface needed by today's E2E.

## 0. Mission

Ship a lean socialware creator MVP for launch: a user can create or launch the
hello/socialware app needed by the full E2E and navigate to both the world session
and the external customer page. Keep this to create/read/launch; live team and
routing management remains in the existing world session UI unless already
supported safely.

## 1. Required reading (before writing code)

1. Skill `ezagent-developer`.
2. `docs/guide/world-coordination.md`.
3. The `dev-together` skill and handoff standard.
4. `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md`.
5. `docs/superpowers/specs/2026-06-22-agent-console-manage-gate-proposal.md`.
6. `docs/superpowers/specs/2026-06-01-unified-kind-creation-via-templates.md`.
7. `docs/together/2026-06-23/handoffs/world-hello-convergence.md`.

## 2. Locked decisions (settled — do not re-litigate)

| # | Decision | Value |
|---|---|---|
| 1 | MVP line | Create/read/launch only. Do not build new live member/routing mutation authority today. |
| 2 | Product framing | This is `socialware creator`, not the old broad Agent Console product. |
| 3 | E2E-driven scope | Build only what helps the shared full E2E: create/launch hello/socialware session, link to world session, link to public customer page. |
| 4 | Deadline | 2026-06-23 20:00 +08:00. At 18:00, split and return the smallest usable creator artifact if incomplete. |

## 3. Architecture primer

The old Agent Console design split cold template creation, live session
management, migration, and observability. Today's MVP only needs the safe
create/read/launch slice:

- template/session creation through existing substrate paths;
- hello app creation through `session.hello` / `EzagentPluginHello.App.ensure_app/2`;
- navigation to world session and `/socialware/customer`;
- read-only status/topology only where existing authority is already safe.

Do not expose a raw tool runner, caps input, or a new Manage-gate. The
Manage-gate proposal is required reading so you know what not to shortcut.

## 4. Design (+ review status) & phased plan

Phase 0: Pick the smallest surface.
- Prefer an additive world surface or existing workspace/templates surface extension.
- Avoid changing major world navigation unless there is no discoverable entrypoint.

Phase 1: Implement create/read/launch.
- Show available socialware/hello creation choices needed by the E2E.
- Create/launch a hello app/session through existing safe paths.
- Show links: open in world session, open external customer page.
- Label unsupported live management actions as unavailable/follow-up; do not fake them.

Phase 2: Verify against the shared E2E.
- Use the `world-deploy-e2e-pg` runbook and the `world-hello-convergence` hello path.
- Return screenshots of the creator flow and links into both world and customer views.

## 5. Definition of Done (demonstrable artifact)

- [ ] Screenshot showing the socialware creator MVP entrypoint.
- [ ] Screenshot/transcript showing a hello/socialware app created or launched.
- [ ] Link from creator to the world session works.
- [ ] Link from creator to the external `/socialware/customer` page works for a public hello session.
- [ ] No new Manage-gate/live mutation authority is introduced.
- [ ] Relevant focused tests/gates for touched files; world slot/manifest checks if adding a world route surface.

## 6. Discuss-first vs Deferred

**Discuss-first:** implementing Manage-gate; granting or projecting live session management caps; adding broad migration/routing editors; changing core template authority.

**Deferred:** live team management, routing editor beyond existing world session UI, migration workflow, observability dashboards, advanced template editing.

**Never deferred here:** the create/launch path and the two navigation links needed by the E2E.

## 7. Conflict-avoidance

This task owns only the creator MVP surface and safe create/read/launch actions.
It must consume hello entrypoints from `world-hello-convergence` rather than
editing the same renderer component independently. Follow `docs/guide/world-coordination.md`.

## 8. Merge model

PRs merge into `socialware-creator-mvp` first. Keep rebased on `main`. The lead
merges the task branch to `main` only after the DoD is met.

## 9. Gates, file/LOC estimate, open questions

Expected files: one additive world component/surface plus small data/action glue,
or a narrow extension to an existing creation surface. Keep under 400 LOC.

Open question for the return: did the creator use an existing surface extension
or a new route-level surface, and what E2E screenshots prove launch works?
