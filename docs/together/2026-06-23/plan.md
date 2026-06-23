# dev-together plan — 2026-06-23

_status: draft for Allen review_

## Day metadata

| Field | Value |
|---|---|
| planned_at | 2026-06-23 10:38:02 +08:00 |
| timezone | Asia/Shanghai |
| lead | Allen + Codex lead support |
| day deadline | 2026-06-23 20:00 +08:00 |
| 18:00 checkpoint | Begin close-down. If a task cannot finish by 20:00, split and return the smallest demonstrable artifact first. |
| merge policy | PR first, then admin-merge; no direct push to `main` |
| planning premise | World must become testable/deployable first; world hello化 and socialware creator should ship usable versions today, then iterate after launch. |

## Guardrails

- `plugin-email` / #88 is already under active small-task development. Do not
  include it in the 2026-06-23 dev-together plan.
- `world_live` oversized debt is already resolved on `main` by `ebccf695`
  (precommit 4611/0; oversized cap back to 3). Do not include it as today's
  arch-debt work.
- Current planning worktree must stay rebased onto `origin/main` before
  handoffs are written.
- Do not revive yesterday's old Agent Console as a separate product surface.
  Ship the useful slice as `socialware creator`: create/read/launch first,
  live session mutation later after Manage-gate decisions.

## Task ledger

