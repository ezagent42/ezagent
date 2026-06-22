# Return — PostgreSQL-only migration (pg-compat-audit)

- **Branch:** `pg-compat-audit` (HEAD `db1fb574` — `feat(db): migrate runtime storage to postgres`)
- **Base:** rebased onto current `origin/main` `3790d112` (includes login-with-email #893 + CF Email Worker #894). `origin/main` IS an ancestor of HEAD → **FF-able, no rebase needed**.
- **Author/dev:** (handoff to lead via Allen)
- **Handoff doc:** `docs/superpowers/handoffs/2026-06-22-pg-compat-audit-lead-programmer-handoff.md`

## Scope
Retire runtime SQLite → **PostgreSQL-only**; backup/restore → `pg_dump`/`pg_restore`.
- `EzagentCore.Repo` → Postgrex; `docker-compose.pg.yml`; PG baseline migration `apps/ezagent_core/priv/repo_pg/migrations/20260622000000_pg_baseline.exs`.
- dev/test/runtime Repo config → PG; removed runtime `DATABASE_PATH`.
- runtime SQLite side-paths replaced with Ecto/PG-compatible code; `database_agnostic_guard_test` added to block re-introduction.
- World admin raw SQL → Ecto/schemaless PG-compatible reads (`admin_data.ex`); split `Ezagent.World.CallerDisplay` out of `WorldLive` to keep the arch oversized-module cap green post-rebase.
- home backup/restore → `pg_dump`/`pg_restore`; `mix ezagent.home.restore` fixed to restore into an empty PG DB without starting the full app.
- `scripts/world_e2e_seed.exs` adapted to login-with-email (default `admin@ezagent.chat` / `worlddev`).
- `repair_orchestrator_test` → `EzagentCore.DataCase` (fixes PG sandbox owner / live-Kind drain flake).
- fixed post-rebase duplicate `InviteCode` per-tenant invariant entry.

## DoD artifact (dev-reported)
- `mix precommit` PASSED; seed **445979**.
- Separately verified: `MIX_ENV=test mix ecto.drop/create/migrate`; world seed + admin email auth; PG backup/restore via pg_dump/pg_restore; CLI smoke (workspace/session/token); API/E2E/demo smoke; login/world/plugin_world tests; repair_orchestrator failing-seed regression.

## Known caveats
- No browser visual E2E (verified via LV/CLI/API same-origin reasoning).
- World route requires Host `world.*`; localhost `/sessions` → fallback 404 (pre-existing routing, not a PG regression).
- No live Feishu external creds used.
- Some `PostgreSQL sandbox owner exited` logs during the run; final `mix precommit` (seed 445979) green; the one real flake fixed via `repair_orchestrator_test → DataCase`.

## Merge request
Review (esp. no residual runtime SQLite dep), optionally re-run `mix precommit`, merge → main, then confirm PG-only path + backup/restore still work on main.
