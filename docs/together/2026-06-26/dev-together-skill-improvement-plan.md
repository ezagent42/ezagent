# dev-together skill 改进计划 — 2026-06-26

> **作者**: Claude (lead-agent), 受 lead（Allen / 林懿伦）2026-06-26 新需求委托。
> **目的**: 把 Allen 的 5 条新需求（A–E）落成 dev-together skill 的**可实现改动清单**。
> **本文是 PLAN，不是实现**：HTML/脚本/模版以**草图 (sketch)** 给出，颗粒度足够让
> **jjkysy（skill owner）或一名 worker** 直接照做。
> **接续既有工作**: 2026-06-25 已派 `jjkysy` 做 `chore/dev-together-skill-improve`
> （handoff: `docs/together/2026-06-25/handoffs/jjkysy-dev-together-skill-improve.md`）。
> 本计划是那条 handoff 的**超集/细化**——它已覆盖"可外发/内部分离、系统功能层面、
> 按人完成、待办、off-plan 预算、完整 github 名、clarify front-load"；本计划**新增** A
> (CURRENT_DATE)、B (数据驱动 HTML review + 持久化)、C (contributing/ + read-before-handoff)、
> D (三段式 team-facing plan)、E (硬性 scrub 规则)。**不另起命令——8 命令词表保持不变**
> （grill 已锁定），只加脚本/flag/目录/章节。

---

## 0. 设计约束（不可违反）

1. **8 命令词表不变** (`init/plan/handoff/dive/return/push/close/review`)。新增=脚本/flag/目录/章节，绝不加命令。
2. **可外发产物用中文**（团队 GMT+8；沿用双语 `<name>.md`(EN)+`<name>.zh_cn.md`(中) 约定）。
3. **不删既有 review 职责**：B 的重写必须保留现有 "Required accounting"（plan/return/stack/merge 计数）+ method-deltas 学习闭环——后者按 E **挪出公开 HTML**，落到 `contributing/`（见 §4.E 的归属裁决）。
4. **read-before-handoff 无法机器强校验**：是 required-reading 行 + checklist gate + 可选非阻塞提醒 hook（仿现有 deadline hook），**不是硬 block**。如实写明，别承诺"验证已读"的 hook。
5. 这是 PLAN：模版/脚本/HTML 给草图，留实现给 jjkysy。

---

## 1. 改动总览（按文件）

| 文件 | 改动 | 需求 |
|---|---|---|
| `SKILL.md` | 改 artifact-layout（加 `contributing/`、`stats/`、`CURRENT_DATE`）；加**日界规则**(A)；加**team-facing scrub 规则**(E)；加 **read-before-handoff** 规则(C) | A,C,E |
| `commands/review.md` | **大改**：新增"数据采集+持久化到 `stats/cycle-data.json`"步骤；三大章节（§1 昨日工作统计 / §2 昨日开发效能 / §3 数据统计）；输出 **HTML**；§2 分析写入 `contributing/`；method-deltas 移出公开稿 | A,B,C,E |
| `commands/plan.md` | 三段式 team-facing：§1 本周目标功能点缺口 / §2 缺口开发计划(总览) / §3 按开发者规划（各指向其 handoff doc）；读 `CURRENT_DATE` 而非 `date +%F` | A,D,E |
| `commands/handoff.md` | 加"派发前必读 `contributing/`"步骤(C)；按 `CURRENT_DATE` 定目录 | A,C |
| `commands/return.md` | 加"返还前必读 `contributing/`"步骤(C)；method-friction 捕获改指向 `contributing/`(C/E) | C,E |
| `commands/dive.md` | required-reading 加 `contributing/`(C) | C |
| `commands/init.md` | `new_day.sh` 现在也 scaffold `contributing/` 软链 + `stats/`；读/初始化 `CURRENT_DATE`(A) | A |
| `references/review-template.html` | **新增**：team-facing HTML review 草图（§5） | B |
| `references/plan-template.md` | **新增**：三段式 plan 草图（§6） | D |
| `references/contributing-entry-template.md` | **新增**：`contributing/` 条目格式 + seed 示例（§7） | C |
| `references/team-facing-scrub-checklist.md` | **新增**：scrub 清单（§8） | E |
| `references/handoff-template.md` | §1 required-reading 永久加一行 `docs/together/contributing/`(C) | C |
| `scripts/new_day.sh` | 读写 `CURRENT_DATE`(A)；scaffold `stats/` + `contributing/` 软链 | A,B,C |
| `scripts/gather_stats.sh` | **新增**：git/gh → `stats/cycle-data.json`（§9） | B |
| `scripts/advance_cycle_date.sh` | **新增**：4 前置条件满足后推进 `CURRENT_DATE`(§3) | A |
| `scripts/validate_skill.sh` | 为每条新规则加断言（否则规则不被强制）(§10) | all |
| `docs/together/contributing/` | **新增目录** + `README.md` + seed 条目(jjkysy kanban)(§7) | C |
| `docs/together/CURRENT_DATE` | **新增 flag 文件**(§2) | A |

