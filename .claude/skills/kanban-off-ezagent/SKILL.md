---
name: kanban-off-ezagent
description: >-
  Use this skill whenever a lead or developers run — or ask how to run — the
  daily product-development workflow on a file-based kanban board (`docs/board.md`)
  WITHOUT ezagent: advancing ONE product through the 9-stage relay chain
  (positioning→metric→pain→anchor→ux→feature→issue→test→pr) day to day. Reach for
  it whenever the user mentions a product board or `board.md`, the 9-stage chain,
  planning today's product work from the board, claiming / relaying / advancing a
  board node, returning progress, the daily merge-and-advance, or an end-of-day
  board review — even if they never say "kanban" or name the skill. Off-ezagent
  (file/CLI/git/gh) half of the kanban-fused workflow; the on-ezagent twin is
  `kanban-on-ezagent`. Do NOT trigger for a bare git push, a single-PR code
  review, plain dev-together with no product board, an ezagent live board (use
  `kanban-on-ezagent`), or a markmap-render / GitHub-Projects request.
---

# kanban-off-ezagent

The file-based, no-ezagent version of the kanban-fused daily product workflow.
The **board is the product's single source of truth** — a markdown `board.md` of
the 9-stage relay chain. dev-together's cadence (plan→handoff→dive→return→push→
close→review) is the **execution layer**, reworked so the board drives the work.

**Fusion principle (why this isn't just dev-together):** plain dev-together only
schedules *developers* — it reads the roster + last return, never a product
board. Here the board is BOTH the **work source** (`plan` reads it) AND the
**write-back sink** (`review` advances it). Product progression and the dev
cadence become one loop instead of two disjoint tracks.

**Daily, not per-stage:** dev is day-to-day; a stage's feature spans days. So the
board changes **every day** (progress recorded on the active nodes), but a node
advances to the **next stage only when its work is done** — never "one stage per
day". `plan` derives the day's increment from the board's **active** (in-flight,
multi-day) nodes first, ready nodes second.

## The board — ONE durable `docs/board.md` (NOT per-day)
**One product = one board.** A single durable file at a stable path
(`docs/board.md`), the product's single source of truth, **evolving day to day**
— there is never a new board per day. 9-stage relay chain; each node carries
`stage`, `owner`, `status`, `artifacts` (requirement docs inline or links, PR
links). Format: [references/board-format.md](references/board-format.md).
`scripts/new_board.sh` scaffolds it **once at product start**.

**Two axes, don't conflate them:**
- **Product axis** = the one `docs/board.md` (persists across all days).
- **Time axis** = `docs/together/<date>/` (the per-day dev-cadence log: `plan.md`
  / `returns/` / `stack.md` / `review.md`).

The per-day commands READ the one board (`plan` derives the day's work from it)
and WRITE it (`review` writes the day's progress back into it). The daily folders
are the log; the board is the product.

## Roles — decentralized relay work, centralized merge
The work is a **decentralized relay**; only the merge is centralized.
- **Leader** — the **ONLY path to merge to `main`** (`close`). The leader does
  **NOT** centrally assign the day's work — assignment is decentralized relay
  (below). The leader runs the integration gate + the daily board `review`. A
  hat, not a person.
- **Contributor** (anyone, incl. the leader in a contributor hat) — claims a
  board node, does that stage's work, and **relays the next stage to others** by
  creating the next node and leaving it claimable (or handing it directly). Work
  moves peer-to-peer along the 9-stage chain — **not dispatched from a center**.
  A contributor may own a single node or a whole feature line, and a task may
  start at any stage (product end: positioning/pain/feature; dev end:
  issue/test/pr).

**Relay on the board (no new mechanic):** `claim_node` = become a node's owner;
per-node `owner_or_admin?` = only the owner/admin edits that node. Relay = the
owner finishes stage N → `add_node` for stage N+1 → someone else `claim_node`s
it and picks up.

## The daily cycle (8 commands) — fused with the board
Invoke as `kanban-off-ezagent <command>`. **Read the matching `commands/` file
before acting.** The fused points are bold.

| # | Command | Role | One-liner |
|---|---------|------|-----------|
| 1 | `init` | anyone | scaffold today's `docs/together/<date>/` (the one board is scaffolded once, not here) ([commands/init.md](commands/init.md)) |
| 2 | `plan` | leader | **snapshot the board's active+ready nodes + flag conflicts/priorities** — a coordination view, NOT central assignment → `plan.md` ([commands/plan.md](commands/plan.md)) |
| 3 | `handoff` | **node-owner** | **relay the next stage**: `add_node` for stage N+1 + a handoff spec from that stage's requirement — decentralized ([commands/handoff.md](commands/handoff.md)) |
| 4 | `dive` | contributor | **claim a board node**, branch off main, do that stage's work ([commands/dive.md](commands/dive.md)) |
| 5 | `return` | contributor | **record progress on the node** + DoD artifact → `returns/` ([commands/return.md](commands/return.md)) |
| 6 | `push` | leader | order returns, map each to its board node → `stack.md` ([commands/push.md](commands/push.md)) |
| 7 | `close` | **leader only** | **merge to `main`** (the single gate) + advance the board node ([commands/close.md](commands/close.md)) |
| 8 | `review` | leader | **reconcile the board to `main`** + the stack (fix drift) + roster → `review.md` ([commands/review.md](commands/review.md)) |

## Ledger rules — do not skip
- **No empty plan.** `plan.md` is invalid until every task lists its **board node**,
  owner/dev, scope, branch, required reading, DoD artifact, deadline.
- **Timestamp every return.** Each `returns/<task>.md` records `returned_at`,
  `deadline`, `deadline_status`, **and the board node + the progress it made**.
- **Reconcile the whole ledger.** `push` accounts for every return: stacked,
  superseded, late, out-of-scope, or blocked.
- **Close PR state.** After `close`, every related PR is merged or explicitly
  closed/subsumed; the board node reflects the outcome.
- **Board write-back is per-action + mandatory.** Every claim/relay/merge writes
  `docs/board.md` immediately (mirroring the live board's per-action dispatch) — the
  board is the live shared truth, not a single-writer log. `review` **reconciles**
  it against `main` + the stack daily and fixes drift.

## References
- [references/board-format.md](references/board-format.md) — the `board.md` format.
- [references/handoff-standard.md](references/handoff-standard.md) — DoD = a
  demonstrable artifact (reused from dev-together; sound, unchanged).

## Why these rules
The board-as-source-and-sink is the whole point: it stops the product state from
drifting away from the dev cadence. Daily-progress-not-per-stage keeps multi-day
features honest (a node can sit in one stage for days while `review` still records
real daily movement). The reused dev-together rules (per-task branch, lead-merge,
demonstrable DoD) keep parallel devs unblocked and "green tests, broken product"
from passing. The on-ezagent twin `kanban-on-ezagent` keeps this exact flow but
swaps the file board for a live dispatched board.
