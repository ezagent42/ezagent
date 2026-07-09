# `dev-together init` (dev / lead)

One-time per environment + per-day setup.

**Do:**
1. Install the handoff-deadline reminder hook into the agent env:
   `scripts/install_hooks.sh` (idempotent; `--deadline HH:MM`, default 20:00; or
   edit `.claude/dev-together.conf`). It drops `hooks/handoff-deadline-reminder.sh`
   into `.claude/hooks/` and wires a `Stop` hook in `.claude/settings.json`.
2. Scaffold today's working folder: `scripts/new_day.sh` → creates
   `docs/together/<today>/{handoffs,returns}/ + plan.md + stack.md`.

Run the hook install once per environment; the day folder is (re)created on demand
by `new_day.sh` / `plan`.

**Output:** installed hook + `docs/together/<date>/` skeleton.
