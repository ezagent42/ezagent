---
name: kanban-on-ezagent
description: >-
  Use this skill whenever a lead or developers run — or ask how to run — the
  daily product-development workflow on an ezagent LIVE kanban board
  (`resource://<ws>/kanban/<name>`, read/written via dispatch, persisted in the
  Kind snapshot) WITH ezagent: advancing ONE product through the 9-stage relay
  chain (positioning→metric→pain→anchor→ux→feature→issue→test→pr) day to day.
  Reach for it whenever the user mentions a live/ezagent kanban board, a
  `resource://…/kanban/…` URI, dispatching `kanban.*` actions (`get_tree`,
  `claim_node`, `add_node`, `sync_github`…), the 9-stage chain on a live board,
  planning today's product work off the live board, claiming / relaying /
  advancing a live node, returning progress, the daily merge-and-advance, an
  end-of-day live-board review, OR **assigning a board node to an agent** (the
  on-ezagent superpower) / chat-orchestrating the board via a kanban-manager
  agent — even if they never say "kanban" or name the skill. This is the
  ON-ezagent (live/dispatch/snapshot) twin of the file-based half; the off-ezagent
  twin is `kanban-off-ezagent`. Do NOT trigger for a bare git push, a single-PR
  code review, plain dev-together with no product board, a FILE board (`docs/board.md`
  with no ezagent — use `kanban-off-ezagent`), or a raw markmap-render / GitHub-
  Projects request.
---

# kanban-on-ezagent

The **live, ezagent-backed** twin of the kanban-fused daily product workflow.
Same product workflow as `kanban-off-ezagent` — same 9-stage relay chain, same
node model, same 8 commands, same decentralized-relay + leader-only-merge roles —
but the **medium is a live ezagent board, not a file**. The board is a kanban
**Kind** at `resource://<ws>/kanban/<name>`; you read and write it through
**dispatch** (`Ezagent.Invocation.dispatch/1`), its state lives in the Kind
**snapshot** (durable, multi-writer), and its projections come from
`export_markmap` / `sync_github` / `sync_miro` actions — not from editing a
markdown file.

