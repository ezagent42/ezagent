# `kanban-off-ezagent plan` (leader)

A daily **coordination snapshot of the board** — NOT central task assignment.
Work is decentralized relay (contributors claim/relay nodes themselves; see
SKILL.md §Roles). `plan` makes the day's board state legible and flags conflicts;
it does not hand out tasks.

**Do:**
1. Ensure today's folder exists (`scripts/new_board.sh` creates the one
   `docs/board.md` **once at product start**; the date folder is created per day).
2. Read the one `docs/board.md` and classify its nodes:
   - **Active** (claimed, `status: doing`) — the in-flight, often multi-day
     features. These are the day's primary continuity.
   - **Ready** (unclaimed, upstream stage done) — relay-able next stages waiting
     for a claimer.
   - **Blocked / conflict** — nodes whose work touches the same files/surfaces.
3. Write `docs/together/<date>/plan.md`: the board snapshot (active + ready +
   blocked), each active node's **owner** + "what advances today", each ready
   node marked **open for claim**, and the conflict map. These are intentions and
   coordination — **not assignments**; contributors `claim_node`/relay themselves.

## Plan completeness gate
Before the day proceeds, `plan.md` is invalid until it includes:
- `planned_at`, leader, day deadline, timezone.
- One row per **active** node (board node id, owner, stage, status, what advances
  today) and per **ready** node (open for claim).
- A **conflict map**: shared files/surfaces and which work can run in parallel.
- Each active node **cites its board node id** as its continuity basis (derived
  from the board, not invented).

**Daily, not per-stage.** An active node's "today's increment" is *advance it one
step* — it may stay in the **same stage** for days. Stage-advance is recorded by
`close`/`review` only when the node's work actually completes. The board changes
every day; stages advance occasionally.

If an unplanned return arrives, keep it in `returns/` with `deadline_status:
late` or `out_of_scope`; do not rewrite the plan to pretend it was planned.

**Output:** `docs/together/<date>/plan.md` — the day's board snapshot + conflict
map (a coordination view, not a dispatch list).
