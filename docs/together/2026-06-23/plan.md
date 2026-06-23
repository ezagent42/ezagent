# dev-together plan - 2026-06-23

_status: approved for dispatch by Allen_

## Day metadata

| Field | Value |
|---|---|
| planned_at | 2026-06-23 11:23:06 +08:00 |
| timezone | Asia/Shanghai |
| lead | Allen + Codex lead support |
| base | `origin/main` @ `deebe994` |
| day deadline | 2026-06-23 20:00 +08:00 |
| 18:00 checkpoint | Begin close-down. If a task cannot finish by 20:00, split and return the smallest demonstrable artifact first. |
| merge policy | Task branches only; PR first; lead/admin merge to `main`; no direct push to `main`. |

## Planning intent

Today prioritizes a testable/deployable `world` flow and the product work needed
to make that flow pass. `protocol-api` external-adapter testing may wait for
later merges, so `gagameow` starts with `agent-flavor` headless support first
and only then resumes protocol-api testing when the dependency is available.

## Task ledger

| # | Task id | Owner/dev | Branch | Scope | Owned surfaces/files | Required reading | DoD artifact | Deadline | Conflict notes | Handoff order |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `socialware-creator-agent-config` | FatNine | `socialware-creator-agent-config` | Narrowed from broad socialware creator: modify the existing world agent config/create/detail surface so it fits the latest AgentManifest / agent contract design. Do not build a separate creator product today. | `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`; `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex`; `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` agent create/config handlers; focused tests for touched world identity/config surfaces. | `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec3-versioned-artifact.md`; `docs/guide/world-coordination.md`. | Screenshot of the updated world agent config UI plus a real create/configure flow that maps to contract-safe fields, or a precise blocker if the backend contract is not landed. | 2026-06-23 20:00 +08:00 | Touches world identity UI; coordinate with task 2's E2E agent-create needs. Avoid hello renderer and routing UI. | 1 |
| 2 | `world-deploy-e2e-pg` | zylideveloper | `world-deploy-e2e-pg` | Deploy/test world on the PostgreSQL substrate, then manually walk the complete E2E and capture screenshots. If current support is incomplete, return the exact support matrix by 18:00 and point missing product behavior to tasks 1/3. | `docs/guide/world-e2e-seed.md`; `scripts/world_e2e_seed.exs`; deployment/runbook/evidence notes; no product UI edits unless the runbook hook itself is wrong. | `docs/guide/world-e2e-seed.md`; `docs/guide/world-coordination.md`; `docs/together/2026-06-22/review.md`; today's plan and handoffs. | Full screenshot-backed E2E report covering login, agent create/login, session chat, routing/team routing, hello creation, public hello link, world hello visibility, and cross-surface conversation. | 2026-06-23 20:00 +08:00 | Owns environment/evidence. Product gaps should be returned early instead of expanding this branch. | 2 |
| 3 | `world-hello-convergence` | zhaomaota97 | `world-hello-convergence` | Complete world hello化 needed by the E2E: hello page creation/opening, operator-side page visibility, public hello link, and session/external conversation coherence. | `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` or additive world page/session surface; `apps/ezagent_plugin_hello` PageView/renderer glue; minimal WorldLive route/action glue if needed. | `docs/superpowers/handoffs/2026-06-22-hello-phase0-status.md`; `docs/together/2026-06-22/returns/hello.md`; `docs/guide/world-coordination.md`; task 2 support matrix when available. | Screenshots showing hello app/page created, rendered in world, reachable externally, and conversation state visible across world and public page. | 2026-06-23 20:00 +08:00 | Owns hello rendering/entrypoints. Task 1 must not independently edit this renderer path. | 3 |
| 4 | `agent-flavor-headless-protocol-api` | gagameow | `agent-flavor-headless-protocol-api` | First add headless agent flavors for the current agent-flavor path: `claude -p` and `codex remote`. After dependent protocol-api merges are available, continue protocol-api external-adapter testing. | `apps/ezagent_plugin_cc`; `apps/ezagent_plugin_codex`; `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`; `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`; focused plugin/bridge tests and runbook notes. | `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`; `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`; `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`; `docs/together/2026-06-22/review.md` protocol-api addendum. | Evidence that `claude -p` and `codex remote` headless paths can be selected/spawned or a precise unsupported matrix; protocol-api external-adapter test report only after dependency branch is available. | 2026-06-23 20:00 +08:00 | Mostly independent of world UI. Do not block on protocol-api; return headless flavor progress even if protocol-api remains waiting. | 4 |

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
| Protocol-api external adapter | Yesterday's review records protocol-api as not ready for main and handed back to the integration branch. | gagameow does not wait on this. Protocol-api testing resumes after the required merges are present. |

## Conflict map

| Shared surface/file | Tasks | Serialization owner | Rule |
|---|---|---|---|
| `Identities.tsx` / world agent create/config UI | 1, 2 | FatNine | Task 2 may report E2E findings, but UI edits for agent config belong to task 1. |
| `Conversation.tsx` / hello page rendering | 2, 3 | zhaomaota97 | Task 2 records evidence/blockers; task 3 owns product fixes. |
| World runbook/seed/evidence | 2, maybe 3 | zylideveloper | Other branches consume the same recipe and do not invent separate boot flows. |
| Agent flavor registry / cc/codex plugin flavor wiring | 4, maybe 1 conceptually | gagameow | Task 1 should treat backend contract gaps as blockers unless the UI adapter can stay purely additive. |
| Protocol-api external adapter | 4 only after dependency is available | gagameow | Start with headless agent flavor. If protocol-api is blocked, record the waiting merge/branch in the return. |

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
- Any plan to block `agent-flavor` headless work on protocol-api merges.