**Twin disambiguation (don't confuse them):** this is the ON / live / ezagent
version. The off-ezagent twin `kanban-off-ezagent` runs the *identical* workflow on
a file board (`docs/board.md`) with no ezagent. They are **usage-identical** by
design — every off concept maps 1:1 to an on concept (see
[references/off-on-parity.md](references/off-on-parity.md)). Pick **on** when the
board is a live ezagent Kind (a `resource://…/kanban/…` URI, dispatched actions, a
running world); pick **off** when it's a plain file in a repo.

**Fusion principle (why this isn't just dev-together):** plain dev-together only
schedules *developers* — it reads the roster + last return, never a product board.
Here the **live board is the product's single source of truth** AND is BOTH the
**work source** (`plan` dispatches `get_tree` to read it) AND the **write-back
sink** (`dive`/`handoff`/`close` dispatch `claim_node`/`add_node`/`set_status` to
advance it). Product progression and the dev cadence become one loop.

**Daily, not per-stage:** dev is day-to-day; a stage's feature spans days. The
board's snapshot changes **every day** (progress recorded on active nodes via
dispatch), but a node advances to the **next stage only when its work is done** —
never "one stage per day". `plan` derives the day's increment from the live board's
**active** nodes first, **ready** nodes second.

## The board — ONE live kanban Kind (NOT per-day, NOT a file)
**One product = one live board.** A single durable kanban Kind at a stable URI
`resource://<ws>/kanban/<name>`, the product's single source of truth, **evolving
day to day** — never a new board per day, never a markdown file you hand-edit. The
9-stage relay chain lives as the Kind's node tree in its snapshot; each node carries
`stage`, `owner`, `status`, `artifacts`, `metrics` — the exact node model in
[references/live-board-access.md](references/live-board-access.md) (grounded in
`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:13-24`). The board is
**created once** by dispatching to a fresh URI (`get_tree` auto-spawns the Kind via
ReadyGate — see live-board-access.md §Create), not by a scaffold script.

**Two axes, don't conflate them:**
- **Product axis** = the one live kanban Kind (persists in its snapshot across all
  days). Read/written ONLY by dispatch.
- **Time axis** = `docs/together/<date>/` (the per-day dev-cadence log: `plan.md` /
  `returns/` / `stack.md` / `review.md`) — the same daily log the off twin keeps,
  because the *dev cadence* is identical; only the *board medium* changed.

The per-day commands READ the live board (`plan` dispatches `get_tree`) and WRITE
it (`dive`/`handoff`/`close` dispatch mutating `kanban.*` actions). The daily
folders are the human-readable log; the live board snapshot is the product truth.

## Roles — decentralized relay work, centralized merge
The work is a **decentralized relay**; only the merge to `main` is centralized.
- **Leader** — the **ONLY path to merge to `main`** (`close`). The leader does
  **NOT** centrally assign the day's work — assignment is decentralized relay
  (below). The leader runs the integration gate + the daily live-board `review`. A
  hat, not a person.
- **Contributor** (anyone, incl. the leader in a contributor hat; **human OR
  agent**) — dispatches `claim_node` to own a node, does that stage's work, and
  **relays the next stage** by dispatching `add_node` for stage N+1, leaving it
  claimable. Work moves peer-to-peer along the 9-stage chain — **not dispatched
  from a center**. A contributor may own a single node or a whole feature line, and
  a task may start at any stage (product end: positioning/pain/feature; dev end:
  issue/test/pr).

**Relay on the live board (no new mechanic):** `claim_node` dispatch = become a
node's owner (`owner=caller, status=claimed`, `kanban.ex:469-489`); the Behavior's
per-node `owner_or_admin?` means only the owner/admin can mutate that node
(`kanban.ex:715`, enforced in the Kind, not on trust). Relay = the owner finishes
stage N → dispatch `add_node` for stage N+1 → someone else dispatches `claim_node`
and picks up.

## The on-ezagent superpower — assign a node to an AGENT, not just a human
Because every mutation is a **dispatch carrying a `caller`** (`ctx.caller`,
`kanban_actions.ex:321-327`), a node's `owner` can be an **agent entity URI** just
as legitimately as a user URI — the Behavior never distinguishes "human" from
"agent", it only checks `caller == node.owner` or admin
(`kanban.ex:715`/`shared.owner_or_admin?`). So a contributor in the relay can be an
agent: claim a node, do the stage's work, attach the artifact, relay the next stage
— **all by dispatch, no file editing**. This is the live board's superpower over the
file board: the relay chain can run (partly or fully) on agents.

**Chat-orchestration entry (high-level):** a lead can `@`/route a message to a
**kanban-manager agent** that owns and drives the board on their behalf — managing
nodes, assigning work (to people or agents), kicking CI, reviewing — in the limit,
fully-automated development. The concrete routing rule + agent contract (which
session-orchestrator path, which agent URI, how the message reaches `kanban.*`
dispatch) are **grounding placeholders** — see
[references/agent-orchestration.md](references/agent-orchestration.md) (marked
"待编排 grounding 补全"; another agent is resolving the exact file:line wiring).

## The daily cycle (8 commands) — fused with the live board
Invoke as `kanban-on-ezagent <command>`. **Read the matching `commands/` file
before acting.** The fused points are bold; the board-touch is always a **dispatch**.

| # | Command | Role | One-liner |
|---|---------|------|-----------|
| 1 | `init` | anyone | scaffold today's `docs/together/<date>/`; ensure the live board Kind exists (dispatch `get_tree` once auto-spawns it) ([commands/init.md](commands/init.md)) |
| 2 | `plan` | leader | **dispatch `get_tree` → snapshot the live board's active+ready nodes + flag conflicts/priorities** — a coordination view, NOT central assignment → `plan.md` ([commands/plan.md](commands/plan.md)) |
| 3 | `handoff` | **node-owner** | **relay the next stage**: dispatch `add_node` for stage N+1 + a handoff spec derived from that node's `artifact`/`metric` — decentralized ([commands/handoff.md](commands/handoff.md)) |
| 4 | `dive` | contributor (human or agent) | **dispatch `claim_node` + `set_status doing`**, branch off main, do that stage's work ([commands/dive.md](commands/dive.md)) |
| 5 | `return` | contributor | **dispatch progress onto the node** (`set_status`/`attach_artifact`/`set_metric`) + DoD artifact → `returns/` ([commands/return.md](commands/return.md)) |
| 6 | `push` | leader | order returns, map each to its live board node id → `stack.md` ([commands/push.md](commands/push.md)) |
| 7 | `close` | **leader only** | **merge to `main`** (the single gate) + dispatch to advance the node (`set_status`/`set_stage`/`attach_artifact`) + `sync_github` ([commands/close.md](commands/close.md)) |
| 8 | `review` | leader | **reconcile the live board (dispatch `get_tree`) to `main`** + the stack (fix drift) + roster; refresh projection (`export_markmap`/`sync_miro`) → `review.md` ([commands/review.md](commands/review.md)) |

## Ledger rules — do not skip
- **No empty plan.** `plan.md` is invalid until every task lists its **live board
  node id** (from `get_tree`), owner/dev, scope, branch, required reading, DoD
  artifact, deadline.
- **Timestamp every return.** Each `returns/<task>.md` records `returned_at`,
  `deadline`, `deadline_status`, **and the board node id + the progress dispatched**.
- **Reconcile the whole ledger.** `push` accounts for every return: stacked,
  superseded, late, out-of-scope, or blocked.
- **Close PR state.** After `close`, every related PR is merged or explicitly
  closed/subsumed; the live node reflects the outcome (and `sync_github`/`sync_prs`
  keep the GitHub side honest).
- **Board write-back is per-action + mandatory + by dispatch.** Every
  claim/relay/merge **dispatches** a mutating `kanban.*` action immediately — the
  live board snapshot is the shared truth, multi-writer, never a single-writer file.
  `review` **reconciles** it (`get_tree`) against `main` + the stack daily and
  fixes drift by dispatching corrections.

## References
- [references/live-board-access.md](references/live-board-access.md) — how to read/
  write the live board by dispatch (target URI, ctx, mode), the 24-action contract,
  snapshot persistence, and the `export_markmap`/`sync_github`/`sync_miro` projections.
- [references/off-on-parity.md](references/off-on-parity.md) — the **off↔on 1:1
  mapping table** proving the two skills are usage-identical (file ↔ dispatch).
- [references/agent-orchestration.md](references/agent-orchestration.md) — high-level
  chat-`@`/route → kanban-manager agent orchestration (routing/agent-contract
  grounding marked "待编排 grounding 补全").

## Why these rules
The live-board-as-source-and-sink is the whole point: it stops product state from
drifting from the dev cadence, AND — unlike the file board — it lets the relay run on
agents (every node touch is an authenticated dispatch, so an agent owner is as
first-class as a human owner). Daily-progress-not-per-stage keeps multi-day features
honest (a node sits in one stage for days while `review` records real daily
movement). The reused dev-together rules (per-task branch, lead-merge, demonstrable
DoD) keep parallel devs/agents unblocked and "green tests, broken product" from
passing. The off-ezagent twin `kanban-off-ezagent` keeps this exact flow on a file
board for when ezagent isn't in the loop.
