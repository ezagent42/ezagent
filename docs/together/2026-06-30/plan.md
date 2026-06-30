# Dev Together Plan - 2026-06-30

planned_at: 2026-06-30 09:55 +0800
lead: allen / codex
day_deadline: 2026-06-30 23:59 +0800
timezone: GMT+8

## Inputs

- Roster source: `docs/together/team.md`, filtered to `role: human-dev`.
- Weekly goals: `docs/together/2026-W27/weekly-goals.md`.
- Continuity basis:
  - `docs/together/2026-06-29/stack.md`
  - `docs/together/2026-06-29/review.md`
  - `docs/together/2026-06-29/returns/*`
  - open PR snapshot on 2026-06-30 after merging #1095: #1027, #1026, #1022, #1020.

## Planned Tasks

| task id | owner | branch | weekly goal | scope | owned surfaces / files | required reading | DoD artifact | deadline |
|---|---|---|---|---|---|---|---|---|
| T1-autoservice-answer-loop | gaga | `gaga/0630-autoservice-answer-loop` | Goal 1 | Continue from merged #1095/#1096: verify the real AutoService cc answer-loop after Claude Code auth/bridge readiness. The target success signal is an agent-authored reply in `session://autosvc/default/tier1` that uses the KB fact `ZEPHYR-7731`. If auth cannot be made ready, return exact blocker evidence and the smallest next operational step. | AutoService live stack, `scripts/autoservice_tier1_seed.exs`, #1095 report, #1096 PR comment | #1095 merged report, `docs/together/2026-06-29/returns/cc-agent-create-failure-resolution.md`, temporary PG rule | Return doc with commands, screenshots/log evidence, PG cleanup proof if DB tests run, and clear verdict: answer-loop green or auth/bridge blocker. | 2026-06-30 16:00 |
| T2-agent-console-f3-f4-f7 | fatnine | `fix/agent-console-qa-f3-f4-f7` | Goal 1 | Convert #1027 QA findings into fixes for the high-value Agent Console blockers: invalid default `advisor` session template silent failure, occupied-agent delete feedback, and missing session remove/delete path decision. | `apps/ezagent_plugin_world/`, `apps/ezagent_web/test/ezagent_web/`, Agent Console LiveView/tests, #1027 docs | #1027 body, `docs/together/2026-06-26/agent-console-qa-findings.md`, AGENTS.md Phoenix/LiveView rules | PR with tests for F3 and F4; F7 either implemented or explicitly split with a tested UX decision. | 2026-06-30 18:00 |
| T3-world-host-scope-verify | zyli | `verify/world-host-scope-temp-pg` | Goal 1 | Rerun the deferred DB-backed gates from `world-host-scope-config-driven` using temporary PG Docker. If green, open/refresh PR; if red, return exact failing gate and fix recommendation. | `apps/ezagent_web/lib/ezagent_web/router.ex`, `config/*.exs`, world host routing tests, socialware P10 E2E | `returns/world-host-scope-config-driven.md`, `docs/guide/world-coordination.md`, temporary PG rule | Return doc with commands, PG container cleanup proof, and merge recommendation. | 2026-06-30 16:00 |
| T4-website-demo-followup | zhaomato | `feat/website-demo-followup-0630` | Goal 2 | Continue official website work from merged #1090 without touching World operator host routing. Focus on demo/content polish and `@json-render` substrate compatibility. | website/demo docs and app surfaces from #1090; avoid `apps/ezagent_plugin_world/assets/src/styles.css` unless coordinated | #1090, `docs/guide/world-coordination.md`, FP4 design-system return | PR or return with screenshots and clear separation from operator World/socialware surfaces. | 2026-06-30 18:00 |
| T5-kanban-pr1020-review | jjkysy | `review/kanban-pr1020-post-socialware` | Goal 3 | Rebase/review #1020 after socialware and #1096 landed. Produce a split recommendation: merge as-is, split into smaller PRs, or close/rebuild. | #1020 diff, `docs/e2e/kanban-pm-flow/`, kanban plugin, dev-together docs | #1020 body, `docs/together/2026-06-29/notes/0629-status-snapshot.md` B3 | Review return with exact gates run, changed-file risk map, and merge/split verdict. | 2026-06-30 20:00 |
| T6-close-stale-prs | allen | `docs/close-stale-prs-0630` | Goal 3 | Lead-only cleanup: close or refresh stale docs/housekeeping PRs #1026, #1022, and any subsumed return PR after extracting useful notes. | PR comments, `docs/together/2026-06-29/stack.md`, `docs/together/2026-06-30/plan.md` | Current open PR list, 0629 review | Each stale PR has either a close comment or refreshed mergeable path recorded in today's stack. | 2026-06-30 21:00 |

## Conflict Map

| surface | tasks | conflict / serialization rule |
|---|---|---|
| AutoService live stack | T1, lead close | #1095 docs are already merged; T1 owns only real answer-loop verification and must not reopen the core materialization design unless new evidence contradicts #1096. |
| Agent Console / World LiveView | T2, T3, T4 | T2 owns Agent Console behavior. T3 only verifies/reruns host routing. T4 must not modify operator World routing or shared `styles.css` without explicit coordination. |
| `apps/ezagent_plugin_world/assets/src/styles.css` | T4, possible T2 | Serialize through zhaomato if website/demo visual work touches it; T2 should prefer behavior/tests over shared style edits. |
| PR queue / dev-together ledger | T5, T6, lead | T5 owns #1020 technical verdict. T6 owns stale docs PR cleanup. Lead updates `stack.md` only after returns. |
| Test database | T2, T3, T5 | All tests use temporary PostgreSQL Docker containers and delete them after; no default sqlite and no local 55432 PG volume. |

## Handoff Order

1. T1 to gaga first: live answer-loop verification, building on merged #1095/#1096.
2. T3 to zyli in parallel: verification-only and uses temporary PG.
3. T2 to fatnine once T3's host-routing result is known if it changes World routing assumptions; otherwise can start immediately with Agent Console tests.
4. T4 to zhaomato in parallel but with World style ownership warning.
5. T5 to jjkysy as a review-first handoff; no build until the verdict says split or merge.
6. T6 stays with lead and runs after T1/T5 results.

## Off-Plan Support

- codex: bounded review/test/merge support; no independent track row.
- claude: Feishu-facing summaries, PR comment drafting, and isolated verification runs.

## Discuss-First Triggers

- Any T2 fix that changes CapBAC, session membership semantics, or cross-workspace authority must stop for design review.
- Any T4 change touching World operator routing, socialware customer routes, or shared world styles must coordinate with T3/T2.
- Any T5 conclusion to merge #1020 as-is must include green CI and a changed-file risk map; otherwise split first.