---

## 2. 需求 A — 日界 = lead↔lead-agent **讨论**，不是机器时间

### 问题
机器时间一过 00:00 就把昨天的活儿"重新日期化"到新一天，污染统计：在 lead 确认今天 plan 之前，**所有进行中的活儿都属于昨天**，应进昨天的 review。新一天只有在以下都满足后才"开始"。

### CURRENT_DATE flag 文件
- **位置**: `docs/together/CURRENT_DATE`（仓库根下 together/ 顶层，跨日持久）。
- **格式**: 单行 `YYYY-MM-DD`（活跃 cycle 日期）。可选第二行 `# advanced_by: <lead> at <iso-ts>` 注释做审计。极简，纯文本，便于 grep / cat / 脚本读。
- **语义**: 这是"**活跃 cycle 日期**"，**不是** `date +%F`。所有 dev-together 写产物的命令用它定 `docs/together/<DATE>/`。

### 状态机 —— 谁推进、4 个前置条件
新一天**只在 lead 跑 `scripts/advance_cycle_date.sh`** 时推进，且脚本断言以下 4 个前置全满足（针对**昨天 = 当前 CURRENT_DATE**）：
1. 昨天的 **review 已写**（`<CURRENT_DATE>/review.html` + `review.zh_cn.md` 存在且非 scaffold）。
2. 今天的 **plan 已写**（`<new_date>/plan.md` 存在且过 plan-completeness gate）。
3. 二者 **lead 已确认**（脚本读一个确认标记：plan.md frontmatter `lead_confirmed: true`，或交互式 `--confirm`）。
4. 今天的 **handoff docs 已备齐**（`<new_date>/handoffs/` 非空，覆盖 plan 里每个 task）。
全满足 → 脚本把 `CURRENT_DATE` 写成 `<new_date>`（`<new_date>` 默认 `date +%F`，可 `--date` 覆盖以处理跨夜场景）。任一不满足 → 脚本**退出非 0 并列出缺哪条**，CURRENT_DATE 不动。

> **关键效果**: lead 凌晨 1 点还在收昨天的尾，CURRENT_DATE 仍是昨天 → `return`/`push`/`close` 全归到昨天的文件夹 → review 把它们算进昨天。机器跨日**永不**静默改日期。

### 每个"读日期"切换点（A 的实质）
把所有 `date +%F` / `$(date +%F)` 改成"读 CURRENT_DATE"（缺失则报错而非默认机器日期——let-it-crash，避免静默误日期）：

| 切换点 | 现状 | 改成 |
|---|---|---|
| `scripts/new_day.sh` | `DATE="${1:-$(date +%F)}"` | `DATE="${1:-$(cat docs/together/CURRENT_DATE)}"`；若 flag 不存在且无 `$1`，报错提示先 `advance_cycle_date.sh`/`init` |
| `commands/plan.md` | "Ensure today's folder exists" | plan 写的是**新一天**目录：plan 在 advance **之前**跑（前置条件 2），故 plan **接受 `--date <new>` 参数**，默认 `date +%F`；advance 后才落为 CURRENT_DATE |
| `commands/review.md` | `<date>/review.md` | `<date>` = **CURRENT_DATE**（昨天）——review 永远写当前活跃 cycle |
| `commands/handoff.md` | `<date>/handoffs/` | 前置条件 4 的 handoff 写**新一天**目录（与 plan 同 `--date`）；advance 后 dispatch |
| `commands/{dive,return,push,close}.md` | `<date>/` | 读 **CURRENT_DATE**（dev 干的活儿、return、stack、close 全归活跃 cycle） |
| `commands/init.md` | `new_day.sh` | init 若 CURRENT_DATE 不存在则初始化为 `date +%F`（首次 bootstrap） |

