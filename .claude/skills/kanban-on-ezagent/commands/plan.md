# `kanban-on-ezagent plan` (leader)

A daily **coordination snapshot of the live board** — NOT central task assignment.
Work is decentralized relay (contributors, human or agent, `claim_node` themselves;
see SKILL.md §Roles). `plan` makes the day's live board state legible and flags
conflicts; it does not hand out tasks.

**Do:**
1. Ensure today's folder exists (the live board itself is created by the first
   `get_tree` dispatch at product start; the date folder is created per day).
2. **Dispatch `get_tree`** against `resource://<ws>/kanban/<name>` with the leader's
   ctx (`mode: :call`; `target = with_action(uri, :kanban, :get_tree)` —
   [../references/live-board-access.md](../references/live-board-access.md) §dispatch
   envelope). Read `result.tree.nodes` and classify:
   - **Active** (`status: doing`, owned) — the in-flight, often multi-day features.
     The day's primary continuity.
   - **Ready** (`status: unassigned`, upstream stage done) — relay-able next stages
     waiting for a claimer.
   - **Blocked / conflict** — nodes whose work touches the same files/surfaces.
3. Write `docs/together/<date>/plan.md`: the live-board snapshot (active + ready +
   blocked), each active node's **owner** (user OR agent URI) + "what advances
   today", each ready node marked **open for claim**, and the conflict map. These
   are intentions and coordination — **not assignments**; contributors dispatch
   `claim_node` themselves.

## Plan completeness gate
Before the day proceeds, `plan.md` is invalid until it includes:
- `planned_at`, leader, day deadline, timezone.
- One row per **active** node (live board node id from `get_tree`, owner, stage,
  status, what advances today) and per **ready** node (open for claim).
- A **conflict map**: shared files/surfaces and which work can run in parallel.
- Each active node **cites its live board node id** (the `"n<seq>"` id returned by
  `add_node`, read back from `get_tree` — derived from the live board, not invented).

**Daily, not per-stage.** An active node's "today's increment" is *advance it one
step* — it may stay in the **same stage** for days. Stage-advance is recorded by
`close`/`review` (dispatching `set_stage`) only when the node's work actually
completes. The board snapshot changes every day; stages advance occasionally.

If an unplanned return arrives, keep it in `returns/` with `deadline_status: late`
or `out_of_scope`; do not rewrite the plan to pretend it was planned.

**Output:** `docs/together/<date>/plan.md` — the day's live-board snapshot (from a
`get_tree` dispatch) + conflict map (a coordination view, not a dispatch list).
