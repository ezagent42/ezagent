# `dev-together return [branch]` (dev)

Return finished work to the lead before the deadline.

**Do:**
1. Confirm the **DoD artifact** exists (agent-browser screenshot / real-channel
   chat transcript / E2E run output / merged-demo-on-Tailnet) and **all gates are
   green** + the work's own invariant test passes.
2. If a task must be **deferred**: cleanly split the **finished** portion onto its
   own branch (gates green) and hand THAT off; carry the rest as a scoped
   follow-up. Never return a tangled half-task.
3. Write `docs/together/<date>/returns/<task>.md`: metadata · what's done · the
   DoD artifact (path/link) · branch + gate status · cleanly-split deferred
   follow-ups · the **merge request** (which branch/PR, any rebase/order notes).
4. Emit the message the dev sends the lead.

## Required metadata block

Every return starts with a block equivalent to:

```md
> **Task:** <id/name>
> **Branch:** `<branch>`
> **PR:** <url-or-number-or-none>
> **Dev:** <human-or-agent>
> **returned_at:** 2026-06-23 07:12 +0800
> **deadline:** 2026-06-22 23:59 +0800
> **deadline_status:** late
```

Allowed `deadline_status` values:

- `on_time` — returned before the day's deadline.
- `late` — valid work, but returned after deadline. Keep it in `returns/` and
  make `push` decide whether it enters today's stack or tomorrow's plan.
- `deferred` — intentionally split follow-up, with target issue/plan.
- `out_of_scope` — not part of the day's plan; preserve it, but do not count it
  as planned work.

**Output:** `docs/together/<date>/returns/<task>.md` + a return message to the lead.
