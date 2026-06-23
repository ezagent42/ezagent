# Handoff: Socialware Creator - World Agent Config Contract UI

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** FatNine
> **Tracking:** `socialware-creator-agent-config` · **Base:** `origin/main` @ `deebe994`
> **Status:** confirmed — narrowed scope. This is not the broad socialware creator MVP.

## 0. Mission

Modify the existing `world` agent config/create/detail page so it fits the
latest AgentManifest / agent contract design. Do not build a separate creator
surface today. The useful launch slice is: operators can create/configure agents
from world using contract-safe fields, and the page explains/collects the data
needed by the current backend contract without leaking derived config or raw caps.

## 1. Required reading before writing code

1. Skill `ezagent-developer`.
2. The `dev-together` skill and handoff standard.
3. `docs/guide/world-coordination.md`.
4. `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`.
5. `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`.
6. `docs/superpowers/specs/2026-06-21-agent-contract-spec3-versioned-artifact.md`.
7. `docs/together/2026-06-23/plan.md`.

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | Scope | Existing world agent config/create/detail surface only. |
| 2 | Product framing | Keep the task name lineage as socialware creator, but the actual implementation is agent-config contract adaptation. |
| 3 | Contract posture | UI adapts to the current AgentManifest/agent-contract shape; do not redesign the runtime contract. |
| 4 | Deadline | 2026-06-23 20:00 +08:00; at 18:00 return the smallest demonstrable UI/config artifact if full flow cannot finish. |

## 3. Current code pointers

- `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`
  - `AgentNewForm` currently submits `flavor`, `name`, `cwd`, `caps`, `with_pty`.
  - `AgentDetail`, `AgentApiKeys`, and `AgentExtensions` are the adjacent config/detail surfaces.
- `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex`
  - builds state for `agent_new_form`, `agent_detail`, `agent_api_keys`, and `agent_extensions`.
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
  - `dispatch_agent_create/2` calls `Ezagent.Workspace.create_agent/3`.
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`
  - current backend create path has special `cc`/`codex` file-flavor branches and generic direct-spawn flavor handling.

## 4. Phased plan

Phase 0: Map UI fields to the current contract.
- Identify which current fields are author fields, executor params, or derived/backend fields.
- Keep derived config out of author input.
- If backend support for a desired contract field is missing, surface a precise blocker instead of inventing a parallel storage path.

Phase 1: Adapt the existing world UI.
- Update `AgentNewForm` and adjacent detail/config surfaces to present the contract-safe shape.
- Preserve the existing world layout and component patterns.
- Prefer additive state fields from `identity_data.ex`; do not broad-rewrite the identities surface.

Phase 2: Verify a real create/configure path.
- Create or configure an agent through the updated world page.
- Capture a screenshot of the updated form/detail page.
- Capture the resulting agent URI/status or exact backend blocker.

## 5. Definition of Done

- [ ] Screenshot of the updated world agent config/create page.
- [ ] Evidence of a real create/configure attempt using contract-safe fields.
- [ ] Agent detail/config page shows the relevant contract/executor status without exposing derived config as editable author data.
- [ ] No broad socialware creator route/product is introduced.
- [ ] No CapBAC or AgentManifest runtime schema change is made without discuss-first approval.
- [ ] Focused tests/gates for touched files, or a clear note if only docs/UI copy changed.

## 6. Discuss-first vs deferred

**Discuss-first:** changing AgentManifest schema, changing CapBAC grants, moving
agent creation out of `Ezagent.Workspace.create_agent/3`, adding a new world
route-level surface, or changing broad world navigation.

**Deferred:** a full socialware creator product, template/team editors, live
routing/team management, advanced manifest versioning UI.

**Never deferred here:** a clear, launch-usable world agent config page or an
exact blocker explaining why the backend contract prevents it today.

## 7. Conflict avoidance

This task owns world identity/agent config UI. Do not edit hello page rendering
or session routing UI. Coordinate with `world-deploy-e2e-pg` if the E2E finds
agent-create gaps, but keep code ownership here.

## 8. Merge model

Work on branch `socialware-creator-agent-config`. PRs merge into the task branch
first. Keep rebased on `main`. The lead merges to `main` only through PR/admin
merge after the return is reviewed.