> **时序澄清**（写进 SKILL.md）：`review`(昨天) 与 `plan`/`handoff`(新一天) 在 CURRENT_DATE **仍是昨天**时同时进行——review 写 CURRENT_DATE 目录，plan/handoff 写 `--date 新一天` 目录。三者齐备 + lead 确认 → `advance_cycle_date.sh` 翻牌 → dev 开工，新一天的 `dive/return/...` 才落进新目录。

---

## 3. `scripts/advance_cycle_date.sh`（新增）草图

```bash
#!/usr/bin/env bash
# 推进 dev-together 活跃 cycle 日期。只有 lead 跑。
# 4 前置全满足才翻 CURRENT_DATE，否则退出非 0 并列出缺项。
set -euo pipefail
ROOT="${DEV_TOGETHER_ROOT:-docs/together}"
CUR="$(cat "$ROOT/CURRENT_DATE")"          # 昨天
NEW="${1:-$(date +%F)}"                      # 新一天（--date 覆盖）
FAIL=0
chk(){ [ "$2" = ok ] || { echo "✗ 缺: $1"; FAIL=1; }; }

# 1 昨天 review 已写
[ -s "$ROOT/$CUR/review.html" ] && [ -s "$ROOT/$CUR/review.zh_cn.md" ] && r=ok || r=no
chk "昨天($CUR) review.html + review.zh_cn.md" "$r"
# 2 今天 plan 已写且过 gate（简化：存在且非 scaffold 占位）
[ -s "$ROOT/$NEW/plan.md" ] && ! grep -q '<task-id>' "$ROOT/$NEW/plan.md" && p=ok || p=no
chk "今天($NEW) plan.md 已填" "$p"
# 3 lead 已确认
grep -q '^lead_confirmed:\s*true' "$ROOT/$NEW/plan.md" 2>/dev/null && c=ok || c=no
chk "plan.md lead_confirmed: true" "$c"
# 4 handoff 备齐（非空目录）
[ -d "$ROOT/$NEW/handoffs" ] && [ -n "$(ls -A "$ROOT/$NEW/handoffs" 2>/dev/null)" ] && h=ok || h=no
chk "今天($NEW) handoffs/ 非空" "$h"

[ "$FAIL" = 0 ] || { echo "未推进 CURRENT_DATE（缺项见上）。"; exit 1; }
printf '%s\n# advanced_by: %s at %s\n' "$NEW" "${USER:-lead}" "$(date -Iseconds)" > "$ROOT/CURRENT_DATE"
echo "✓ CURRENT_DATE: $CUR → $NEW"
```

---

## 4. 需求 C / E — `contributing/` 目录 + read-before-handoff + scrub 规则

### C. `docs/together/contributing/`（新增，cycle 间持久）
- **位置**: `docs/together/contributing/`（与 `team.md` 同层，跨 cycle 持久）。**不**放进每天目录——它是**累积的团队开发原则违例 + 潜在问题 + 流程摩擦 (process-friction)**台账（charter 明确含三类：原则违例、潜在系统问题、流程摩擦——见下 §5.3 的归属裁决，dev 在 return 捕获的 method-friction 流向这里）。
- **每个 cycle 的 `review` §2 分析喂它**：把当轮暴露的"开发原则违例 / 潜在问题"提炼成条目 append 进来。
- **每名 developer/agent 在每次 handoff 前必读**（lead 派发 *和* dev 返还都要读）。
- **每天 cycle 目录里放一个软链** `docs/together/<DATE>/contributing -> ../contributing`（`new_day.sh` 建），让 handoff 的相对 required-reading 路径稳定。

#### read-before-handoff 强制
> **诚实前提**：无法机器验证"人是否真读了文件"。但**可以**把它做成与 return-gate（CI-URL / `deadline_status`）同级的**机械闸**——靠一个**必填 attestation 字段**，缺它则 handoff/return 无效。这就是 Allen 要的"enforcement hook"的可实现形态（见开放问题 #7 请 lead 签字）。三层，从硬到软：
1. **必填 attestation 字段（硬闸）**：handoff 元数据块 + return 元数据块各加一行
   `contributing_read_through: <commit-sha 或 日期>`（读到 `contributing/` 哪条）。
   `validate_skill.sh` 断言这两个命令的模版含该字段；**`return` 缺该字段视为无效返还**（与缺 `returned_at`/`deadline_status` 同处理——`push` 标 `blocked` 直到补上）。这是真闸，不只 checklist。
