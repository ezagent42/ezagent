# `dev-together return [branch]` (dev)

Return finished work to the lead before the deadline.

**Do:**
1. Confirm the **DoD artifact** exists (agent-browser screenshot / real-channel
   chat transcript / E2E run output / merged-demo-on-Tailnet) and **all gates are
   green** + the work's own invariant test passes.
2. If a task must be **deferred**: cleanly split the **finished** portion onto its
   own branch (gates green) and hand THAT off; carry the rest as a scoped
   follow-up. Never return a tangled half-task.
3. Write `docs/together/<date>/returns/<task>.md`: what's done · the DoD artifact
   (path/link) · branch + gate status · cleanly-split deferred follow-ups · the
   **merge request** (which branch, any rebase/order notes).
4. Emit the message the dev sends the lead.

**Output:** `docs/together/<date>/returns/<task>.md` + a return message to the lead.
