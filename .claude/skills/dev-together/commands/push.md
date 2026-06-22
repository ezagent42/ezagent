# `dev-together push` (lead)

Push the developers' returned handoffs onto the day's merge stack and analyze the
merge order. **`push` only analyzes + orders — it does not merge** (that's `close`).

**Do:**
1. Read `docs/together/<date>/returns/*`.
2. Analyze across the returns: inter-task **dependencies**, the safe **merge
   order**, and a **cross-branch conflict check** (which merge clean vs. need
   rebase/sequencing) — apply `docs/guide/world-coordination.md` for world
   overlaps.
3. Maintain `docs/together/<date>/stack.md`: the returns as an **ordered merge
   stack** with the dependency/order/conflict analysis and per-entry status
   (ready / needs-rebase / blocked).

**Output:** `docs/together/<date>/stack.md` — the analyzed, ordered merge stack.