2. **required-reading 行**（硬约定）：`handoff-template.md` §1、`dive.md`、`return.md`、`handoff.md` 把 `docs/together/contributing/README.md` 列为**永久必读**。
3. **非阻塞提醒 hook**（软）：仿 `hooks/handoff-deadline-reminder.sh` 加一个 `Stop` hook，在 dev 进入 dive/return 阶段时提醒"先过一遍 contributing/"。**不验证是否真读**——只提醒。

### E. team-facing scrub 硬性规则
- **铁律**（写进 SKILL.md 顶部 + review/plan 命令）：plan 与 review 是给**整个团队**的，**不是** lead↔lead-agent 的讨论记录。讨论过程 / lead-agent-only 机制 / claude 内部备注**绝不**出现在 plan 或 review。
- **method-deltas/method-writeback 的归属裁决**（解决与 E 的冲突——三类信号各有去处，无一丢失）：现有"内部学习闭环"**移出公开 HTML review**：
  - dev 在 `return` 捕获的 **method-friction（流程摩擦：handoff/DoD/scope 哪里错/未知）** → 仍捕获，**流向 `contributing/`**（它的 charter 已含"流程摩擦"，见 §4.C）。这是团队全员该知道的"下次别再这样派活"，故是 team-facing 台账的一类，**不是** lead↔lead-agent 私货。
  - **method-deltas → dev-together-PR / process-debt 的提升信号（既有 back-phase 学习闭环）保留不丢**：lead 在 `review` 仍**必须**triage `contributing/` 新增的 friction/违例条目，每条裁成 **dev-together PR**（改 skill）或 tracked process-debt。这一步落 `docs/together/<DATE>/notes/`（lead 的 triage 决策底稿，内部），但**触发源（friction 条目）在 `contributing/` 公开台账**——既满足 E（公开稿不含讨论过程），又保住 PDCA 的 Act 相（学习闭环不被静默删除）。
  - lead↔lead-agent 的内部讨论底稿 → 落 `docs/together/<DATE>/notes/`（git-tracked 但**不外发**，已有先例：2026-06-25/notes/）。
  - 公开 review HTML **只**含团队该看的：工作统计、效能、数据。
- **scrub checklist**（新文件 §8）：写公开 plan/review 前逐条过——无 "我 (Claude)/lead-agent/我们讨论/codex 说/内部" 字样；无 OAuth/token/路径泄漏；无未外发的决策辩论；身份用**完整 github 名**不用代称。

---

## 5. 需求 B — review = team-facing、数据驱动、HTML 输出

### 数据采集 + 持久化（写 HTML **之前**必须先做，结构化落盘）
- **落盘位置**: `docs/together/<DATE>/stats/cycle-data.json`（每 cycle 一份；`new_day.sh` 建 `stats/`）。
- **采集脚本**: `scripts/gather_stats.sh`（§9）用 git + `gh` 算出：
  1. **总 PR 数**（本 cycle 合进 main 的）。
  2. **每任务 dev-time** = 该 PR **最早 commit 时间 → merge 时间**。
  3. **每 dev 贡献** = feature-points（文字）+ LOC，**把该 dev 管理的 claude/CC agent 的活儿算作 dev 自己的**——按 **PR author (github 用户名) → team.md 行**归并（commits 已落在管理人的 git 身份下，见下"归并规则"）。
- HTML/zh_cn 稿**从 cycle-data.json 渲染**——数据先持久化，呈现是其投影。

#### agent 工作归并规则（已据 git 实情确定）
- 仓库实情：agent 提交落在**管理人的 git author name** 下（如 `Allen Woods | claude-agent@noreply.anthropic.com`），PR-merge 落在管理人的 **github 用户名**（`gagameow`/`zyli-developer`/`jjkysy`…）。
- 故归并 key = **PR author 的 github 用户名 → team.md 的 `github_username` 行**。该 dev 名下所有 PR（含其 agent 写的）天然算作他的。
- **可选增强**：team.md 加一列 `agents:`（如 `gagameow → [gaga-cc, gaga-codex]`），当某 agent 直接以独立身份开 PR 时用它映射回管理人。**默认不需要**（当前都走管理人身份）；列为开放项，按需启用。

