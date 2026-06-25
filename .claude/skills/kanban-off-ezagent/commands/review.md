# `kanban-off-ezagent review` (leader)

End-of-day retrospective that **reconciles the one `docs/board.md` against `main`**
and feeds tomorrow's `plan`. The board is **multi-writer** — `dive` claims,
`handoff` relays, `close` advances on merge, each writing it immediately (mirroring
the live board's per-action dispatch). `review` is the **reconciler, not a second
writer**: it audits the board against `main` + the day's stack and fixes drift.

**Do:** write `docs/together/<date>/review.md` covering:
1. **What landed** — tasks merged to `main` (from `stack.md`), with shas **and the
   board node each one advanced**.
2. **Board reconcile (mandatory)** — audit `docs/board.md` against `main` + the
   day's merges. `close` advances each merged node immediately; here you **fix any
   node it missed or got wrong** and confirm `stage` advanced only where the work
   actually completed (daily progress is the norm; stage-advance is occasional).
   Newly-completed stages should have a next ready node for relay.
3. **Efficiency stats** — **planned vs. returned vs. stacked vs. merged**; how much
   ran in parallel vs. serial; cycle times if available.
4. **Gaps** — **late returns** (called out, not silently counted), deferred items
   (+ where tracked), skipped gates, conflicts hit, steps that stalled on a human.
5. **Next-day planning** — what to sequence, **which ready nodes are waiting for a
   claimer** (open relays), which conflicts to pre-empt, process tweaks.
6. **Roster** — set each contributor's `current_track`/`latest_return` to the
   board node/line they're now on (tomorrow's `plan` derives continuity from this).

## Required accounting
Include a table answering:
- How many board nodes advanced today, and how many of those were **stage-advances
  vs. same-stage progress**?
- How many tasks were in `plan.md`? How many return files arrived, and how many
  were **late returns**?
- How many returns entered `stack.md`? How many merged to `main`?
- Which returns were superseded, out-of-scope, blocked, or deferred?
- Which board nodes are now **ready/open for the next relay**?

If `plan.md` was placeholder-only, say so directly and treat it as a process gap.
Do not infer a clean plan from successful merges after the fact.

**Output:** `docs/together/<date>/review.md` + an **updated `docs/board.md`** —
input to the next day's `plan`.
