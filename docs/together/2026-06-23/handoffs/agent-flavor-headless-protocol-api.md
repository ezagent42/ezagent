# Handoff: Agent Flavor Headless + Protocol-API Follow-up

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** gagameow
> **Tracking:** `agent-flavor-headless-protocol-api` · **Base:** `origin/main` @ `56148805`
> **Status:** confirmed — rebase latest main; protocol-api #896 is merged, so testing is no longer waiting on that dependency.

## 0. Mission

Add or prove headless agent flavor support for the current agent-flavor path:
`claude -p` and `codex remote`. Then run protocol-api external-adapter testing
against latest `origin/main`, where #896 has already landed. Keep the sequencing:
headless flavor first, protocol-api external-adapter validation next.

## 1. Required reading before writing code

1. Skill `ezagent-developer`.
2. The `dev-together` skill and handoff standard.
3. `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`.
4. `docs/superpowers/specs/2026-06-21-agent-contract-spec1-manifest-compile-fallback.md`.
5. `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`.
6. `docs/together/2026-06-22/review.md` Addendum 2.
7. `docs/together/2026-06-23/plan.md`.

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | First phase | Agent-flavor headless support comes first. |
| 2 | Required headless targets | `claude -p` and `codex remote`. |
| 3 | Protocol-api | #896 is merged on `origin/main`; test against latest main after the headless slice is underway. |
| 4 | Deadline | 2026-06-23 20:00 +08:00; return headless evidence plus the protocol-api retest status on latest main. |

## 2.1 Merged protocol-api baseline

Before coding, rebase or recreate the task branch from latest `origin/main`.
The protocol-api baseline is already present on main:

- `131bfd0a` feat: Phase-0 OpenAI/Anthropic compatible inbound API
- `2ad0c42d` fix: stale-base compile warnings
- `fc341c9d` fix: move migration to `priv/repo_pg`
- `d8b913d7` fix: uri_query scan + manifest annotations
- `593aeeca` fix: `:request_scoped` adapter + per-tenant table arch compliance
- `58c9ed12` test: port E2E script to PostgreSQL
- `ac4d7128` docs: 6-22 review Addendum 2
- `56148805` docs: corrected #896 merged-commit SHAs after post-merge rebases

PR #896 is closed because it was merged through the dev-together lead path. The
reported baseline gates were PG precommit 4600+ tests with 0 failures plus live
E2E double green: echo and DeepSeek `1+1 equals 2.`.

## 3. Current code pointers

- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex`
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
- `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex`
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`
- `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`
- `apps/ezagent_plugin_protocol_api`
- `scripts/e2e_init_protocol_api.sh`
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

Phase 2: Run protocol-api testing on the merged baseline.
- Run the external-adapter test path against latest `origin/main` after rebasing.
- Treat #896's prior green gates as baseline evidence, not as a substitute for
  the task return if the headless work changes any relevant agent path.
- If a new failure appears, separate regression-from-main from headless-slice
  fallout with exact commands and logs.

## 5. Definition of Done

- [ ] Evidence that `claude -p` can be selected/spawned or a precise unsupported matrix.
- [ ] Evidence that `codex remote` can be selected/spawned or a precise unsupported matrix.
- [ ] Focused tests/transcript for the chosen headless path.
- [ ] Protocol-api external-adapter test report against latest `origin/main`.
- [ ] Return states the exact main SHA tested and whether failures, if any, are baseline or headless-slice fallout.

## 6. Discuss-first vs deferred

**Discuss-first:** changing `AgentFlavorRegistry` semantics, changing
AgentManifest runtime schema, changing credential/capability behavior, or
reworking protocol-api external adapter architecture.

**Deferred:** broad protocol-api cleanup unrelated to external-adapter testing,
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
