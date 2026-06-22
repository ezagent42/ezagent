# PostgreSQL-only Migration Handoff

Date: 2026-06-22
Worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/pg-compat-audit`
Branch: `pg-compat-audit`
Base: `origin/main` at `3790d112` (`feat(infra): CF Email Worker for ezagent.chat inbound mail cache (task #88) (#894)`)

## Current State

This branch has been rebased onto latest `origin/main`, including the login-with-email merge and the CF Email Worker follow-up.

Commit currently at handoff:

- latest `pg-compat-audit` commit subject: `feat(db): migrate runtime storage to postgres`
- verify the exact hash with `git log --oneline --decorate --max-count=3`

The final Codex push step should verify:

```bash
git status --short --branch
git ls-remote --heads origin pg-compat-audit
```

## Scope Completed

The branch now targets PostgreSQL-only runtime storage:

- Switched `EzagentCore.Repo` from SQLite to PostgreSQL/Postgrex.
- Added isolated local Docker PostgreSQL config in `docker-compose.pg.yml`.
- Added PostgreSQL baseline migration under `apps/ezagent_core/priv/repo_pg`.
- Updated dev/test/runtime Repo config to PostgreSQL and removed runtime `DATABASE_PATH`.
- Replaced runtime SQLite side paths with Ecto/PostgreSQL-compatible code.
- Converted home backup/restore to `pg_dump` / `pg_restore`.
- Added `database_agnostic_guard_test` to prevent new runtime SQLite coupling.
- Converted World admin data reads from raw SQLite-specific SQL to Ecto/schemaless PG-compatible reads.
- Rebased over login-with-email and the CF Email Worker mainline update, and updated `scripts/world_e2e_seed.exs` so the admin has a verified email login (`admin@ezagent.chat` / `worlddev` by default).
- Fixed `mix ezagent.home.restore` so it can restore into an empty PG database without starting the full app before schema restore.
- Fixed the post-rebase duplicate `InviteCode` per-tenant invariant entry.
- Split `Ezagent.World.CallerDisplay` out of `WorldLive` to keep the architecture oversized-module cap green after the main rebase.
- Updated `repair_orchestrator_test` to use `EzagentCore.DataCase` instead of a hand-written SQL sandbox checkout; this reuses the existing stable shared-owner / live-Kind drain logic needed under PostgreSQL.

## Important Files

- `docker-compose.pg.yml`
- `config/dev.exs`
- `config/test.exs`
- `config/runtime.exs`
- `apps/ezagent_core/mix.exs`
- `mix.lock`
- `apps/ezagent_core/priv/repo_pg/migrations/20260622000000_pg_baseline.exs`
- `apps/ezagent_core/lib/ezagent/home/migration.ex`
- `apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`
- `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex`
- `apps/ezagent_core/lib/ezagent/persistence/database_diagnostics.ex`
- `apps/ezagent_core/lib/ezagent/persistence/transient_retry.ex`
- `apps/ezagent_core/test/invariants/database_agnostic_guard_test.exs`
- `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/caller_display.ex`
- `apps/ezagent_domain_session/test/integration/repair_orchestrator_test.exs`
- `scripts/world_e2e_seed.exs`
- `docs/guide/world-e2e-seed.md`
- `docs/superpowers/plans/2026-06-22-pg-only-migration.md`

## Local PostgreSQL

Test DB defaults:

- host: `127.0.0.1`
- port: `55432`
- database: `ezagent_pg_compat_test`
- user/password: `ezagent_pg_compat`

Bring up and reset:

```bash
docker compose -f docker-compose.pg.yml up -d
MIX_ENV=test mix ecto.drop --force
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

## Verification Completed

Fresh verification after the PostgreSQL migration and latest-main rebase:

```bash
MIX_ENV=test mix ecto.drop --force
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test EZAGENT_HOME=/tmp/ezagent_pg_verify WORLD_E2E_ADMIN_PW=worlddev mix run scripts/world_e2e_seed.exs
MIX_ENV=test mix run -e 'case Ezagent.Registration.principal_for_email("admin@ezagent.chat") do {:ok, uri} -> IO.puts("principal=#{URI.to_string(uri)}"); case Ezagent.Entity.authenticate(uri, "worlddev") do {:ok, _} -> IO.puts("auth=ok"); other -> IO.inspect(other, label: "auth") end; other -> IO.inspect(other, label: "principal") end'
```

Output confirmed:

- `principal=entity://system/user/admin`
- `auth=ok`

Focused PG backup/restore:

```bash
MIX_ENV=test EZAGENT_HOME=/tmp/ezagent_pg_verify EZAGENT_PROFILE=default \
  mix ezagent.home.backup --out /private/tmp/ezagent-pg-backup-post-rebase-20260622.tar.gz

MIX_ENV=dev mix ecto.drop --force
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ezagent.home.restore \
  --from /private/tmp/ezagent-pg-backup-post-rebase-20260622.tar.gz \
  --home /private/tmp/ezagent-pg-restore-post-rebase-20260622 \
  --profile default \
  --force
```

Focused tests:

```bash
MIX_ENV=test mix test \
  apps/ezagent_core/test/integration/home_migration_test.exs \
  apps/ezagent_core/test/ezagent/home_test.exs \
  --include umbrella_only --seed 0

MIX_ENV=test mix test \
  apps/ezagent_web/test/ezagent_web/controllers/login_email_test.exs \
  apps/ezagent_web/test/ezagent_web/world_host_routing_test.exs \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs \
  apps/ezagent_plugin_world/test \
  --seed 0

MIX_ENV=test mix test \
  apps/ezagent_web/test/api_v1_controller_test.exs \
  apps/ezagent_core/test/e2e \
  apps/ezagent_domain_session/test/e2e \
  apps/ezagent_web/test/demo_smoke_test.exs \
  --include umbrella_only --seed 0

MIX_ENV=test mix test \
  apps/ezagent_domain_session/test/integration/repair_orchestrator_test.exs \
  --seed 344293

MIX_ENV=test mix test apps/ezagent_domain_session/test --seed 344293
```

CLI smoke:

```bash
MIX_ENV=test mix ezagent.workspace.create pg-cli-smoke-$(date +%s)
MIX_ENV=test mix ezagent.workspace.create_session system pg-cli-session-$(date +%s) --template default
MIX_ENV=test mix ezagent.user.token entity://system/user/admin --mint --label pg-compat-smoke
```

Final gates:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix ezagent.arch.scan
mix precommit
```

Final result:

- `mix format --check-formatted`: passed
- `mix compile --warnings-as-errors`: passed
- `mix ezagent.arch.scan`: passed
- `mix precommit`: passed, seed `123209`

Precommit note:

- One earlier full `mix precommit` run after the latest-main rebase failed once in `apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs` with `{:error, :no_such_actor}` during setup.
- Follow-up root-cause check did not reproduce it: the same file with seed `69714` passed, and the whole `apps/ezagent_domain_session/test` suite with seed `69714` passed.
- A subsequent full `mix precommit` passed with seed `123209`; a later full run exposed the same PG sandbox class in `repair_orchestrator_test`.
- Root cause for the `repair_orchestrator_test` failure: the test hand-rolled `Sandbox.checkout/1` and `Sandbox.mode/2`, bypassing `EzagentCore.DataCase`'s stable shared-owner and live-Kind drain/allow logic. After switching the test to `DataCase`, the failing file and the whole `ezagent_domain_session` app passed with seed `344293`.

Expected log noise observed during tests:

- test-only Feishu credential warnings
- SQL Sandbox owner-exit/disconnect logs from async/background Kind tasks
- expected negative-path plugin contract errors from fixture plugins
- expected login silent-drop warnings in tests

## Browser / Host Routing Note

World routes are intentionally host-scoped in `EzagentWeb.Router`:

```elixir
scope "/", EzagentPluginWorld, host: "world." do
  ...
end
```

So `/sessions` under `localhost` or `127.0.0.1` falls through to the fallback route unless the request Host matches `world.*`. This is not a PostgreSQL issue. For PG functionality validation, CLI/API/LV tests were used because the planned architecture treats LV/CLI/API as same-server paths over the same persistence layer.

No successful browser visual E2E is claimed here. The PG acceptance evidence is from ExUnit LV/API/scenario tests, CLI smoke, and backup/restore CLI smoke.

## Lead Programmer Prompt

Please review and merge `/Users/h2oslabs/Workspace/esr-ng/.worktrees/pg-compat-audit`.

Start with:

```bash
cd /Users/h2oslabs/Workspace/esr-ng/.worktrees/pg-compat-audit
git status --short --branch
git log --oneline --decorate --max-count=8
docker compose -f docker-compose.pg.yml up -d
mix precommit
```

Review focus:

- PostgreSQL baseline schema parity in `apps/ezagent_core/priv/repo_pg/migrations/20260622000000_pg_baseline.exs`
- Backup/restore behavior in `Ezagent.Home.Migration` and `mix ezagent.home.restore`
- Runtime SQLite dependency guard coverage in `database_agnostic_guard_test`
- World admin data PG-compatible reads
- latest-main rebase compatibility in `scripts/world_e2e_seed.exs`

Merge caveats:

- Browser E2E was not used as the final PG gate because World UI routes require a `world.*` Host.
- Feishu live-tier behavior was not exercised because real external credentials are not part of this local validation.
