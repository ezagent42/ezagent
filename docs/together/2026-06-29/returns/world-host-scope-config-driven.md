> **Task:** world-host-scope-config-driven
> **Branch:** `fix/world-host-scope-config-driven`
> **PR:** none per handoff
> **Dev:** codex
> **returned_at:** 2026-06-29 16:41 +0800
> **deadline:** 2026-06-29 23:59 +0800
> **deadline_status:** deferred

## What changed
- The remote target branch already contained the main implementation:
  - `EzagentWeb.Router` reads `:world_host_scope` from config.
  - Dev/test keep a host-scoped `world.` route set.
  - Prod compiles apex operator routes through `EzagentWeb.Plugs.WorldHostScope`.
  - The world root `/` remains host-scoped for dev/test, so prod apex `/` stays `EzagentWeb.HomeLive`.
- Added a revert commit for the remote branch's format-only `style(core): apply precommit formatting` commit so this return does not carry unrelated format churn.
- Added the missing grep follow-up in scripts:
  - `scripts/autoservice_tier1_seed.exs` no longer inserts `world.` into every base URL; localhost maps to `world.localhost`, deployed/apex bases stay apex, and `EZAGENT_OPERATOR_BASE_URL` can override.
  - `scripts/demo/agent-create-record.js` no longer documents a hardcoded `host: "world."` assumption.
- Fixed a prod-only compile warning in `Ezagent.Resource.FsResolver`: the test-only registry helper now uses fully qualified module calls, so `MIX_ENV=prod mix compile --warnings-as-errors` has no unused alias. Updated the URI-scan exception line anchor accordingly.

## DoD reconciliation
| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Router `host: "world."` is config-driven; dev/test keep `world.localhost`; deploy uses apex/no host restriction. | met | `apps/ezagent_web/lib/ezagent_web/router.ex`; `apps/ezagent_web/lib/ezagent_web/plugs/world_host_scope.ex`; `config/dev.exs`; `config/test.exs`; `config/prod.exs`. |
| 2 | Grep and fix hardcoded `world.` deploy-domain refs; keep test/dev `world.localhost`. | met | `mix ezagent.arch.scan` reports `hardcoded_deploy_domain_hosts: count=0 cap=0`; remaining local/demo refs are `world.localhost`. |
| 3 | Add arch gate forbidding prod code hardcoded deploy domain/literal host, with exemptions. | met | `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`; `apps/ezagent_core/test/architecture/hardcoded_deploy_domain_test.exs`; baseline cap `hardcoded_deploy_domain_hosts: 0`. |
| 4 | Do not break apex socialware customer routes; `/socialware/*` and operator routes path-disambiguate on apex. | met by static route table | `MIX_ENV=prod mix phx.routes EzagentWeb.Router` shows operator `/admin`, `/sessions`, `/identities` under `EzagentPluginWorld.WorldLive`; `/` under `EzagentWeb.HomeLive`; `/socialware/*` under `EzagentWeb.Socialware.*`. |
| 5 | Self-merge to target, return for coordinator verification; do not merge to main/open PR. | met | Work is committed on the target branch path and will be pushed back to `fix/world-host-scope-config-driven`. No PR opened. |
| 6 | Full gates green, including new gate, socialware P10 E2E, and world tests. | deferred | Static gates below are green. DB-backed test commands and `mix precommit` cannot reach assertions because local Postgres `127.0.0.1:55432` refuses connections; this environment also lacks `docker`, `psql`, and `pg_isready`. Lead/CI should rerun these before merge. |

## Verification
- PASS: `mix compile --force --warnings-as-errors`
- PASS: `mix compile --warnings-as-errors`
- PASS: `MIX_ENV=prod mix compile --warnings-as-errors`
- PASS: `mix ezagent.arch.scan`
- PASS: `mix ezagent.check_invariants`
- PASS: `mix ezagent.check_invariants.lifecycle`
- PASS: `mix ezagent.uri_query.scan`
- PASS: `mix ezagent.doc.scan`
- PASS: `git diff --check`
- PASS: `MIX_ENV=prod mix phx.routes EzagentWeb.Router | rg "WorldLive|HomeLive|/admin|/sessions|/identities|/socialware|GET\\s+/\\s"`
- PASS: `MIX_ENV=test mix phx.routes EzagentWeb.Router | rg "WorldLive|HomeLive|/admin|/sessions|/identities|/socialware|GET\\s+/\\s"`
- BLOCKED: `mix precommit` compiles the umbrella, then fails creating/connecting `EzagentCore.Repo`: `tcp connect (127.0.0.1:55432): connection refused`.
- BLOCKED: `MIX_ENV=test mix test apps/ezagent_core/test/architecture/hardcoded_deploy_domain_test.exs` fails before assertions with the same DB connection refusal.
- BLOCKED: `MIX_ENV=test mix test apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs` fails before assertions with the same DB connection refusal.
- BLOCKED: `MIX_ENV=test mix test apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs` fails before assertions with the same DB connection refusal.
- KNOWN LOCAL DEBT: `mix format --check-formatted` fails on 7 existing unrelated format-debt files. The branch now contains a revert commit for the prior format-only changes.

## Coordinator verification after merge/deploy
- Rebuild/redeploy through deploy-flow.
- Verify `https://app.ezagent.chat/admin` serves `EzagentPluginWorld.WorldLive`.
- Verify `https://app.ezagent.chat/` remains the public/login/customer entry and is not shadowed by world root.
- Verify `https://app.ezagent.chat/identities/agents/new` is reachable for operator create-agent.
- Verify `/socialware/*` customer routes remain reachable on apex.

## Open decisions
- Run the blocked DB-backed gates in CI or a local environment with Postgres on `127.0.0.1:55432` before accepting the branch.
- Decide whether the centralized deploy defaults in config are enough for this slice, or whether a later release-hardening pass should move more host defaults to release env only.

**Method friction:** The handoff required full local gate green, but this workspace has no reachable Postgres and no local DB tooling. That made P10/world verification impossible locally; the return is marked deferred for lead/CI verification.
