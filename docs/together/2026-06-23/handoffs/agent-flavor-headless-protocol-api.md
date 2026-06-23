# Handoff: Agent Flavor Headless + Protocol-API Follow-up

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** gagameow
> **Tracking:** `agent-flavor-headless-protocol-api` · **Base:** `origin/main` @ `deebe994`
> **Status:** confirmed — start with agent-flavor headless work; protocol-api testing may wait for later merges.

## 0. Mission

Add or prove headless agent flavor support for the current agent-flavor path:
`claude -p` and `codex remote`. After the dependent protocol-api branch/merge is
available, continue protocol-api external-adapter testing. Do not block the
headless work on protocol-api.

## 1. Required reading before writing code

1. Skill `ezagent-developer`.
2. The `dev-together` skill and handoff standard.
3. `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`.
4. `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`.
5. `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`.
6. `docs/together/2026-06-22/review.md` protocol-api addendum.
7. `docs/together/2026-06-23/plan.md`.

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | First phase | Agent-flavor headless support comes first. |
| 2 | Required headless targets | `claude -p` and `codex remote`. |
| 3 | Protocol-api | Continue external-adapter testing only after the needed dependency merge/branch is available. |
| 4 | Deadline | 2026-06-23 20:00 +08:00; return headless evidence even if protocol-api remains blocked. |

## 3. Current code pointers

- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex`
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
- `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex`
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`
- `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`
- Existing cc/codex bridge and plugin tests under `apps/ezagent_plugin_cc/test`
  and `apps/ezagent_plugin_codex/test`.

## 4. Phased plan

Phase 0: Confirm the flavor model.
- Determine whether `claude -p` and `codex remote` should be represented as new
  flavors, executor params on existing `cc`/`codex`, or a contract-safe mode
  field.
- If more than one representation has real runtime trade-offs, stop and discuss
  before implementation.

Phase 1: Implement/prove the headless path.
- Wire the selected headless choices through the existing plugin/flavor/create
  path.
- Keep plugin isolation: prefer plugin-local declarations and adapters over
  core edits unless the current registry contract requires a small shared seam.
- Produce focused tests or a runnable transcript proving selection/spawn path.

Phase 2: Resume protocol-api testing when available.
- Once the needed protocol-api merge/branch is present, run the external-adapter
  test path.
- If it is still unavailable by 18:00, record the exact waiting branch/PR and
  return the headless artifact instead of holding the task open.

## 5. Definition of Done

- [ ] Evidence that `claude -p` can be selected/spawned or a precise unsupported matrix.
- [ ] Evidence that `codex remote` can be selected/spawned or a precise unsupported matrix.
- [ ] Focused tests/transcript for the chosen headless path.
- [ ] Protocol-api external-adapter test report if the dependency is available.
- [ ] If protocol-api is blocked, the return names the missing merge/branch and does not count that as headless failure.

## 6. Discuss-first vs deferred

**Discuss-first:** changing `AgentFlavorRegistry` semantics, changing
AgentManifest runtime schema, changing credential/capability behavior, or
reworking protocol-api external adapter architecture.

**Deferred:** broad protocol-api cleanup while dependency is unavailable,
advanced headless UX polish, and non-required agent flavors.

**Never deferred here:** headless support evidence or an exact reason it cannot
land through the current flavor path today.

## 7. Conflict avoidance

This task is independent of `world` UI. Keep world changes out unless a tiny
selection field is explicitly required after the flavor path lands, and then
coordinate with FatNine.

## 8. Merge model

Work on branch `agent-flavor-headless-protocol-api`. PRs merge into the task
branch first. Keep rebased on `main`. The lead merges to `main` only through
PR/admin merge after the return is reviewed.
