# `kanban-on-ezagent init` (anyone)

Per-day setup. Scaffold today's `docs/together/<date>/` working folder and ensure
the **one live kanban board** exists. Unlike the off twin there is **no
`new_board.sh`** — the board is a live Kind, brought to life by **dispatch**, not a
file scaffold (see SKILL.md §The board, [../references/live-board-access.md](../references/live-board-access.md) §Create).

**Do:**
1. Scaffold today's working folder: create `docs/together/<today>/{handoffs,returns}/
   + plan.md + stack.md` (the per-day dev-cadence log; identical to off — only the
   board medium differs).
2. Confirm the one live board exists at `resource://<ws>/kanban/<name>`. To create
   or confirm it, **dispatch `get_tree`** once: a fresh URI with no live Kind
   auto-spawns via ReadyGate (`KanbanData.board_snapshot/2` →
   `ensure_spawned` + `get_tree`, `kanban_data.ex:113-124`). If the product has no
   board yet, this first dispatch IS the creation step — no scaffold script. `init`
   itself never mutates the board (read-only `get_tree`).

The day folder is created on demand here (or by `plan`); the live board persists in
its snapshot across all days and is never re-created.

**Output:** `docs/together/<date>/` skeleton (handoffs/ returns/ plan.md stack.md) +
a confirmed live board URI (auto-spawned if it was the product's first dispatch).
