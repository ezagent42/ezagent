# dev-together plan - 2026-06-23

_status: approved for dispatch by Allen_

## Day metadata

| Field | Value |
|---|---|
| planned_at | 2026-06-23 11:23:06 +08:00 |
| timezone | Asia/Shanghai |
| lead | Allen + Codex lead support |
| base | `origin/main` @ `3cd5a5a4` (re-dispatched 16:20 on latest main; was `56148805`) |
| re-dispatch | 2026-06-23 16:20 — handoffs 1/3/4 rebased to latest `origin/main` + each annotated with the now-available E2E support matrix/root-cause (PR [#902](https://github.com/ezagent42/ezagent/pull/902), `e2e-blocker-analysis.md`). Task 2 (`world-deploy-e2e-pg`) **returned** (`returns/world-deploy-e2e-pg.md`, `on_time`). New gap surfaced for the lead: the session-create-timeout + snapshot crux (steps 3/4/8) — not yet a planned task. |
| day deadline | 2026-06-23 20:00 +08:00 |
| 18:00 checkpoint | Begin close-down. If a task cannot finish by 20:00, split and return the smallest demonstrable artifact first. |
| merge policy | Task branches only; PR first; lead/admin merge to `main`; no direct push to `main`. |

## Planning intent

Today prioritizes a testable/deployable `world` flow and the product work needed
to make that flow pass. `protocol-api` external-adapter work is now merged into
`origin/main`, so `gagameow` should rebase on latest main, start with
`agent-flavor` headless support, then run the protocol-api external-adapter test
path against the merged baseline.

## Task ledger

| # | Task id | Owner/dev | Branch | Scope | Owned surfaces/files | Required reading | DoD artifact | Deadline | Conflict notes | Handoff order |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `socialware-creator-agent-config` | FatNine | `socialware-creator-agent-config` | Narrowed from broad socialware creator: modify the existing world agent config/create/detail surface so it fits the latest AgentManifest / agent contract design. Do not build a separate creator product today. | `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`; `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex`; `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` agent create/config handlers; focused tests for touched world identity/config surfaces. | `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec3-versioned-artifact.md`; `docs/guide/world-coordination.md`. | Screenshot of the updated world agent config UI plus a real create/configure flow that maps to contract-safe fields, or a precise blocker if the backend contract is not landed. | 2026-06-23 20:00 +08:00 | Touches world identity UI; coordinate with task 2's E2E agent-create needs. Avoid hello renderer and routing UI. | 1 |
| 2 | `world-deploy-e2e-pg` | zylideveloper | `world-deploy-e2e-pg` | Deploy/test world on the PostgreSQL substrate, then manually walk the complete E2E and capture screenshots. If current support is incomplete, return the exact support matrix by 18:00 and point missing product behavior to tasks 1/3. | `docs/guide/world-e2e-seed.md`; `scripts/world_e2e_seed.exs`; deployment/runbook/evidence notes; no product UI edits unless the runbook hook itself is wrong. | `docs/guide/world-e2e-seed.md`; `docs/guide/world-coordination.md`; `docs/together/2026-06-22/review.md`; today's plan and handoffs. | Full screenshot-backed E2E report covering login, agent create/login, session chat, routing/team routing, hello creation, public hello link, world hello visibility, and cross-surface conversation. | 2026-06-23 20:00 +08:00 | Owns environment/evidence. Product gaps should be returned early instead of expanding this branch. | 2 |
| 3 | `world-hello-convergence` | zhaomaota97 | `world-hello-convergence` | Complete world hello化 needed by the E2E: hello page creation/opening, operator-side page visibility, public hello link, and session/external conversation coherence. | `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` or additive world page/session surface; `apps/ezagent_plugin_hello` PageView/renderer glue; minimal WorldLive route/action glue if needed. | `docs/superpowers/handoffs/2026-06-22-hello-phase0-status.md`; `docs/together/2026-06-22/returns/hello.md`; `docs/guide/world-coordination.md`; task 2 support matrix when available. | Screenshots showing hello app/page created, rendered in world, reachable externally, and conversation state visible across world and public page. | 2026-06-23 20:00 +08:00 | Owns hello rendering/entrypoints. Task 1 must not independently edit this renderer path. | 3 |
| 4 | `agent-flavor-headless-protocol-api` | gagameow | `agent-flavor-headless-protocol-api` | Rebase on latest `origin/main`, then add headless agent flavors for the current agent-flavor path: `claude -p` and `codex remote`. After the headless slice is underway, run protocol-api external-adapter testing against the merged #896 baseline. | `apps/ezagent_plugin_cc`; `apps/ezagent_plugin_codex`; `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`; `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`; `apps/ezagent_plugin_protocol_api`; `scripts/e2e_init_protocol_api.sh`; focused plugin/bridge/protocol-api tests and runbook notes. | `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`; `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`; `docs/together/2026-06-22/review.md` Addendum 2. | Evidence that `claude -p` and `codex remote` headless paths can be selected/spawned or a precise unsupported matrix; protocol-api external-adapter test report against latest main. | 2026-06-23 20:00 +08:00 | Mostly independent of world UI. Protocol-api is no longer waiting on merge; sequence is headless first, then external-adapter testing on latest main. | 4 |

## Shared world E2E acceptance flow

`world-deploy-e2e-pg` owns the evidence, but all world tasks must preserve this
target:

1. Register or log in through the normal web flow.
2. Create a `cc` agent from world and complete its login/credential path.
3. Open a session and have a real conversation with the agent.
4. Create a routing table / session routing rule and verify team routing behavior.
5. Create a hello page/app.
6. Open the external hello/customer link and confirm the page is reachable without login when public.
7. In the world session page, see the hello conversation/page state.
8. Send messages across the session/external hello surface and confirm both sides reflect the interaction.

## Current support check before dispatch

| Area | Static support seen | Plan consequence |
|---|---|---|
| World agent create/config | Existing world `Identities.tsx` has `AgentNewForm`, agent detail, API keys, and extensions; `world_live.ex` currently dispatches `flavor`, `name`, `cwd`, `caps`, `with_pty`. | FatNine adapts this existing page to the AgentManifest/agent-contract shape instead of building a separate creator. |
| Full deployed E2E | Existing docs/runbook and seed files exist, but full PG/manual screenshot flow must be reproved. | zylideveloper owns deploy/runbook/evidence and must return unsupported steps by 18:00. |
| Hello world convergence | Hello plugin has PageView/renderer and public `/socialware/customer`; world still contains temporary hello preview code. | zhaomaota97 owns the product convergence needed for E2E steps 5-8. |
| Agent flavors/headless | `cc` and `codex` are registered agent flavors; current create path has special `cc`/`codex` file-flavor branches. | gagameow starts by adding or proving `claude -p` and `codex remote` headless choices through the existing flavor path. |
| Protocol-api external adapter | #896 is merged on `origin/main` via the dev-together lead path: `131bfd0a`, `2ad0c42d`, `fc341c9d`, `d8b913d7`, `593aeeca`, `58c9ed12`, `ac4d7128`; latest docs correction is `56148805`. Prior gates were PG precommit 4600+ tests with 0 failures plus live E2E echo and DeepSeek. | gagameow rebases on latest main and can run protocol-api external-adapter testing after the headless flavor slice is underway. |

## Conflict map

| Shared surface/file | Tasks | Serialization owner | Rule |
|---|---|---|---|
| `Identities.tsx` / world agent create/config UI | 1, 2 | FatNine | Task 2 may report E2E findings, but UI edits for agent config belong to task 1. |
| `Conversation.tsx` / hello page rendering | 2, 3 | zhaomaota97 | Task 2 records evidence/blockers; task 3 owns product fixes. |
| World runbook/seed/evidence | 2, maybe 3 | zylideveloper | Other branches consume the same recipe and do not invent separate boot flows. |
| Agent flavor registry / cc/codex plugin flavor wiring | 4, maybe 1 conceptually | gagameow | Task 1 should treat backend contract gaps as blockers unless the UI adapter can stay purely additive. |
| Protocol-api external adapter | 4 | gagameow | Start with headless agent flavor. Protocol-api is merged; test against latest main after rebasing. |

## Parallelization

- FatNine, zhaomaota97, and gagameow can start immediately.
- zylideveloper starts immediately too, but its 18:00 support matrix is the
  coordination checkpoint for world product gaps.
- If any task cannot finish by 20:00, return the smallest demonstrable artifact
  plus the exact blocker; do not keep a large unmerged branch open silently.

## Handoff order

1. `socialware-creator-agent-config`
2. `world-deploy-e2e-pg`
3. `world-hello-convergence`
4. `agent-flavor-headless-protocol-api`

## Discuss-first triggers

- Any change to CapBAC/authorization semantics, raw capability grants, or live
  session-management authority.
- Any broad world navigation/restyle or replacement of major world surfaces.
- Any change to the AgentManifest schema/runtime contract instead of adapting
  UI/adapter code to the current contract.
- Any plan to block `agent-flavor` headless work on stale protocol-api branches
  instead of rebasing to latest main.