### review 三大章节（HTML）
- **§1 昨日工作统计** — 按任务表格：`昨日任务 / 昨日完成(文字) / 实现PR / 参与开发人员 / summary`。
- **§2 昨日开发效能** — 逐 PR 效能（dev-time）、依赖关系、下一步改进建议（拆开发顺序解耦？预先拆分/调研？）、+ **遇到的问题分析**（此分析**喂 `contributing/`**）。
- **§3 数据统计** — 按 author / 按 PR / 按时间窗，**聚焦 FEATURE POINTS，不是 LOC**（LOC 为辅）。

### HTML 模版草图 — `references/review-template.html`
干净、可读、可团队分享。单文件、内联 CSS、无外部依赖（便于 send_file / 直接浏览器打开）：

```html
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dev-together 日报 — {{DATE}}</title>
<style>
  :root{--fg:#1a1a1a;--mut:#666;--line:#e5e7eb;--ok:#16a34a;--warn:#d97706;--bg:#fff;--card:#f9fafb}
  *{box-sizing:border-box} body{font:15px/1.6 system-ui,"PingFang SC",sans-serif;color:var(--fg);background:var(--bg);max-width:960px;margin:0 auto;padding:24px}
  h1{font-size:24px;margin:0 0 4px} .sub{color:var(--mut);margin:0 0 24px}
  h2{font-size:19px;margin:32px 0 12px;padding-bottom:6px;border-bottom:2px solid var(--line)}
  table{width:100%;border-collapse:collapse;margin:12px 0;font-size:14px}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{background:var(--card);font-weight:600}
  .kpi{display:flex;gap:16px;flex-wrap:wrap;margin:12px 0}
  .kpi .box{flex:1;min-width:140px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
  .kpi .n{font-size:28px;font-weight:700} .kpi .l{color:var(--mut);font-size:13px}
  .ok{color:var(--ok)} .warn{color:var(--warn)} .fp{font-weight:600}
  code{background:var(--card);padding:1px 5px;border-radius:4px;font-size:13px}
</style></head><body>
<h1>dev-together 日报</h1>
<p class="sub">活跃 cycle：{{DATE}} · lead：{{LEAD}} · 数据源：<code>stats/cycle-data.json</code></p>

<div class="kpi">
  <div class="box"><div class="n">{{TOTAL_PRS}}</div><div class="l">合入 PR</div></div>
  <div class="box"><div class="n">{{TOTAL_FP}}</div><div class="l">功能点 (FP)</div></div>
  <div class="box"><div class="n">{{AVG_DEVTIME}}</div><div class="l">平均 dev-time</div></div>
  <div class="box"><div class="n">{{DEVS}}</div><div class="l">参与开发者</div></div>
</div>

<h2>§1 昨日工作统计</h2>
<table><thead><tr><th>昨日任务</th><th>昨日完成（文字）</th><th>实现 PR</th><th>参与开发人员</th><th>summary</th></tr></thead>
<tbody>{{#TASKS}}<tr><td>{{task}}</td><td>{{done_text}}</td><td>{{prs}}</td><td>{{devs}}</td><td>{{summary}}</td></tr>{{/TASKS}}</tbody></table>

<h2>§2 昨日开发效能</h2>
<table><thead><tr><th>PR</th><th>dev-time<br><small>最早commit→merge</small></th><th>依赖</th><th>遇到的问题</th><th>下一步改进</th></tr></thead>
<tbody>{{#PR_EFF}}<tr><td>{{pr}}</td><td>{{devtime}}</td><td>{{deps}}</td><td>{{problems}}</td><td>{{next}}</td></tr>{{/PR_EFF}}</tbody></table>
<p class="sub">问题分析 → 已沉淀进 <code>docs/together/contributing/</code>（团队开发原则/潜在问题台账）。</p>

<h2>§3 数据统计（聚焦功能点）</h2>
<h3>按 author</h3>
<table><thead><tr><th>开发者（含其 agent）</th><th class="fp">功能点</th><th>PR 数</th><th>LOC（辅）</th></tr></thead>
<tbody>{{#BY_AUTHOR}}<tr><td>{{author}}</td><td class="fp">{{fp}}</td><td>{{prs}}</td><td>{{loc}}</td></tr>{{/BY_AUTHOR}}</tbody></table>
<h3>按 PR</h3>
<table><thead><tr><th>PR</th><th class="fp">功能点</th><th>author</th><th>dev-time</th><th>LOC</th></tr></thead>
<tbody>{{#BY_PR}}<tr><td>{{pr}}</td><td class="fp">{{fp}}</td><td>{{author}}</td><td>{{devtime}}</td><td>{{loc}}</td></tr>{{/BY_PR}}</tbody></table>
<h3>按时间窗</h3>
<table><thead><tr><th>时间窗</th><th class="fp">功能点</th><th>PR 数</th></tr></thead>
<tbody>{{#BY_WINDOW}}<tr><td>{{window}}</td><td class="fp">{{fp}}</td><td>{{prs}}</td></tr>{{/BY_WINDOW}}</tbody></table>

<p class="sub">本报告对全体开发者公开。内部讨论/lead-agent 机制不在此文（见 scrub 规则）。</p>
</body></html>
```

