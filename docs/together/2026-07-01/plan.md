# 2026-07-01 Dev-Together Plan

planned_at: 2026-07-01 Asia/Shanghai
lead: linyilun / Codex
day_deadline: 2026-07-01 19:00 Asia/Shanghai
weekly_goals: `docs/together/2026-W27/weekly-goals.md`

## Theme

Today should be a convergence day around ruihua's design direction.

The work is not "ruihua implements everything". The work is: use ruihua as the
shared design/IA source of truth, then let each engineer finish one surface
without colliding with the others.

Primary surfaces:

- Website / Hello
- World UI shell
- Agent Console
- Socialware / AutoService public flow
- Kanban/dev-together integration branch split

## Tracks

| Task | Owner | Branch | Weekly goal | Scope | Owned surfaces/files | DoD artifact | Deadline |
|---|---|---|---|---|---|---|---|
| T1 Design convergence gate | ruihua + lead | docs/design-ui-convergence-0701 | Goal 1 / Goal 2 | Produce one shared IA/visual direction for Website, Hello, World UI, Agent Console, and Socialware. This is a review gate, not a code-heavy branch. | `docs/together/2026-07-01/`, design/demo docs | Short design memo/screenshots: what is common, what differs by surface, what must be implemented today. | 12:30 |
| T2 Website / Hello production path | zhaomato | feat/website-hello-ruihua-0701 | Goal 2 | Take #1103/#1107 main state and make one website/hello path coherent with ruihua's direction. Verify hello can connect to backend/world on a non-prod target before production attempt. | `docs/website-demo/`, `scripts/refresh_hello_site.exs`, hello plugin/site data only | PR with screenshots, refresh command evidence, and explicit statement of prod rollout readiness. | 17:00 |
| T3 World UI shell polish | zyli | feat/world-ui-ruihua-polish-0701 | Goal 1 | Build on merged #1104. Align the World shell with the shared design direction; fix concrete post-merge rough edges rather than opening another broad redesign. | `apps/ezagent_plugin_world/assets/src/main.tsx`, focused components, avoid broad `styles.css` churn | PR with before/after screenshots and a short checklist against ruihua direction. | 17:00 |
| T4 Agent Console one complete prototype | fatnine | feat/agent-console-one-prototype-0701 | Goal 1 | Continue #1112 by choosing one Agent Console IA prototype path and making it usable/verifiable. Do not create additional prototype branches. Keep session delete/archive as a design decision unless semantics are agreed. | Agent Console demo/docs/surface files from #1112; avoid unrelated World shell edits | PR update or new PR with one completed prototype path, evidence, and remaining explicit design questions. | 17:00 |
| T5 Socialware / AutoService public flow | gaga | feat/socialware-autoservice-ruihua-0701 | Goal 1 | Validate the customer-facing socialware/AutoService flow on current main after #1106. Identify UI/content gaps against ruihua direction and fix only narrow blocking issues. | socialware customer UI, AutoService seed/docs, no core dispatch changes | Return with E2E transcript/screenshots; PR only for narrow fixes. | 17:00 |
| T6 Split #1110 | jjkysy | split/1110-surface-runtime-0701 | Goal 3 | Use #1110 as source branch and split into reviewable PRs. Start with PR A World UI surface substrate and PR B generic role-agent materialization. Do not merge the whole integration branch. | #1110 branch, `docs/together/2026-07-01/handoffs/jjkysy-split-pr-1110.md` | At least one smaller PR opened, with clear excluded scope and CI status. | 18:00 |
| T7 Lead integration | allen / lead | lead/0701-stack-review | Goal 3 | Review returned PRs, enforce design gate, keep main green, and avoid UI branch collisions. | `docs/together/2026-07-01/`, GitHub reviews | Updated stack/review notes and merge decisions. | 19:00 |

## Conflict Map

| Surface | Owners Today | Conflict Rule |
|---|---|---|
| Shared design / IA | ruihua + lead | ruihua provides the direction; engineers implement one surface each. No new competing prototypes without lead approval. |
| World UI shell | zyli, fatnine, jjkysy | zyli owns shell polish. fatnine should avoid shell-wide changes unless required by the Agent Console prototype. jjkysy should not mix kanban UI substrate with shell redesign. |
| `apps/ezagent_plugin_world/assets/src/main.tsx` | zyli / jjkysy | Serialize edits. #1110 already conflicted here after #1104. Any PR touching this file must name the specific slot/rendering change. |
| `styles.css` / visual tokens | zyli only by default | No broad parallel edits. Other tracks should prefer component-local changes or docs/screenshots. |
| Website demo/docs | zhaomato + ruihua | zhaomato implements; ruihua reviews direction. Avoid re-opening #1103/#1107 conflicts. |
| Agent Console | fatnine | One prototype path only. No parallel IA branches. |
| Socialware / AutoService | gaga | Validate current main; narrow PRs only. Do not reintroduce core dispatch/local registry changes. |
| #1110 split | jjkysy | Split by ownership boundary. Do not combine substrate, business plugin, UI, persona, and docs in one PR. |

## Handoff Order

1. T1 ruihua design convergence first. The other UI tracks can prepare, but final
   UI decisions should wait for this direction.
2. T2/T3/T4/T5 can run in parallel after the design gate.
3. T6 can run independently, but must not merge into main today unless split PRs
   are small, green, and reviewed.
4. T7 runs throughout the day.

## Required Reading

- `docs/together/2026-06-30/review.md`
- `docs/together/2026-06-30/stack.md`
- `docs/together/2026-06-30/kanban-rebase-merge-analysis.md`
- `docs/together/2026-07-01/handoffs/jjkysy-split-pr-1110.md` for jjkysy
- `docs/guide/world-coordination.md` for any World UI work

## Off-Plan Support

Agents may help with bounded review, screenshots, CI diagnosis, and docs. Agents
should not become hidden owners of human-dev tracks.

## Plan Gate

This plan is valid only if the team follows the convergence constraint: one
shared design direction, one owner per surface, and one completed prototype path
for Agent Console.
