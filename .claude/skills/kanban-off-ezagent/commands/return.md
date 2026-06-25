# `kanban-off-ezagent return [branch]` (contributor)

Record the day's progress on the board node + its DoD artifact, before the
deadline. A return is a **node progress report**, not necessarily a stage-advance —
a multi-day node returns daily while staying in the same stage.

**Do:**
1. Confirm the **DoD artifact** exists (agent-browser screenshot / real-channel chat
   transcript / E2E run output / **the board node advanced + an artifact link
   attached**) and **all gates are green** + the work's own invariant test passes.
2. If a node must be **deferred**: cleanly split the **finished** portion onto its
   own branch (gates green) and relay THAT (`handoff`); carry the rest as a scoped
   follow-up. Never return a tangled half-node.
3. Write `docs/together/<date>/returns/<task>.md`: the metadata block below · what's
   done · the DoD artifact (path/link) · branch + gate status · cleanly-split
   deferred follow-ups · the **merge request** (which branch/PR, rebase/order notes).
4. Emit the message the contributor sends the leader.

## Required metadata block

Every return starts with a block equivalent to:

```md
> **Task:** <id/name>
> **Board node:** <node id/title> — stage: <stage>
> **Advanced this time:** <what moved on the node — same-stage progress or stage-complete>
> **Branch:** `<branch>`
> **PR:** <url-or-number-or-none>
> **Dev:** <human-or-agent>
> **returned_at:** 2026-06-23 07:12 +0800
> **deadline:** 2026-06-22 23:59 +0800
> **deadline_status:** late
```

Allowed `deadline_status` values:

- `on_time` — returned before the day's deadline.
- `late` — valid work, but returned after deadline. Keep it in `returns/` and make
  `push` decide whether it enters today's stack or tomorrow's plan.
- `deferred` — intentionally split follow-up, with target issue/plan/node.
- `out_of_scope` — not part of the day's planned nodes; preserve it, but do not
  count it as planned work.

**Output:** `docs/together/<date>/returns/<task>.md` + a return message to the leader.