> 渲染方式（写进 review.md）：jjkysy 可用最朴素的占位替换（sed/`uv run` 小脚本读 cycle-data.json 填 `{{...}}`），**不引入模版引擎依赖**（ponytail）。`{{#X}}…{{/X}}` 仅是"按 X 数组重复一行"的标记，几行脚本即可。

### `commands/review.md` 改写要点
1. 第 0 步：跑 `scripts/gather_stats.sh` → `stats/cycle-data.json`（数据先落盘）。
2. 渲染 §1/§2/§3 → `<DATE>/review.html`（公开）+ `<DATE>/review.zh_cn.md`（同内容 md 外发版，便于 Feishu）。
3. §2 的问题分析 append 到 `docs/together/contributing/`（C）。
4. method-deltas/内部讨论 **不进 HTML**，落 `<DATE>/notes/`（E）。
5. **保留**现有 "Required accounting"（plan/return/stack/merge 计数、late、superseded…）——并入 §3 或 §1 的统计口径，别丢。
6. **保留**现有"roster 单一写者"职责（更新 team.md 的 current_track/latest_return）。

---

## 6. 需求 D — plan = team-facing，三段式

### `references/plan-template.md`（新增）+ `commands/plan.md` 改写
plan 产出三段（中文、可外发、scrub 过）：

```markdown
# dev-together 计划 — {{DATE}}（团队开发计划）
> planned_at · lead · day_deadline · timezone · base_main · **lead_confirmed: false**

## §1 本周目标功能点缺口
<读 2026-Www/weekly-goals.md；把每个周目标拆成"还差哪些功能点"。每行=一个功能点缺口 + 它服务的周目标。>
| 周目标 | 功能点缺口 | 当前状态 | 阻塞它的是什么 |
|---|---|---|---|

## §2 缺口开发计划（总览）
<把 §1 的缺口排成本 cycle 的开发计划：先后、并行、依赖、谁牵头。一张总览表，不展开到人。>
| 缺口 | 计划动作 | 负责开发者(完整 github 名) | 分支 | 依赖/顺序 |
|---|---|---|---|---|

## §3 按开发者规划的开发任务
<每名 human-dev 一小段：今日任务一句话 + 指向他的 handoff doc 路径。简短，细节在 handoff。>
- **`<github_username>`（中文名）** — <一句话任务> → handoff: `handoffs/<task>.md`

## Off-plan / 越界预算（保留既有）
<agent 支持、lead 自做的部署等；越界预算声明。>

## Conflict map（保留既有）
```

要点：
- §1 直接接 weekly-goals → 以**功能点缺口**为单位（不是 LOC、不是任务）。
- §3 每条**指向 dev 的 handoff doc**（薄 plan / 厚 handoff，避免重复）。
- 保留既有 plan-completeness gate（roster 来自 team.md、每 track 映射周目标、cite latest_return、conflict map）。
- frontmatter 加 `lead_confirmed:`（advance_cycle_date.sh 的前置 3 读它）。

---

## 7. `references/contributing-entry-template.md` + seed（C）

### `docs/together/contributing/README.md`（新建，台账头）
说明：这是团队累积的**开发原则违例 + 潜在问题**台账；每 cycle review §2 喂它；每次 handoff 前必读。

### 条目格式
```markdown
## [{{cycle-date}}] {{一句话标题}}
- **暴露于**: <哪个 PR/任务/dev>
- **违反的原则**: <如 "resource 必须是静态文件" / "let-it-crash 不加 workaround">
- **更深的潜在问题**: <这条违例暴露出的、更普遍的系统性缺口>
- **建议/对策**: <下次怎么避免；是否需要新 arch gate / 新 skill 规则>
```

