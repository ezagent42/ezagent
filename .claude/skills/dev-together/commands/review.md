# `dev-together review` (lead)

End-of-day retrospective that closes the loop and feeds tomorrow's `plan`.

**Canonical skeleton:** author `review.md` (and its `review.html`) from
[../references/review-template.md](../references/review-template.md) so the format
matches the plan's §0–§5 shape and stops drifting. The mandatory sections below
are unchanged.

**Do:** write `docs/together/<date>/review.md` covering:
1. **What landed** — tasks merged to `main` (from `stack.md`), with shas.
2. **Efficiency stats** — planned vs. returned vs. stacked vs. merged; cycle
   times if available; how much was parallel vs. serial. **加一行自动工时下界**:
   跑 `uv run python .claude/skills/dev-together/scripts/pr_session_hours.py
   ezagent42/ezagent "<今日日期>"`(commit 时间戳 session 聚类,git-hours 法),
   把 `total_active_hours` 记入表格(方法与读数纪律见
   `docs/together/2026-07-15/engineering-efficiency-analysis.md`:**下界、
   非真实工时、禁止用于个人绩效**)。周五 review 额外跑一次 `">=<本周一>"`
   的周窗口,积累效率时序数据。
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
7. **Team-facing render (MANDATORY).** Alongside `review.md`, produce
   `docs/together/<date>/review.html` — a clean, product-first rendering of the
   day for the whole team: **product 大局 → task stats → efficiency →
   risks/deferred → method deltas → next-day plan**. It is a team artifact, not a
   worklog: **omit all Claude↔lead discussion meta**, keep it self-contained
   (inline CSS, no external assets), and match the established house style (see
   the prior examples `docs/together/2026-06-25/review.html` and
   `docs/together/2026-06-30/review.html`). `review.html` must exist alongside
   `review.md`; a missing render means `review` is incomplete.

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