| # | Task id | Owner/dev | Branch | Scope | Owned surfaces/files | Required reading | DoD artifact | Deadline | Conflict notes | Handoff order |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `world-deploy-e2e-pg` | world/dev | `world-deploy-e2e-pg` | Make world reliably testable/deployable on PostgreSQL and produce the full manual E2E checklist. First statically and manually check whether current `main` already supports every E2E step. If not, return the support matrix early and hand the missing product steps to tasks 2/3; the final full E2E may run on `world-hello-convergence` if that is where support lands. | `docs/guide/world-e2e-seed.md`, `scripts/world_e2e_seed.exs`, PG/dev-server runbook, screenshot/evidence checklist. Avoid product UI edits unless the runbook itself is wrong. | `docs/guide/world-e2e-seed.md`; `docs/guide/world-coordination.md`; 2026-06-22 review PG/agent-browser lessons. | Full manual E2E checklist with screenshots where supported; if current main lacks support, a precise support matrix and smallest returned runbook/deploy evidence by 18:00. | 2026-06-23 20:00 +08:00 | Must run first. It defines the shared validation target for tasks 2 and 3; do not hide unsupported steps. | 1 |
| 2 | `world-hello-convergence` | world/hello dev | `world-hello-convergence` | Complete world hello化 needed by the E2E: world can create/open hello apps, render the generated page in the operator session view, expose the public `/socialware/customer` link, and ensure session/chat/customer views stay coherent. If task 1 finds full E2E cannot pass on `main`, this branch owns the product fixes and may become the full E2E branch. | `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` or additive Page/SessionView surface; world route/action glue only if needed; `apps/ezagent_plugin_hello` operator `PageView`/HelloRenderer`; customer/chat links. Keep changes minimal and world-coordination compliant. | `docs/superpowers/handoffs/2026-06-22-hello-phase0-status.md`; `docs/guide/world-coordination.md`; `docs/together/2026-06-22/returns/hello.md`. | Operator creates/opens a hello session, sees generated `@json-render` page in world, opens external customer link, and verifies conversation visibility/interaction between session and external page. | 2026-06-23 20:00 +08:00 | Depends on task 1's support matrix. Touches world UI; update world coordination row in handoff. Avoid broad restyle. | 2 |
| 3 | `socialware-creator-mvp` | socialware/world dev | `socialware-creator-mvp` | Ship a lean socialware creator MVP that directly supports the E2E: create/launch a hello/socialware session, expose links to world session and external customer page, and surface only the read/create actions needed for the workflow. Live team/routing management is not the MVP unless already supported by existing world session UI. | Additive creator surface if needed; `*_data/*_actions` for safe read/create paths; links to existing world/hello/customer routes. Avoid broad CapBAC changes and avoid exposing raw tool runner/caps. | `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md`; `docs/superpowers/specs/2026-06-22-agent-console-manage-gate-proposal.md`; `docs/guide/world-coordination.md`; `docs/superpowers/specs/2026-06-01-unified-kind-creation-via-templates.md`. | A user can open socialware creator, create or launch the hello/socialware app needed by the E2E, and navigate to both the world session and external customer page. Anything beyond the E2E is deferred. | 2026-06-23 20:00 +08:00 | Coordinates with task 2 on hello entrypoints. Do not implement new Manage-gate authority today unless Allen explicitly expands scope. | 3 |

## Shared full E2E acceptance flow

The day is not complete until a human walks this flow on the deployed/testable
world environment and captures screenshots/transcript evidence, or the relevant
task returns a precise unsupported-step matrix by 18:00:

1. Register or log in through the normal web flow.
2. Create a `cc` agent from world and complete its login/credential path.
3. Open a session and have a real conversation with the agent.
4. Create a routing table / session routing rule and verify team routing behavior.
5. Create a hello page/app.
6. Open the external hello/customer link and confirm the page is reachable without login when public.
7. In the world session page, see the hello conversation/page state.
8. Send messages across the session/external hello surface and confirm both sides reflect the interaction.

## Current support check (static, before handoff)

| E2E step | Static support seen on `main` | Plan consequence |
|---|---|---|
| Register/login | Routes exist: `/register`, `/login`; seed docs still need PG refresh. | Task 1 verifies manually. |
| Create `cc` agent | World has `world-agent-new-form`; `world_live.ex` calls `Ezagent.Workspace.create_agent`. | Task 1 verifies; missing credential/login UX must be surfaced by 18:00. |
| Session conversation | World conversation UI and send path exist. | Task 1 verifies with screenshots/transcript. |
| Routing/team routing | Conversation has session routing add/toggle UI and tests; broader team routing UX may be partial. | Task 1 checks support; task 2/3 only fix if needed for E2E. |
| Create hello page/app | `session.hello` Template Class and `App.ensure_app` exist. | Task 2 ensures world exposes a usable path. |
| External hello page | `/socialware/customer` tokenless public path exists for `public_view`. | Task 2 verifies and links from world/creator. |
| See hello page in session | Current `Conversation.tsx` has a temporary iframe preview; `Hello.PageView` exists. | Task 2 removes/de-risks the temporary path or proves it is acceptable for launch. |
| External hello ↔ session interaction | Public chat/customer paths exist, but full two-way interaction across surfaces is not proven by static read. | Task 2 owns product fixes if task 1 cannot pass this on `main`. |

## Conflict map

| Shared surface/file | Tasks | Serialization owner | Rule |
|---|---|---|---|
| world operator UI / `Conversation.tsx` / page rendering | 2, maybe 3 | `world-hello-convergence` | Task 3 must prefer additive creator surface and links. If it needs hello page entrypoints, consume task 2's seam instead of editing the same component independently. |
| world seed/runbook environment | 1, 2, 3 | `world-deploy-e2e-pg` | Tasks 2 and 3 validate against the task 1 recipe. Do not invent separate local boot recipes. |
| `world_live.ex` route/action glue | 2, 3 | lead coordinates | Additive route clauses only; keep scoped and update `SlotRegistry`/manifest if a route-level surface is added. |
| hello PageView / renderer integration | 2, maybe 3 | `world-hello-convergence` | Task 3 should link to created hello apps; renderer plumbing belongs to task 2. |
| Manage-gate / live member-routing mutation | 3 only if explicitly expanded | none today | Out of today's MVP. Keep create/read/launch shippable without resolving all Manage-gate open decisions. |

## Parallelization

- Task 1 starts first and returns a support matrix early if current `main` cannot
  pass the full E2E.
- Task 2 starts code reading immediately and owns hello/world fixes needed by
  unsupported E2E steps.
- Task 3 stays lean and only builds creator capabilities required by the E2E.
  It should avoid shared component edits until task 2 chooses the hello
  entrypoint seam.

## Handoff order

1. `world-deploy-e2e-pg`
2. `world-hello-convergence`
3. `socialware-creator-mvp`

## Discuss-first triggers

- Any change that grants new live session-management authority or implements Manage-gate.
- Any plan to replace major world navigation or restyle existing world components.
- Any deploy path that requires Cloudflare/production credentials instead of a disposable PG stack.
- Any decision to include `plugin-email` #88 or reopen `world_live` oversized work.
