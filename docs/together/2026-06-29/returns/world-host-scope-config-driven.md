> **Task:** world-host-scope-config-driven
> **Branch:** `fix/world-host-scope-config-driven`
> **PR:** https://github.com/ezagent42/ezagent/pull/1089
> **Dev:** codex for zyli
> **returned_at:** 2026-06-29 17:14 +0800
> **deadline:** 2026-06-29 23:59 +0800
> **deadline_status:** on_time

## Return status

Target work is complete and ready for coordinator verification.

Important branch note: the code changes for this handoff have already landed on `origin/main` via PR #1086
(`fbe4caf8 fix(web): world host-scope config-driven ...`). PR #1089 is therefore a return/record PR against
`fix/world-host-scope-config-driven`; after this return update, the PR should only show this return artifact
as a remaining diff versus `main`.

## What changed

- `EzagentWeb.Router` reads the world host scope from config instead of hardcoding `host: "world."`.
- Dev/test keep `world.localhost` behavior through `host: "world."`.
- Deploy/release uses apex/no host restriction for world routes, so `app.ezagent.chat/admin` can serve WorldLive.
- Hardcoded deployed-domain/literal-host references were removed from prod code and scripts.
- Added/kept the arch gate for hardcoded deploy-domain hosts; current count is zero.
- Apex socialware customer routes remain path-separated from operator routes:
  `/socialware/*` stays customer-facing, while `/admin`, `/sessions`, and `/identities` stay operator/world-facing.
- Reverted the earlier format-only `ezagent_core` churn so this return does not carry unrelated formatter changes.

## DoD reconciliation

| # | DoD line | status | proof / note |
|---|---|---|---|
| 1 | Router `host: "world."` is config-driven; dev/test keep `world.localhost`; deploy uses apex/no host restriction. | met | Landed on `main` via #1086. |
| 2 | Grep and fix hardcoded `world.` deploy-domain refs; test/dev `world.localhost` stays allowed. | met | `mix ezagent.arch.scan` reports `hardcoded_deploy_domain_hosts: count=0 cap=0`. |
| 3 | Add arch gate forbidding prod hardcoded deploy domains/literal hosts, with exemptions. | met | `apps/ezagent_core/test/architecture/hardcoded_deploy_domain_test.exs`; invariant scan passes. |
| 4 | Do not break apex socialware customer routes. | met | Static route design keeps `/socialware/*` separate from world operator paths on apex. |
| 5 | Self-merge to target and return for coordinator verification. | met / superseded | Code is already on `main` via #1086; PR #1089 records the handoff return. |
| 6 | Full gates, P10 E2E, and world tests. | targeted pass; full precommit blocked locally | Required targeted gates below pass. Full `mix precommit` exits 2 due to local test DB/tooling issues described below. |

## Verification

Targeted verification run with host Postgres on port 5432, no Docker:

- PASS: `POSTGRES_PORT=5432 mix ezagent.arch.scan`
- PASS: `POSTGRES_PORT=5432 mix ezagent.check_invariants`
- PASS: `POSTGRES_PORT=5432 mix ezagent.check_invariants.lifecycle`
- PASS: `POSTGRES_PORT=5432 mix ezagent.uri_query.scan`
- PASS: `MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_core/test/architecture/hardcoded_deploy_domain_test.exs apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs`
  - `hardcoded_deploy_domain_test`: 6 tests, 0 failures
  - `world_host_routing_test`: 12 tests, 0 failures
  - `socialware_p10_codex_gate_test`: 1 test, 0 failures
- PASS: `ezagent_plugin_world` full app test segment during precommit: 89 tests, 0 failures

Full gate status:

- FAIL (local): `POSTGRES_PORT=5432 mix precommit` exits 2.
- Primary local blockers:
  - test database schema is not aligned: `socialware_delivery_outbox` table is missing, which causes socialware/web/hello feed tests to fail before exercising this host-scope change;
  - local DB tooling is incomplete: `pg_dump` is missing, causing home-migration tests to fail;
  - per-tenant table invariant reports `socialware_delivery_outbox` missing `workspace_uri` and `socialware_customer_outbox` uncategorized in this local DB state;
  - one py np-role test timed out during the long full run.

## Service

Local service was started without Docker, using host Postgres:

- tmux session: `ezagent-phx`
- env: `MIX_ENV=dev PORT=10042 POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 POSTGRES_USER=ezagent_pg_compat POSTGRES_PASSWORD=ezagent_pg_compat POSTGRES_DB=ezagent_pg_compat_dev`
- Smoke checks before return:
  - `http://127.0.0.1:10042/` redirects to `/login`
  - `http://world.localhost:10042/admin` redirects to `/login`

## Coordinator verification

- CI should rerun full `mix precommit` in a migrated test DB environment.
- Deploy-flow should verify `https://app.ezagent.chat/admin` serves WorldLive on apex.
- Verify `https://app.ezagent.chat/` is not shadowed by the world root.
- Verify `/socialware/*` customer routes remain reachable on apex.
