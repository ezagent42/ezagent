# dev-together plan — 2026-06-22

_Backfilled on 2026-06-23 from returns, stack, PR metadata, and main history._

The original `plan.md` for 2026-06-22 was only a scaffold:

> _tasks · scope · owned surfaces/files · per-task branch · cross-task conflict map · handoff order_

That means the day did **not** have a valid dev-together plan at kickoff. The
table below is the recovered ledger of what was actually planned/returned/merged.
Use it as historical accounting, not as evidence that a proper plan existed
before work started.

## Day metadata

| Field | Value |
|---|---|
| Date | 2026-06-22 |
| Lead | Claude acting as lead programmer, with Allen directing/reviewing |
| Planning status | **invalid at kickoff** — placeholder-only plan |
| Backfill source | `returns/`, `stack.md`, `review.md`, PR metadata, main commit history |
| Nominal deadline | 2026-06-22 20:00 Asia/Shanghai (dev-together hook default observed in the day tooling) |
| Close path | Lead squash/subsumed returns into `main`; PRs were closed after the fact on 2026-06-23 |

## Recovered task ledger

| # | Task | Dev / PR author | Branch / PR | Scope | Owned surfaces/files | Return status | Main outcome |
|---|---|---|---|---|---|---|---|
| 1 | PostgreSQL-only runtime migration | Lead / Allen handoff | `pg-compat-audit` | Retire runtime SQLite; PostgreSQL Repo/config/migrations; PG backup/restore; DB-compatible world admin reads | `apps/ezagent_core`, runtime Repo config, backup/restore tasks, world admin data | Returned/recorded late in ledger (`returns/pg-compat-audit.md`, 23:17 backfill record) | Landed `db1fb574` at 2026-06-22 22:30 +08:00 |
| 2 | World UI beautification + product restructure (#83) | `zyli-developer` | `world-beautify`, PR #890 | typed-slot registry, Tailwind/shadcn migration, admin/product restructure, visual DoD | `apps/ezagent_plugin_world`, world assets, world coordination docs | Original return existed; later stale “ff-able” claim superseded after main advanced | Landed as squash/subsumed `28a90831` at 2026-06-22 23:52 +08:00; PR #890 closed 2026-06-23 |
| 3 | Hello @json-render plugin | `zhaomaota97` | `hello`, PR #891 | new `ezagent_plugin_hello`, generated UI page flow, customer/operator renderer work, world temporary Page view | `apps/ezagent_plugin_hello`, `apps/ezagent_web` customer/operator renderer, limited world bridge | Returned after deadline via PR branch; required order after world-beautify | Landed as squash/subsumed `d8c4a7f9` at 2026-06-23 00:05 +08:00; PR #891 closed 2026-06-23 |
| 4 | Agent Console Phase-0 demo + Manage-gate proposal (#84) | `FatNine` | `agent-console`, PR #892 | static design-confirmation demo, authority matrix, Manage-gate protocol proposal | `apps/ezagent_web/priv/static/agent-console-demo`, agent-console design docs, world coordination docs | Missing return file in original ledger; backfilled on 2026-06-23 | Landed as squash/subsumed `798f46bd` at 2026-06-23 00:21 +08:00; PR #892 closed 2026-06-23 |
| 5 | Duplicate old world return | Claude / `zyli-developer` | `world-beautification-restructure.md` | Earlier world-beautify return snapshot | `docs/together/2026-06-22/returns/world-beautification-restructure.md` | **Superseded** by `returns/world-beautify.md`; its fast-forward claim became stale | Do not count separately |

## Conflict map recovered from close

| Conflict | Decision |
|---|---|
| `world_live.ex` across login, pg, world-beautify, hello | Kept pg's extracted `CallerDisplay` shape and layered world/hello UI changes on top. |
| `world/admin_data.ex` across pg and world-beautify | Kept pg-compatible Ecto reads; layered world-beautify's orchestrator status shaping. |
| `config/dev.exs` / `config/test.exs` across pg/world/hello | Kept PostgreSQL config as target substrate; retained non-DB additions only where compatible. |
| `Conversation.tsx` hello vs world-beautify | Took hello's superset with the temporary `Page` operator view. |
| `world-coordination.md` agent-console vs world-beautify | Merged the coordination table and kept both Phase-0 demo and world #83 status. |

## Handoff / merge order

1. `pg-compat-audit` first: substrate migration had to become the target base.
2. `world-beautify` second: stale-base UI branch needed post-PG rebase/conflict resolution.
3. `hello` third: depended on `world-beautify` and added a plugin plus renderer surface.
4. `agent-console` fourth: mostly docs/static demo, but touched coordination docs after the world/hello stack.

## Gaps found by this backfill

- The original day plan was placeholder-only, so dev-together did not provide
  a reliable kickoff ledger.
- Return files did not consistently include `returned_at`, `deadline`, or
  `deadline_status`.
- `agent-console` was merged and reviewed but had no `returns/agent-console.md`.
- A duplicate world return stayed in the ledger without an explicit
  `superseded` status.
- PR #890/#891/#892 were left open even though their code was already landed via
  lead squash/subsumed commits. They were comment+closed on 2026-06-23.