### seed 条目（按 Allen 的示例预填）
```markdown
## [2026-06-25] kanban-as-role：好点子但踩了静态资源原则
- **暴露于**: jjkysy 的 kanban-as-role 设计（#983/#984/#986/#987 一线）
- **违反的原则**: "resource 必须是静态文件"——kanban 当成 role 是好的抽象，但实现把动态看板塞进了静态 resource 契约。
- **更深的潜在问题（团队级、常见）**:
  1. **role-foundation 还没搭**——大家在没有 role 物化地基时就往上叠 role 语义。
  2. **"什么是 agent" 不清晰**——agent 的边界/身份/生命周期定义模糊，导致 role/agent/resource 三者职责互相渗透。
- **建议/对策**: 先夯 role-materialization foundation（per-instance mount + role recipes，见 #984）；在 skill/arch 里写清 agent 定义；新设计先过"它是不是想把动态状态塞进静态 resource"这一问。
```

---

## 8. `references/team-facing-scrub-checklist.md`（E）

写公开 plan/review（HTML + zh_cn）前，逐条过：
- [ ] 无第一人称 lead-agent 痕迹："我(Claude)/我们讨论/lead-agent/我建议…"。
- [ ] 无 lead↔lead-agent 决策辩论过程（结论可留，过程移 `notes/`）。
- [ ] 无 claude 内部机制/codex 调度细节/subagent 编排说明。
- [ ] 无凭据泄漏（token/OAuth/绝对私密路径）。
- [ ] 身份一律用**完整 github 用户名**（+ 中文名），不用内部代称。
- [ ] method-friction/原则违例已落 `contributing/`，公开稿只留去身份化的产品/效能视角。
- [ ] 内容是"团队全员该看的"，不是"lead 自己的工作笔记"。

---

## 9. `scripts/gather_stats.sh`（新增）草图（B）

```bash
#!/usr/bin/env bash
# 采集本 cycle 的开发数据 → stats/cycle-data.json。review 写 HTML 前先跑。
# 依赖 git + gh。需 lead 提供本 cycle 的 PR 集（或按 merge 时间窗 + base_main 推断）。
set -euo pipefail
ROOT="${DEV_TOGETHER_ROOT:-docs/together}"
DATE="$(cat "$ROOT/CURRENT_DATE")"
OUT="$ROOT/$DATE/stats/cycle-data.json"; mkdir -p "$(dirname "$OUT")"

# 1 本 cycle 合入 main 的 PR（窗口 = 上一 cycle base_main..HEAD，或 gh 按 mergedAt 过滤）
#   gh pr list --state merged --base main --json number,title,author,mergedAt,additions,deletions,headRefName
# 2 每 PR dev-time = 最早 commit 时间 → mergedAt
#   earliest=$(git log --format=%cI <base>..<head> | tail -1)
# 3 归并：author.login → team.md 的 github_username（agent 活儿天然在管理人名下）
# 4 feature-points：**人工/LLM 标注**（见开放问题①——FP 单位未定义）。
#   先留字段 fp（可空/占位），等 Allen 定义 FP 口径后回填。
# 输出形如：
# { "date":"...", "total_prs":N, "tasks":[...], "pr_eff":[...],
#   "by_author":[{"author":"gagameow","fp":"...","prs":N,"loc":N}],
#   "by_pr":[...], "by_window":[...] }
echo "wrote $OUT"
```

> **LOC** 从 `gh ... additions/deletions` 直接拿。**dev-time** 需 PR head 在本地可达（或用 `gh pr view --json commits` 取最早 commit 时间）。**feature-points** 是唯一需人/LLM 判断的字段——脚本只搭骨架 + LOC + dev-time，FP 留待口径确定。

---

## 10. `scripts/validate_skill.sh` 新增断言（每条新规则都要被强制）

