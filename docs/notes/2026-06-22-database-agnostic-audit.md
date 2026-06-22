# Database-Agnostic Audit

Date: 2026-06-22

Scope: ezagent runtime portability from the current SQLite deployment toward a database-agnostic Ecto surface, with PostgreSQL as the first alternate backend.

This audit intentionally excludes backup/restore. Current backup work is SQLite-specific by product choice, but it is not part of the runtime database portability gate added here.

## Definitions

Not a strong dependency:

- `Ecto.Adapters.SQLite3` in config.
- `ecto_sqlite3` / `exqlite` in `mix.exs` or `mix.lock`.
- SQLite-specific historical migrations that were written for the existing SQLite database.
- Tests that introspect the current SQLite test database.

Strong or migration-blocking dependency:

- Runtime code directly references `Exqlite`.
- Runtime or ops code issues SQLite-specific SQL such as `PRAGMA`, `sqlite_master`, `VACUUM`, or WAL checkpoint commands.
- Feature code uses raw SQL placeholders such as `?1` or `?#{n}` instead of Ecto query APIs.
- Schemaless writes depend on SQLite adapter behavior for JSON/text values without an adapter-aware boundary.

## Guardrail Added

`apps/ezagent_core/test/invariants/database_agnostic_guard_test.exs` statically scans runtime and ops source files and fails if new database-specific side paths appear.

The guard deliberately skips:

- `apps/**/test/**`
- `apps/ezagent_core/priv/repo/migrations/**`
- `apps/ezagent_core/lib/ezagent/home/migration.ex`
- `apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex`
- `apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`

When a future change really needs adapter-specific code, keep it behind a narrow adapter boundary and update the test baseline with a reason. Do not scatter direct database-driver calls or SQL dialect syntax through feature code.

## Current Strong Dependencies

1. `Ezagent.Ecto.KindSnapshot` rescues `Exqlite.Error` and string-matches SQLite's `"Database busy"` message.

   File: `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex`

   Impact: PostgreSQL will not raise `Exqlite.Error`, and transient write conflicts will surface through different exception structs/messages. This blocks a clean backend switch for snapshot writes.

   Direction: move transient write retry into an adapter-aware persistence boundary. Prefer matching DBConnection/Ecto classes where possible, and keep database-specific exception handling isolated.

2. `Ezagent.World.AdminData` uses raw SQL with SQLite positional placeholders.

   File: `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex`

   Impact: SQLite accepts `?1`; PostgreSQL raw queries use `$1`. Because this code calls `Repo.query/2` directly, Ecto cannot translate placeholders.

   Direction: replace these reads with Ecto query DSL. Full schemas are not required; schemaless queries with `from i in "invocations"` and `field(i, :column)` are enough for these admin read models.

3. `mix ezagent.stress` reads SQLite PRAGMA values.

   File: `apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex`

   Impact: diagnostic output is SQLite-only. This is not core business logic, but it will not run unchanged on PostgreSQL.

   Direction: split diagnostics by adapter. Keep SQLite PRAGMAs under a SQLite diagnostics module and add PostgreSQL diagnostics separately if needed.

## Portability Concerns Not Yet Guarded as Strong Runtime Dependencies

1. Schemaless JSON insert paths.

   Files:

   - `apps/ezagent_core/lib/ezagent/dlq.ex`
   - `apps/ezagent_core/lib/ezagent/event_log.ex`
   - `apps/ezagent_core/lib/ezagent/audit.ex`
   - `apps/ezagent_core/lib/ezagent/audit/writer.ex`

   Concern: the code manually JSON-encodes values before schemaless `insert_all/3`. This works with SQLite text columns. On PostgreSQL, if these columns become `jsonb`, passing encoded strings may be wrong or require explicit casting/type handling.

   Direction: introduce schemas or typed changesets for these tables, or centralize JSON encoding in an adapter-aware writer. Decide column types before enabling a PostgreSQL repo.

2. Migration history.

   Files under `apps/ezagent_core/priv/repo/migrations/` include SQLite table rebuilds, `sqlite_master`, `AUTOINCREMENT`, and SQLite column/type assumptions.

   Concern: replaying the existing SQLite migration history against PostgreSQL is unlikely to be viable.

   Direction: for PostgreSQL, create a fresh baseline migration or adapter-specific migration path from the current logical schema. Do not assume the current SQLite migration chain is cross-adapter.

3. SQLite-aware constraint compatibility shims.

   Example: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex`

   Concern: some code names both PostgreSQL-style and SQLite-style constraints. This is not a hard dependency when it exists as an explicit compatibility shim, but it should remain localized.

## Database-Agnostic Refactor Plan

1. Keep SQLite as the current default.

   Add PostgreSQL support as an alternate backend. Do not remove SQLite until self-host/local deployment requirements are intentionally changed.

2. Replace World admin raw SQL.

   Convert the `invocations`, `kind_snapshots`, and `external_mirror_bindings` admin reads to Ecto query DSL. Use schemaless Ecto queries if adding schemas would be too heavy.

3. Isolate transient persistence retry.

   Move `Exqlite.Error` handling out of `KindSnapshot` into a small adapter-aware retry module. The caller should ask for "retry transient write conflicts" without knowing the driver.

4. Normalize schemaless write typing.

   Audit `insert_all("table", rows)` call sites. For durable product tables, prefer schemas or typed writer functions. Decide JSON column behavior for SQLite text versus PostgreSQL `jsonb`.

5. Define PostgreSQL schema bootstrap.

   Add a PostgreSQL baseline migration that represents the current logical schema. Treat older SQLite migrations as the SQLite lineage, not as the canonical cross-database path.

6. Add a PostgreSQL CI/profile spike.

   Add `postgrex` and a separate Repo config only when the previous runtime blockers are removed. Run a focused suite against PostgreSQL first: migrations/bootstrap, snapshot writes, audit/event writes, World admin reads, identity/session core flows.

7. Expand the invariant.

   Once PostgreSQL support exists, extend `database_agnostic_guard_test.exs` to allow adapter-specific code only under explicit modules such as `Ezagent.Persistence.SQLiteDiagnostics` or `Ezagent.Persistence.PostgresDiagnostics`.

## Practical Deployment Reading

For the product deployment goal, switching to PostgreSQL is mostly valuable when the database is externalized and managed, for example ECS plus RDS/Supabase-like Postgres. It does not make Cloudflare Containers simpler by itself unless the app can reliably reach and operate an external Postgres service. The short-term Mac plus Cloudflare Tunnel path can remain SQLite-first while this portability debt is paid down.
