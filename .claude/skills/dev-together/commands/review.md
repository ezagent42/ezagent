# `dev-together review` (lead)

End-of-day retrospective that closes the loop and feeds tomorrow's `plan`.

**Do:** write `docs/together/<date>/review.md` covering:
1. **What landed** — tasks merged to `main` (from `stack.md`), with shas.
2. **Efficiency stats** — planned vs. returned vs. stacked vs. merged; cycle
   times if available; how much was parallel vs. serial.
3. **Gaps** — deferred items (+ where they're tracked), skipped gates, conflicts
   hit, steps that needed a human and stalled, any DoD that slipped to "tests
   pass" only.
4. **Next-day planning suggestions** — what to sequence differently, which
   conflicts to pre-empt, which deferrals to schedule, process tweaks.
5. **Update the roster (single writer).** For each human dev, set their
   `current_track` and `latest_return` in `docs/together/team.md` to the next
   track — this is what tomorrow's `plan` derives from. `review` is the **only**
   writer of `current_track`/`latest_return`; `return`/`close` do NOT touch them
   (avoids double-write). A mid-stream pivot may be reflected by the lead.

## Required accounting

Include a table that answers:

- How many tasks were in `plan.md`?
- How many return files arrived, and how many were late returns?
- How many returns entered `stack.md`?
- How many merged to `main`?
- Which returns were superseded, out-of-scope, blocked, or deferred?
- Which related GitHub PRs were merged, closed as subsumed, or intentionally left
  open?

If `plan.md` was incomplete or placeholder-only, say that directly and treat it
as a process gap. Do not infer a clean plan from successful merges after the
fact.

**Output:** `docs/together/<date>/review.md` — input to the next day's `plan`.
