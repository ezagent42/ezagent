# `kanban-on-ezagent review` (leader)

End-of-day retrospective that **reconciles the live board (dispatch `get_tree`)
against `main`** and feeds tomorrow's `plan`. The live board is **multi-writer** —
`dive` dispatches `claim_node`, `handoff` dispatches `add_node`, `close` dispatches
`set_status`/`set_stage` on merge, each writing the snapshot immediately. `review` is
the **reconciler, not a second writer of fresh work**: it audits the live board
(`get_tree`) against `main` + the day's stack and **fixes drift by dispatching
corrections**.

**Do:** write `docs/together/<date>/review.md` covering:
1. **What landed** — tasks merged to `main` (from `stack.md`), with shas **and the
   live board node id each one advanced**.
2. **Board reconcile (mandatory)** — **dispatch `get_tree`** and audit the live
   snapshot against `main` + the day's merges. `close` advances each merged node
   immediately; here you **fix any node it missed or got wrong** by dispatching the
   correcting `set_status`/`set_stage`/`attach_artifact`, and confirm `stage`
   advanced only where the work actually completed (daily progress is the norm;
   stage-advance is occasional). Newly-completed stages should have a next ready node
   (dispatch `add_node`) for relay.
3. **Refresh projections** — dispatch `export_markmap` (the markmap view) and/or
   `sync_miro` / `sync_prs` so the external mirrors match the reconciled snapshot
   ([../references/live-board-access.md](../references/live-board-access.md)
   §Projections).
4. **Efficiency stats** — **planned vs. returned vs. stacked vs. merged**; how much
   ran in parallel vs. serial; cycle times if available; **how many nodes were driven
   by agents vs. humans** (on-ezagent — owner can be either).
5. **Gaps** — **late returns** (called out, not silently counted), deferred items (+
   where tracked), skipped gates, conflicts hit, steps that stalled on a human.
6. **Next-day planning** — what to sequence, **which ready nodes are waiting for a
   claimer** (open relays), which conflicts to pre-empt, process tweaks.
7. **Roster** — set each contributor's (human or agent) `current_track`/`latest_return`
   to the live board node/line they're now on (tomorrow's `plan` derives continuity
   from this + a fresh `get_tree`).

## Required accounting
Include a table answering:
- How many live board nodes advanced today, and how many of those were **stage-advances
  vs. same-stage progress**?
- How many tasks were in `plan.md`? How many return files arrived, and how many were
  **late returns**?
- How many returns entered `stack.md`? How many merged to `main`?
- Which returns were superseded, out-of-scope, blocked, or deferred?
- Which live board nodes are now **ready/open for the next relay**?

If `plan.md` was placeholder-only, say so directly and treat it as a process gap. Do
not infer a clean plan from successful merges after the fact.

**Output:** `docs/together/<date>/review.md` + a **reconciled live board** (drift fixed
by dispatch, projections refreshed via `export_markmap`/`sync_miro`) — input to the
next day's `plan`.
