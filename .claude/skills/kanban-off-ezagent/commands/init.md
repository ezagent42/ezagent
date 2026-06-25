# `kanban-off-ezagent init` (anyone)

Per-day setup. Scaffold today's `docs/together/<date>/` working folder. The one
durable `docs/board.md` is **not** created here — `scripts/new_board.sh` creates
it **once at product start** (see SKILL.md §The board).

**Do:**
1. Scaffold today's working folder: `scripts/new_day.sh` → creates
   `docs/together/<today>/{handoffs,returns}/ + plan.md + stack.md`.
2. Confirm the one `docs/board.md` exists. If it does **not**, the product hasn't
   been scaffolded — run `scripts/new_board.sh` (once) before any other command.
   `init` itself never touches `docs/board.md`.

The day folder is created on demand here (or by `plan`); the board persists across
all days and is never re-scaffolded.

**Output:** `docs/together/<date>/` skeleton (handoffs/ returns/ plan.md stack.md).
