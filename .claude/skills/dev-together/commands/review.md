# `dev-together review` (lead)

End-of-day retrospective that closes the loop and feeds tomorrow's `plan`.

**Canonical skeleton:** author `review.md` (and its `review.html`) from
[../references/review-template.md](../references/review-template.md) so the format
matches the plan's §0–§5 shape and stops drifting. The mandatory sections below
are unchanged.

**Do:** write `docs/together/<date>/review.md` covering:
1. **What landed** — tasks merged to `main` (from `stack.md`), with shas.
2. **Efficiency stats** — planned vs. returned vs. stacked vs. merged; cycle
   times if available; how much was parallel vs. serial.
3. **Gaps** — deferred items (+ where they're tracked), skipped gates, conflicts
   hit, steps that needed a human and stalled, any DoD that slipped to "tests
   pass" only.
4. **Next-day planning suggestions** — what to sequence differently, which
   conflicts to pre-empt, which deferrals to schedule, process tweaks.
5. **Method deltas (MANDATORY section — promote, don't just collect).** Read the
   **DoD-reconciliation + method-friction** notes from every `return`. Triage them:
   each real process gap becomes either a **dev-together PR** (edit the skill — the
   lead is the single writer of the contract) or a tracked **process-debt** item
   with an owner. Write this section **even if it's "none"** — a missing section
   means the learning step was skipped, and that must be visible. Every
   close-review finding should name the **process rule (existing or new) that would
   have caught it**; a finding with no mapped rule is a signal to add one. This is
   the *Act* phase of the loop: it updates the **method**, not just the roster.
6. **Update the roster (single writer).** For each human dev, set their
   `current_track` and `latest_return` in `docs/together/team.md` to the next
   track — this is what tomorrow's `plan` derives from. `review` is the **only**
   writer of `current_track`/`latest_return`; `return`/`close` do NOT touch them
   (avoids double-write). A mid-stream pivot may be reflected by the lead.
7. **Update the board (MANDATORY, deterministic — never hand-write HTML).**
   `review` does NOT write a new file — it **updates the same
   `docs/together/<date>/board.yaml`** the `plan` opened, then re-renders:
   `uv run --with pyyaml python scripts/render/board2html.py docs/together/<date>/board.yaml`.
   At EOD you: (a) **move each card** to its final `status` (`done` / `review` /
   `wip` / `blocked`); (b) **tick its `acceptance:`** — set each `done: true` and
   add `evidence:` (PR#/SHA/test result) — this IS the 验收结果, closing the
   morning's acceptance one by one; (c) fill the `review:` block
   (`method_deltas`, `incidents`, `delivery`, `next_day`). Presentation lives ONLY
   in `board2html.py`; do not author `<style>`/layout by hand. A missing or
   hand-authored `board.html` means `review` is incomplete.

   **Continuity is welded into the card:** the same `acceptance:` list `plan`
   wrote (`done: false`) is what `review` ticks (`done: true` + evidence), and any
   card not moved to `done` is tomorrow's carryover — no separate 验收结果 doc to
   drift against.

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

> **对账并核两源。** 台账对账必须**同时**扫 `returns/` 与当日 GitHub 合并（`gh pr list --repo … --state merged --author …`）——有人走直接 PR review→merge、不进 `returns/`，只看台账会漏记其贡献（2026-07-09 zhaomato #1277 / ruihua #1204 即如此，一度被误记为"无 return→结转"）。

**Output:** `docs/together/<date>/review.md` **and** its team-facing
`docs/together/<date>/review.html` render — `review.md` is the input to the next
day's `plan`; `review.html` is the artifact the team reads.
