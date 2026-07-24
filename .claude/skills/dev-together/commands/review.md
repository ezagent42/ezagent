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
>
> **归属看实质，不看提交账号（统筹≠交付）。** 协调者（cc）以 lead 账号（`allenwoods`）提交+合并，所以 **git author 不能用来判定归属**——它会把所有人的活都吸进"统筹轨道"。判定信号是**该 PR 是否承载了某位具名 dev 的实质产出**（`returns/`、handoff 台账、或 PR body 里点名，如 "ruihua's 3 analysis docs"）：
> - 具名 dev 的实质产出即便**装在**协调者账号的 PR 里合并，`done` 卡的 owner 仍归**该 dev 的轨道**，附一行 "统筹 packaged/reviewed/merged"——绝不让统筹账号吞掉它（2026-07-24：ruihua 的 3 篇 MFU 分析装在 `allenwoods` 的 #1543 里被记成 "Allen 轨道"；zyli 自号 #1497 只作为统筹 #1541 修的"漂移来源"出现、无 done 卡——两者都错）。
> - **统筹角色工作（review/gate/merge 别人的 PR、PR 清理、看板 PR、main-red/fallout 救火）不是交付卡**——它进 `efficiency`/统筹小结，不占 `done` 交付列；否则统筹重的周期会视觉上把 dev 的功能交付挤没、显得"全是 lead 轨道"。

**Output:** `docs/together/<date>/review.md` **and** its team-facing
`docs/together/<date>/review.html` render — `review.md` is the input to the next
day's `plan`; `review.html` is the artifact the team reads.
