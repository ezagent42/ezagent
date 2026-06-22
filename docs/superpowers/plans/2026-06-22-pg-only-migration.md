# PostgreSQL-Only Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ezagent from SQLite-backed persistence to PostgreSQL-only persistence in the `pg-compat-audit` worktree, including isolated local PostgreSQL, runtime side-path cleanup, and PG dump/restore.

**Architecture:** `EzagentCore.Repo` becomes a PostgreSQL repo. SQLite-specific migration history is replaced for active bootstrap by a PostgreSQL baseline migration path. Feature code must use Ecto or core persistence helpers; database-specific details are contained under `Ezagent.Persistence.*`.

**Tech Stack:** Phoenix/Ecto, `postgrex`, Docker Compose PostgreSQL, `pg_dump`, `pg_restore`, ExUnit.

---

## File Structure

- Create `docker-compose.pg.yml`: persistent local PostgreSQL container bound to `127.0.0.1:55432`.
- Modify `apps/ezagent_core/mix.exs`: replace `ecto_sqlite3` with `postgrex`.
- Modify `apps/ezagent_core/lib/ezagent_core/repo.ex`: use `Ecto.Adapters.Postgres`.
- Modify `config/dev.exs`, `config/test.exs`, `config/runtime.exs`: PostgreSQL connection config, no `DATABASE_PATH`.
- Create `apps/ezagent_core/priv/repo_pg/migrations/20260622000000_pg_baseline.exs`: PG baseline schema.
- Modify Repo config `:priv` to point at `priv/repo_pg` so old SQLite migrations are not replayed.
- Modify `apps/ezagent_core/test/invariants/database_agnostic_guard_test.exs`: no SQLite side paths outside explicit PG helpers.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex`: Ecto query DSL instead of raw SQL.
- Create `apps/ezagent_core/lib/ezagent/persistence/transient_retry.ex`: adapter-aware transient retry for PostgreSQL.
- Create `apps/ezagent_core/lib/ezagent/persistence/database_diagnostics.ex`: PostgreSQL diagnostics for stress task.
- Modify `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex`: call retry helper, no `Exqlite`.
- Modify `apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex`: call diagnostics helper, no `PRAGMA`.
- Modify `apps/ezagent_core/lib/ezagent/home/migration.ex`: backup/restore stages use `pg_dump`/`pg_restore`, still copy EZAGENT_HOME subdirs and rewrite paths after restore.
- Modify `apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex` and `apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`: remove `:exqlite` startup, update docs/errors for PostgreSQL.
- Add focused tests under `apps/ezagent_core/test/ezagent/persistence/` and update existing invariants.

## Task 1: Isolated PostgreSQL Runtime

**Files:**
- Create: `docker-compose.pg.yml`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] Add Docker Compose service `pg-compat-postgres` using `postgres:16`, port `127.0.0.1:55432`, named volume `ezagent_pg_compat_data`.
- [ ] Add environment defaults:
  - `POSTGRES_HOST=127.0.0.1`
  - `POSTGRES_PORT=55432`
  - `POSTGRES_USER=ezagent_pg_compat`
  - `POSTGRES_PASSWORD=ezagent_pg_compat`
  - `POSTGRES_DB=ezagent_pg_compat_dev`
- [ ] Configure `EzagentCore.Repo` with PostgreSQL hostname/port/username/password/database.
- [ ] Set test DB name to `ezagent_pg_compat_test#{MIX_TEST_PARTITION}`.
- [ ] Set `priv: "priv/repo_pg"` in Repo config.
- [ ] Verify red/green with `mix ecto.create` after Docker starts.

## Task 2: Repo and Dependency Switch

**Files:**
- Modify: `apps/ezagent_core/mix.exs`
- Modify: `apps/ezagent_core/lib/ezagent_core/repo.ex`
- Modify: `mix.lock`

- [ ] Replace `{:ecto_sqlite3, ">= 0.0.0"}` with `{:postgrex, ">= 0.0.0"}`.
- [ ] Change Repo adapter to `Ecto.Adapters.Postgres`.
- [ ] Run `mix deps.get`.
- [ ] Verify compile reaches schema/migration errors rather than SQLite dependency errors.

## Task 3: PostgreSQL Baseline Migration

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260622000000_pg_baseline.exs`
- Modify if necessary: schema modules whose field types conflict with PG.

- [ ] Write a baseline migration for current logical tables:
  `invocations`, `dlq`, `kind_snapshots`, `messages`, `message_routings`, `routing_rules`,
  `workspaces`, `users`, `entity_tokens`, `entity_profiles`, `app_settings`,
  `magic_link_tokens`, `template_tags`, `read_markers`, `workspace_magic_link_rules`,
  `external_mirror_bindings`, `agent_lineage`, credential tables, socialware tables,
  `invite_codes`, and indexes/constraints currently relied on by schemas.
- [ ] Use PostgreSQL-native types where useful but keep schema compatibility:
  `:binary` for snapshot blobs, `:map`/`:jsonb` only where schema fields are `:map`,
  `:utc_datetime_usec` timestamps, string primary keys where schemas expect strings.
- [ ] Run `MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate`.
- [ ] Fix migration/schema mismatches until migrations complete.

## Task 4: Runtime SQLite Side-Path Cleanup

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex`
- Create: `apps/ezagent_core/lib/ezagent/persistence/transient_retry.ex`
- Create: `apps/ezagent_core/lib/ezagent/persistence/database_diagnostics.ex`
- Modify: `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex`
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex`
- Modify: `apps/ezagent_core/test/invariants/database_agnostic_guard_test.exs`

- [ ] Write failing tests for:
  - guard rejects SQLite side paths outside persistence helpers.
  - transient retry retries DBConnection/Postgrex transient failures.
  - World admin data returns expected rows through Ecto query DSL.
- [ ] Convert World admin reads to Ecto schemaless queries.
- [ ] Move transient write retry into `Ezagent.Persistence.TransientRetry`.
- [ ] Move DB diagnostic string construction into `Ezagent.Persistence.DatabaseDiagnostics`.
- [ ] Run focused tests until green.

## Task 5: PostgreSQL Dump/Restore

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/home/migration.ex`
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex`
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`
- Add/modify tests under `apps/ezagent_core/test/ezagent/home_migration_test.exs`

- [ ] Replace SQLite DB file copy with `pg_dump --format=custom --no-owner --no-acl --file <staging>/db/ezagent_core.dump`.
- [ ] Store DB connection metadata in `MANIFEST.json` without passwords.
- [ ] On restore, run `pg_restore --clean --if-exists --no-owner --no-acl --dbname <target url> <dump>`.
- [ ] Keep subdir copy and runtime skeleton behavior.
- [ ] After restore, run path rewrite against restored `kind_snapshots` rows through Repo queries, not direct SQLite file mutation.
- [ ] Update CLI docs and remove `Application.ensure_all_started(:exqlite)`.

## Task 6: Verification

**Commands:**
- `docker compose -f docker-compose.pg.yml up -d`
- `mix deps.get`
- `MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate`
- `mix test apps/ezagent_core/test/invariants/database_agnostic_guard_test.exs`
- `mix test apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
- `mix test apps/ezagent_plugin_world/test`
- `mix test apps/ezagent_core/test/ezagent/ecto/kind_snapshot_concurrent_upsert_test.exs`
- `mix format --check-formatted`
- `mix precommit`

If `mix precommit` fails for known unrelated local email/Swoosh or sandbox ownership failures, record the exact failure and keep focused PG evidence separate.