```bash
require "SKILL.md" "CURRENT_DATE" "活跃 cycle 日期 flag 规则"
require "SKILL.md" "contributing/" "contributing 台账规则"
require "SKILL.md" "team-facing|外发|不是.*讨论" "team-facing scrub 铁律"
require "commands/review.md" "cycle-data.json" "数据持久化步骤"
require "commands/review.md" "昨日工作统计|review\\.html" "三章节 + HTML 输出"
require "commands/plan.md" "本周目标功能点缺口|功能点缺口" "三段式 team-facing plan"
require "commands/plan.md" "lead_confirmed" "lead 确认标记"
require "commands/handoff.md" "contributing" "派发前必读 contributing"
require "commands/return.md" "contributing|contributing_read_through" "返还前必读 contributing"
require "commands/return.md" "contributing_read_through" "已读 contributing attestation 必填字段"
require "references/handoff-template.md" "contributing" "handoff 永久必读 contributing"
# 文件存在性（skill 自身内容，非运行期状态）
test -f references/review-template.html
test -f references/plan-template.md
test -f references/contributing-entry-template.md
test -f references/team-facing-scrub-checklist.md
test -x scripts/gather_stats.sh
test -x scripts/advance_cycle_date.sh
```
> **注意**：validate 只断言 **skill 自身内容**（命令描述了机制、脚本存在），**不**断言运行期产物
> （`docs/together/CURRENT_DATE`、`contributing/` 目录）——后者在全新 checkout 或首个 cycle 前不存在，
> 会误失败。运行期状态的存在性由 `init`/`new_day.sh` 负责创建，若需校验另开一个独立 runtime check，不混进 validate。

---

## 11. 实现顺序（给 jjkysy）

1. **基础设施先行**：建 `CURRENT_DATE`、`contributing/`(+README+seed)、`stats/` scaffold；改 `new_day.sh`。
2. **A 日界**：`advance_cycle_date.sh` + 各命令的"读 CURRENT_DATE"切换 + SKILL.md 时序说明。
3. **C/E**：`contributing/` 必读步骤（4 文件）+ scrub checklist + SKILL.md 铁律 + handoff-template §1。
4. **D plan**：`plan-template.md` + `plan.md` 三段式重写。
5. **B review**：`gather_stats.sh` + `review-template.html` + `review.md` 重写（保留既有 accounting/roster 职责）。
6. **validate**：补全 `validate_skill.sh` 断言；跑通。
7. **自验**（DoD）：用新模版**重跑一遍 2026-06-24 的 review**（HTML + zh_cn）作"好版式"对照样例；`bash scripts/validate_skill.sh` 通过；CI 绿 + rebase main。

---

## 12. 给 lead（Allen）的开放问题

1. **功能点 (feature-point) 的口径未定义**——B§3 与 D§1 都以 FP 为单位，但仓库**无 FP 台账**，weekly-goals 是散文。FP 是：① 一个周目标拆出的能力项？② 一个 PR 标 N 个 FP？③ 还是按 task？请定义 FP 的粒度与登记位置（建议：`weekly-goals.md` 里把每个周目标拆成带 id 的 FP 清单，PR/return 引用 FP id）。**这是 B/D 数据驱动的地基**，FP 不定义则 §3 的"聚焦功能点"无从量化。
2. **agent→管理人映射**：当前 agent 提交都落在管理人 git/github 身份下，故"按 PR author 归并"即可，**无需新 map**。但若以后 agent 直接以独立身份开 PR，是否要在 `team.md` 加 `agents:` 列？（默认不加，按需启用——确认即可。）
3. **CURRENT_DATE 的 lead 确认**用什么信号？建议 `plan.md` frontmatter `lead_confirmed: true`（脚本可读、留痕）；或你更想要交互式 `--confirm`？
4. **review 输出双份**（`review.html` 公开 + `review.zh_cn.md` 外发）是否都要？还是 HTML 为主、md 仅作 Feishu 摘要？
5. **gather_stats 的 PR 集**怎么界定一个 cycle？按 `上一 cycle base_main..HEAD` 的 git 区间，还是 `gh pr list --mergedAt` 落在 cycle 时间窗内？（建议前者，确定性强。）
6. 本计划与 **jjkysy 已在 `chore/dev-together-skill-improve` 上的工作**重叠/超集——是让 jjkysy 在同分支继续吸收 A–E，还是另派？（建议同分支续做，他是 skill 单一写者。）
7. **"enforcement hook"(C) 的落地形态**：你要求 read-before-handoff 有 enforcement hook，但**真·读取验证 hook 不可能**（无法证明人读了文件）。本计划替代为：**必填 `contributing_read_through` attestation 字段（缺它 return 无效，与 CI-URL/deadline_status 同级机械闸）+ 非阻塞提醒 hook**。请确认这个"硬闸=必填字段、软提示=hook"的组合可接受。
