# Dev Together Plan - 2026-06-30

planned_at: 2026-06-30 09:55 +0800
lead: allen
day_deadline: 2026-06-30 23:59 +0800
timezone: GMT+8

## Inputs

- Roster source: `docs/together/team.md`.
- Weekly goals: `docs/together/2026-W27/weekly-goals.md`.
- 2026-06-29 merged team PRs: #1083, #1090, #1095, #1096, #1099, #1100.
- Allen 2026-06-30 correction: today's plan must focus on product flows that can
  be shown, tested, and attempted on production.

## Planned Tasks

| task id | owner | branch | weekly goal | scope | owned surfaces / files | required reading | DoD artifact | deadline |
|---|---|---|---|---|---|---|---|---|
| T1-autoservice-current-arch-e2e | gaga | `verify/autoservice-current-arch-e2e` | Goal 1 | Continue verifying that the AutoService flow can run end-to-end on the current architecture. This is not a redesign task: prove the current #1095/#1096 state can complete, or return the exact blocker. | AutoService seed/live stack, #1095 report, #1096 final fix, production-like local env | `docs/together/2026-06-29/returns/autoservice-live-verify.md`, #1095, #1096 | Return with transcript/screenshots/logs, clear pass/blocker verdict, and whether the current architecture can complete the flow. | 16:00 |
| T2-agent-console-completeness | fatnine | `fix/agent-console-completeness-0630` | Goal 1 | Validate Agent Console completeness. List missing items first, then directly fix the small/clear gaps. Anything requiring a design decision is returned as a short list with recommendation. | Agent Console world UI, LiveView/tests, #1027 QA report | #1027, `docs/together/2026-06-26/agent-console-qa-findings.md`, Phoenix/LiveView rules | Return with missing-content checklist, fixes/PR for clear gaps, and design-decision list for nontrivial gaps. | 18:00 |
| T3-ui-im-demo | zyli | `demo/ui-im-alignment-0630` | Goal 1 | Adjust the current UI toward an IM-like product baseline. First produce a revised demo for team confirmation; do not jump straight into broad production refactor. | World/session/chat UI surfaces, screenshots/demo artifact | #1083, current app UI, IM reference comparison from Allen feedback | Demo artifact/screenshots showing revised information architecture and chat/session interaction direction; list of production changes after confirmation. | 17:00 |
| T4-website-framework-local-prod | zhaomato + ruihua | `feat/website-framework-hello-prod-0630` | Goal 2 | Build the official website framework with consistent style and columns. Concrete copy and detailed interactions can be optimized later by ruihua. Establish a hello page that connects to backend/world, test locally, then attempt production rollout on `app.ezagent.chat`. | `docs/website-demo/`, hello page, website route/binding, backend/world connection, deployment notes | #1090, #1099, #1083, `docs/guide/world-coordination.md` | Local proof of website framework + hello page backend/world connectivity, production rollout attempt on `app.ezagent.chat`, and ruihua content/interaction follow-up list. | 19:00 |
| T5-kanban-socialware-launch-check | jjkysy | `verify/kanban-socialware-launch-0630` | Goal 3 | Check whether kanban socialware is ready to go online now. Verify current branch/main state, identify blockers, and return a launch/no-launch verdict. | Kanban socialware, #1020, kanban E2E/docs | #1020, `docs/e2e/kanban-pm-flow/`, socialware notes | Launch-readiness report: green path if launchable, exact blockers if not, and smallest PR slices required. | 20:00 |
| T6-production-workspace-dev-team | allen | `ops/prod-workspace-dev-team-0630` | Goal 1 | Complete production environment work: create/use the ezagent workspace on `app.ezagent.chat`, add all current dev-team users, and test the workspace with real login/session access. | production env, workspace/user admin, deployment config, dev-team roster | `docs/together/team.md`, production deployment notes, current secrets policy | Production workspace exists, dev-team users added, smoke test recorded, and deployment gaps listed. | 21:00 |

## Conflict Map

| surface | tasks | conflict / serialization rule |
|---|---|---|
| Live/production environment | T4, T6 | Allen owns production deployment/workspace. zhaomato tests locally first, then coordinates with Allen before `app.ezagent.chat` rollout. |
| World/session/chat UI | T2, T3, T4 | zyli owns UI direction/demo. fatnine owns Agent Console completeness. zhaomato avoids broad World UI refactor while wiring website/hello. |
| AutoService current architecture | T1, T6 | gaga verifies flow behavior; Allen handles production environment/workspace. Do not mix architecture redesign into deployment work. |
| Kanban socialware | T5, T4 | jjkysy owns kanban launch verdict. Website can reference kanban, but launch readiness comes from T5. |

## Handoff Order

1. T1 gaga: AutoService current-architecture end-to-end verification.
2. T3 zyli: UI/IM revised demo for team confirmation.
3. T4 zhaomato + ruihua: website framework, hello page, local proof, production attempt with Allen.
4. T2 fatnine: Agent Console completeness checklist and direct fixes.
5. T5 jjkysy: kanban socialware launch readiness.
6. T6 allen: production environment, ezagent workspace, dev-team users, smoke test.

## Paste-Ready Start Prompts

| dev | prompt |
|---|---|
| gaga | `dev-together dive docs/together/2026-06-30/handoffs/t1-autoservice-current-arch-e2e.md` — verify the AutoService flow can run end-to-end on the current architecture; return transcript/screenshots/logs and pass/blocker verdict. |
| fatnine | `dev-together dive docs/together/2026-06-30/handoffs/t2-agent-console-completeness.md` — validate Agent Console completeness, list missing items, directly fix clear gaps, and return design-decision items separately. |
| zyli | `dev-together dive docs/together/2026-06-30/handoffs/t3-ui-im-demo.md` — adjust UI direction toward an IM-like baseline and first produce a revised demo/screenshots for team confirmation. |
| zhaomato | `dev-together dive docs/together/2026-06-30/handoffs/t4-website-framework-local-prod.md` — coordinate with ruihua, build website framework + hello page, prove backend/world connection locally, then coordinate production attempt on `app.ezagent.chat`. |
| ruihua | `dev-together dive docs/together/2026-06-30/handoffs/t4-ruihua-website-content.md` — provide website columns/content/interaction direction for zhaomato today; detailed copy and polish can continue after framework launch. |
| jjkysy | `dev-together dive docs/together/2026-06-30/handoffs/t5-kanban-socialware-launch-check.md` — check whether kanban socialware can go online now; return launch/no-launch verdict and blockers. |
| allen | `dev-together dive docs/together/2026-06-30/handoffs/t6-production-workspace-dev-team.md` — complete production env, create/use ezagent workspace, add dev-team users, and smoke test. |

## Discuss-First Triggers

- Any task that changes CapBAC, cross-workspace authority, or production access
  policy must stop for Allen confirmation.
- T3 is demo-first. Do not broad-refactor production UI before team confirms the
  revised IM-like direction.
- T4 must coordinate with T6 before production changes on `app.ezagent.chat`.
- T5 must not claim kanban socialware launchable without a concrete smoke/E2E
  path and blocker list.
