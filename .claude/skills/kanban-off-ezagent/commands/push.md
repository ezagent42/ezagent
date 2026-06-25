# `kanban-off-ezagent push` (leader)

Push the contributors' returns onto the day's merge stack, mapping each to its
board node, and analyze the merge order. **`push` only analyzes + orders — it does
not merge** (that's `close`) and it does **not** write the board (that's `review`).

**Do:**
1. Read `docs/together/<date>/returns/*`.
2. Analyze across the returns: inter-node **dependencies** (relay order along the
   9-stage chain), the safe **merge order**, and a **cross-branch conflict check**
   (which merge clean vs. need rebase/sequencing) — apply
   `docs/guide/world-coordination.md` for world overlaps.
3. Run the **Returned-vs-stacked reconciliation** below.
4. Maintain `docs/together/<date>/stack.md`: the returns as an **ordered merge
   stack**, each row carrying **its board node id**, with the
   dependency/order/conflict analysis and per-entry status (ready / needs-rebase /
   blocked).

## Returned-vs-stacked reconciliation

`stack.md` must account for every file in `returns/`; no return may disappear.
Create a reconciliation table with one row per return, each naming its board node:

- `stacked` — included in the ordered merge stack.
- `superseded` — duplicate/stale return replaced by another return file for the
  same node; name the winner.
- `late` — arrived after deadline; either stack explicitly or defer to tomorrow.
- `out-of-scope` — valid artifact but not a planned node today.
- `blocked` — cannot be reviewed/merged; give the concrete blocker.

If two returns describe the same board node, pick one canonical row, mark the other
`superseded`, and explain which branch/PR/head wins. If a return has no
`returned_at`, `deadline_status`, or **board node id**, mark it `blocked` until the
contributor adds the metadata.

**Output:** `docs/together/<date>/stack.md` — the analyzed, ordered merge stack,
each entry tied to its board node.
