# dev-together merge stack — 2026-06-22 (lead: Claude)

_returned handoffs in analyzed merge order · dependencies · conflict check · per-entry status_

> Supersedes the earlier single-entry `stack.md` that shipped on the `world-beautify`
> branch (it analyzed only #83 vs `main@a6fa6db3` and is now stale — main advanced).
> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> **Returns analyzed:** 4 active returns + 1 superseded duplicate · current
> `origin/main` at original stack time = `3790d112`. Backfilled on 2026-06-23
> to include the missing Agent Console return and PR closure state.

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
| 2 | #83 world beautify + restructure | `world-beautify` | ✅ **MERGED** `28a90831` (squash) | done — precommit 4584/0 PG + vite build + check:mounts + agent-browser E2E (shadcn world renders); debt: world_live.ex 1036>1000 (cap-bumped 3→4, re-trim follow-up for zyli) |
| 3 | hello @json-render plugin | `hello` (#891) | ✅ **MERGED** `d8c4a7f9` (squash) | done — precommit 4611/0 PG + vite/check:mounts + anon @json-render page E2E (/socialware/customer); fixed hello's stale WorkspaceRegistry.bind/2 warning; note: customer_app esbuild needs zod (web/assets/package.json, installed by `mix assets.setup`) |
| 4 | Agent Console demo (#84) | `agent-console` (#892) | ✅ **MERGED** `798f46bd` (squash) | done — precommit 4611/0 PG; /agent-console-demo loads + renders (Phase-0 mockup); conflict: world-coordination.md table merged. Phase-0 = design demo only (no real authz) |

## Returned-vs-stacked reconciliation (2026-06-23 backfill)

| Return file | Ledger status | Evidence / close state |
|---|---|---|
| `returns/pg-compat-audit.md` | stacked + merged | Landed `db1fb574`; no GitHub PR recorded in this ledger. |
| `returns/world-beautify.md` | stacked + merged | Landed `28a90831`; PR #890 comment+closed on 2026-06-23 as subsumed by main. |
| `returns/hello.md` | stacked + merged | Landed `d8c4a7f9`; PR #891 comment+closed on 2026-06-23 as subsumed by main. |
| `returns/agent-console.md` | stacked + merged | Missing in original ledger; backfilled. Landed `798f46bd`; PR #892 comment+closed on 2026-06-23 as subsumed by main. |
| `returns/world-beautification-restructure.md` | superseded duplicate | Older world-beautify snapshot. Its "fast-forward-able" claim was stale after main advanced; canonical active return is `returns/world-beautify.md`. |

## PR closure loop (2026-06-23 backfill)

These PRs were **not** merged through GitHub. They were integrated through the
lead close path as squash/subsumed commits, then comment+closed so GitHub matches
`main`:

| PR | Author | State after backfill | Main SHA |
|---|---|---|---|
| #890 `world-beautify` | `zyli-developer` | CLOSED | `28a90831` |
| #891 `hello` | `zhaomaota97` | CLOSED | `d8c4a7f9` |
| #892 `agent-console` | `FatNine` | CLOSED | `798f46bd` |

## Close prerequisites
- **PostgreSQL must be running** for all gate re-runs (the suite is PG-only after step 1). Bring up `docker-compose.pg.yml` before close step 1's verification.
- Heads-up Allen before each push to `main` (per remote-op convention).

## Next step
`dev-together close` — execute steps 1→2→3 in order, stopping to surface any entry whose DoD/gates aren't satisfied.
