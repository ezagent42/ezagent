# dev-together merge stack — 2026-06-22 (lead: Claude)

_returned handoffs in analyzed merge order · dependencies · conflict check · per-entry status_

> Supersedes the earlier single-entry `stack.md` that shipped on the `world-beautify`
> branch (it analyzed only #83 vs `main@a6fa6db3` and is now stale — main advanced).
> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> **Returns analyzed:** 3 · current `origin/main` = `3790d112`.

## Branch facts (measured)

| Branch | HEAD | base | vs current `origin/main` | FF-able now? |
|---|---|---|---|---|
| `pg-compat-audit` | `db1fb574` | rebased onto `3790d112` | main IS ancestor | ✅ yes |
| `world-beautify` | `67db6e79` | `a6fa6db3` | main NOT ancestor (behind #893+#894) | ❌ needs rebase |
| `hello` (PR #891) | `808553f3` | `world-beautify` | wb IS ancestor of hello | ❌ via wb |

## Merge order (forced)

**1. `pg-compat-audit` → 2. `world-beautify` → 3. `hello`**

Rationale:
- **pg first** — it is the *only* branch already rebased onto current main and FF-able; it is also the most invasive change (DB substrate). Landing it first means wb + hello are rebased onto and verified against the **real target substrate (PostgreSQL)**, which is the correct end state. (If pg went last it would have to absorb wb's React UI + hello's brand-new plugin and re-verify a tree it was never tested against — strictly riskier.)
- **world-beautify second** — hard dependency: `hello` contains wb, so wb must precede hello. wb must be **rebased onto post-pg main** (its "ff-able" claim is stale).
- **hello third** — rebase onto post-pg + post-wb main.

## Conflict analysis

### pg ∩ world-beautify (resolve during wb's rebase, step 2)
Both modify, vs main:
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` — **triple overlap**: login #893 (caller display) + pg (split `Ezagent.World.CallerDisplay` OUT of WorldLive for the arch oversized-module cap) + wb (UI restructure). Most delicate; reconcile wb's UI edits against pg's extracted `CallerDisplay` module.
- `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex` — pg (raw SQL → Ecto/schemaless) + wb (Admin orchestrator dump fix `6db6d876`). Keep pg's PG-compatible reads; layer wb's badge/fields fix on top.
- `config/dev.exs`, `config/test.exs` — pg (PG Repo config) + wb (dev-infra). Keep pg's DB config; add wb's non-DB additions.
- `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs` — pg (InviteCode entry fix) + wb. Keep pg's version; re-check wb's intent.

### world-beautify ∩ main-since-base (#893/#894) (resolve during wb's rebase)
- `world_live.ex` (same triple-overlap as above), `.gitignore` (trivial).

### hello (step 3)
- Inherits wb's resolved base. New app `ezagent_plugin_hello` → wire into `apps/ezagent_web/mix.exs` deps + root release apps + pass `:ezagent_plugin_check`. Must be PG-compatible (`database_agnostic_guard_test`).

### Also-ran / out of scope
- `feat/loom-vertical` (in-flight, not a return today) — touches no `ezagent_plugin_world`/`assets/src`; no conflict.
- My own `plugin-email` (#88) — separate; rebases onto final main after this stack lands.

## Per-entry status

| # | Task | Branch | Status | Close action |
|---|---|---|---|---|
| 1 | PostgreSQL-only migration | `pg-compat-audit` | ✅ **MERGED** `db1fb574` (on main `3768b8e3`) | done — see outcomes |
| 2 | #83 world beautify + restructure | `world-beautify` | ⚠️ needs-rebase | rebase onto post-pg main, resolve 5-file conflict set, re-run gates **under PG** + vite build + visual check, merge |
| 3 | hello @json-render plugin | `hello` (#891) | ⛓️ blocked-by-2 | rebase onto post-wb main, wire new plugin, re-run gates **under PG**, merge |

## Close prerequisites
- **PostgreSQL must be running** for all gate re-runs (the suite is PG-only after step 1). Bring up `docker-compose.pg.yml` before close step 1's verification.
- Heads-up Allen before each push to `main` (per remote-op convention).

## Next step
`dev-together close` — execute steps 1→2→3 in order, stopping to surface any entry whose DoD/gates aren't satisfied.
