# Daily plan template (copy-paste) — the canonical `plan.md` skeleton

Copy this skeleton for the day's `plan.md`. **Fill every section**; delete a
section only if you can say *why* it doesn't apply (a deleted section carries a
one-line reason, it is never silently dropped). The rules behind each section
live in [../commands/plan.md](../commands/plan.md) and the `dev-together`
`SKILL.md`. The team-facing `plan.html` renders these same §0–§7 sections
1:1 (product-first, no Claude↔lead meta) — the section numbers must match.

> **Canonical section order — do not renumber per day.** `§0 本周大局` is
> **standing** (present in EVERY plan); `§1..§7` follow the same order every day
> so the format stops drifting and `plan.html` can mirror it 1:1.

---

```markdown
# dev-together 计划 · YYYY-MM-DD

## 元数据
- `planned_at`: YYYY-MM-DD
- `lead`: <github_username of the lead>
- `coordinator`: allenwoods + Claude(CC)   <!-- coordinator = allen + CC; agents NEVER get a track row -->
- `day_deadline`: YYYY-MM-DD EOD（<tz>）
- `timezone`: <tz>
- `lead_confirmed`: **true|false**（when — per-dev task lists confirmed before finalize; see plan.md step 7）
- `week_ref`: `docs/together/<ISO-week>/weekly-goals.md`（e.g. 2026-W29）

## §0 本周大局（STANDING — 每个 plan 必有）
> This section is **required in every daily plan**. The **week acceptance** is
> standing (same each day until it lands); **今日进度** and **修正/变化** refresh
> daily. Never drop §0 — it is the section that carries progress forward.

**本周验收（week acceptance — 具体 demo/目标，逐日不变直到达成）:**
<The one concrete demo/goal that defines "the week is done" — copied from
`weekly-goals.md`. Keep the exact end-to-end chain if there is one.>

**今日进度（progress toward the acceptance — refresh daily）:**
<Where we are against the acceptance TODAY: what has landed (SHAs/PR#s), what is
next, what still blocks. This is not a task list — it is the state of the goal.>

**修正/变化（deltas vs the last plan/state — refresh daily）:**
<What changed since the last plan: roster changes, re-scopes, a branch that
merged, a corrected assumption. "无" is a valid value but say it explicitly.>

## §1 头号目标（today's #1）
<The single most important thing today, and why it's the entry point / gate for
the rest. If it carries a **red-line**, state it here (e.g. "canary 前不宣布修好").>

## §2 按开发者规划（human-dev only）
> roster 来自 `team.md`（filter `role: human-dev`）；**agent 永不出现在 plan**
> （无 track 行、无 off-plan 节）。coordinator = allenwoods + CC 只记于元数据，不占
> track 行。每条 track 由该 dev 的 `latest_return` 续接，并归入 §0 week acceptance 的某一环。

| 开发者 | 本日 track | 闭环 / 依赖 | 分支 | week-goal 环 |
|---|---|---|---|---|
| **<short_name>**（<feishu_name>） | <today's increment, grounded in latest_return> | <闭环 / 依赖> | `<per-task-branch>` | <which demo 环节> |

<非 track 行（designer / others）: 一句「设计输入」说明，反馈走 Feishu，不占 track 行、不改代码。>

## §3 冲突图（cross-task conflict map）
| 任务 | 拥有面 / 文件 | 冲突 | 并行 / 串行 |
|---|---|---|---|
| … | … | … | … |

- **触 `world` 的 track:** 适用 `docs/guide/world-coordination.md`——声明 surface 归属、
  串行化 `styles.css`、遵守 layout gate。
- 互不重叠的 track 标注可并行。

## §3a Plan-level system closure
| Closure | X problem | Plan invariant | Related tracks | Durable proof | Integration evidence |
|---|---|---|---|---|---|
| | | | | | |

**Closure checkpoints:** <frozen implementation commits and gates>
**Stop Rule owner:** <lead>

## §4 依赖与 handoff 顺序 / 并行
<The intended handoff order + what runs in parallel; which tasks need
brainstorming/design confirmation before build (discuss-first). Note the
coordinator's integration/merge responsibilities here if relevant.>

## §5 开工 prompt（每个 dev 一段 paste-ready）
> One kickoff block per human dev — paste-ready, the dev/their agent starts from
> it. For a task with real unknowns, use the full `handoff` command
> ([../commands/handoff.md](../commands/handoff.md)) for the deeper spec; this §5
> block is the fast-path kickoff.

### <short_name> — <track one-liner>
- **分支:** `<per-task-branch>`（先 `git fetch origin main` 再从 `origin/main` 切）
- **范围:** <scope — what's in, what's out>
- **必读:** <skill(s): ezagent-developer + others> · <spec/notes by path> · dev-together 技能（`references/handoff-standard.md`）· `docs/guide/world-coordination.md`（若触 `world`）
- **DoD:** <pointer — the demonstrable proof this track owes; see handoff-standard 四属性>
- **闸:** `arch.scan + doc.scan + uri_query.scan + check_invariants`（或整套 `mix ci.local`）+ 本任务自有回归测试 + **PR-head CI 绿 + rebase 到 current main**
- **规约:** 每任务一分支，PR 只并入本任务分支（不进 `main`）；**return 前 PR CI 必须绿**；lead 走 `close` 合入 main。<red-line if any>

<repeat one ### block per human dev>

## §6 out-of-scope / backlog（登记 + 归因）
<Anything deliberately not in today's tracks: register it + attribute to one of
「偏离方向（拉回）」or「底层疏漏（系统排查）」per team.md 派发原则 §3. Deferrals
are lead-adjudicated, not dev-declared.>

## §7 协作约束
- **CI 闸:** return 前本地跑全套静态 gate（不跑子集）；机器闸 CI 绿 ≠ 产品验证。
- **PR 标题诚实:** 未 canary 实证的修复不标「修好」。
- **canary 红线:** <如有 —— canary 前不宣布修好；须有实测证据（agent-browser 截图 / PTY join 日志 / 真实 PR + 流转截图）>。
- **评审基准:** `origin/main`（rebase 后再 return）。
- **skill 改动:** dev-together 无唯一 owner —— 全员讨论，特殊情况由 lead（allenwoods）admin-merge（「Protect dev-together skill」CI gate = lead-gated）。
```

---

## Plan completeness gate (checklist before handoff)

A `plan.md` is valid only when all hold (see [../commands/plan.md](../commands/plan.md)):

- 元数据 present incl. `lead_confirmed: true` (+ when) — the lead confirmed the
  per-dev task lists before finalize.
- **§0 本周大局 present** with all three parts: week acceptance (standing) +
  今日进度 + 修正/变化.
- §2 roster from `team.md` filtered to `role: human-dev`; **no agent has a track
  row**; every track cites its `latest_return` and maps to a §0 week goal 环.
- §3 conflict map: shared surfaces + serialization owner + parallel/serial call;
  `world` touches apply `world-coordination.md`.
- **§5 开工 prompt present — one paste-ready block per human dev.**
- §7 collaboration constraints incl. the CI gate + canary red-line + review
  baseline + the no-single-owner skill-change note.
- `plan.html` renders §0–§7 1:1 (product-first, no meta) — a missing/mismatched
  render means the step is incomplete.
```
