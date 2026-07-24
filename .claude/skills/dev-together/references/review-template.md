# Daily review template (copy-paste) — the canonical `review.md` skeleton

Copy this skeleton for the day's `review.md`. **Fill every section**; a section
is never silently dropped (a deleted one carries a one-line reason). The rules
behind each section live in [../commands/review.md](../commands/review.md) and
the `dev-together` `SKILL.md`. `review.md` is the machine/`plan` input; the
team-facing `review.html` renders §0–§5 product-first (no Claude↔lead meta).

> **§4 method-deltas is MANDATORY** — write it even if it's "none". §6 (roster
> update) makes `review` the **single writer** of `current_track`/`latest_return`
> (a mechanical de-dup — `return`/`close` never touch them). The lead is the
> contract gatekeeper for any skill change; dev-together has **no single owner**
> (team-discussed, lead admin-merges the「Protect dev-together skill」gate).

---

```markdown
# dev-together 复盘 · YYYY-MM-DD

## 元数据
- `reviewed_at`: YYYY-MM-DD
- `lead`: <github_username>
- `plan_ref`: docs/together/YYYY-MM-DD/plan.md
- `week_ref`: docs/together/<ISO-week>/weekly-goals.md

## §0 product 大局（what the day advanced toward the week acceptance）
<Against §0 of today's plan (the standing week acceptance): what did today move
the needle on? What is now unblocked / still blocking? One honest paragraph —
this is what the team reads first.>

## §1 落地了什么（what landed — SHAs）
<Tasks merged to `main` (from `stack.md`) with their merge SHAs; plus any direct
PR merges not routed through returns (cross-check GitHub, see below).>

## §2 台账对账（accounting table）
> **对账并核两源:** 扫 `returns/` **和**当日 GitHub 合并
> （`gh pr list --repo … --state merged --author …`）——有人走直接 PR，只看台账会漏记。

| 指标 | 数 | 备注 |
|---|---|---|
| plan.md 计划任务数 | | |
| returns/ 到达数 | | 其中 late： |
| 进入 stack.md 数 | | |
| 合入 main 数 | | |
| superseded / out-of-scope / blocked / deferred | | 各列去向 |
| GitHub PR：merged / subsumed / left-open | | 逐一点名 |

<If `plan.md` was incomplete/placeholder, say so directly and treat it as a
process gap — do not infer a clean plan from successful merges after the fact.>

## §3 缺口 / 结转（gaps / deferrals）
<Deferred items + where each is tracked; skipped gates; conflicts hit; steps
that needed a human and stalled; any DoD that slipped to "tests pass" only.>

## §4 method-deltas（MANDATORY — promote, don't just collect）
> Read the DoD-reconciliation + method-friction notes from every `return`. Each
> real gap becomes either a **dev-together PR** (edit the skill — team-discussed,
> lead admin-merges) or a tracked **process-debt** item with an owner. Write this
> section **even if "none"**. **Every finding names the process rule (existing or
> new) that would have caught it** — a finding with no mapped rule is a signal to
> add one.

| # | 发现（finding） | 会抓到它的规则（existing/new） | 去向：skill-change / process-debt |
|---|---|---|---|
| 1 | | | |

## §5 次日规划建议（next-day planning suggestions）
<What to sequence differently, which conflicts to pre-empt, which deferrals to
schedule, process tweaks. This feeds tomorrow's `plan` §0 修正 + §2 tracks.>

## §6 roster 更新（single writer）
> `review` is the ONLY writer of `current_track`/`latest_return` in
> `docs/together/team.md`. Set each human dev's next track here.

- <short_name>: `current_track` → <next> · `latest_return` → <path/PR#>
- …
```

---

## Team-facing render — `review.html` (MANDATORY)

Alongside `review.md`, produce `docs/together/YYYY-MM-DD/review.html` — a clean,
product-first rendering for the whole team, rendering §0–§5 in order:
**product 大局 → task stats → efficiency → risks/deferred → method-deltas →
next-day plan**. It is a team artifact, not a worklog: **omit all Claude↔lead
discussion meta**, keep it self-contained (inline CSS, no external assets), and
match the house style (see `docs/together/2026-06-30/review.html` and
`2026-07-08/review.html`). A missing `review.html` means `review` is incomplete.
