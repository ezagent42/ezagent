# Dev Together Team

_Last checked: 2026-07-02_

The durable roster for `dev-together`. **Row identity = `github_username`** (the
canonical key; it joins to PR authorship). `dev-together plan` reads this file,
filters to `role: human-dev`, and derives each dev's next increment from
`current_track` + `latest_return`. `current_track` / `latest_return` have a
**single writer: `dev-together review`** (end of day). A mid-stream pivot may be
reflected by the lead.

`short_name` is the alias the daily `plan.md`/handoffs use (`zyli`, `zhaomato`);
it exists so the long GitHub key joins to the short name plans cite.

| github_username | short_name | role | feishu_name | current_track | latest_return | timezone | github_lookup |
|---|---|---|---|---|---|---|---|
| `zyli-developer` | zyli | human-dev | 李震宇 | 0701 World UI shell polish aligned to ruihua direction | `2026-06-30/stack.md` | GMT+8 | verified org member |
| `gagameow` | gaga | human-dev | 黄佳佳 | 0703 Agent Console /overview + lifecycle + route tests (#1131/#1132/#1133) — rebase onto post-T1/T2 main, fix #1132 ActionSet prose, stack in author order | `2026-06-30/stack.md` | GMT+8 | verified |
| `zhaomaota97` | zhaomato | human-dev | 张宁 | 0703 Hello concierge + publish-template (#1134) — BLOCKED on 导游/客服 design; then rename-migrate off pre-T1 symbols + merge | `2026-06-30/stack.md` | GMT+8 | verified org member |
| `FatNine` | fatnine | human-dev | 戴明 | 0701 Agent Console one complete prototype path | `2026-06-30/returns/fatnine-agent-console-completeness-ia.md` | GMT+8 | verified |
| `allenwoods` | allen | lead | 林懿伦 | dev-together lead (plan/handoff/close/review) + own tracks | n/a | GMT+9 | verified |
| `jjkysy` | jjkysy | human-dev | 姚升悦 | 0701 split #1110 into reviewable PRs | `2026-07-01/handoffs/jjkysy-split-pr-1110.md` | GMT+8 | verified |
| `ruihuachen-designer` | ruihua | designer | 陈瑞华 | 0703 官网 journey scenarios (#1129) — rebase onto post-T1/T2 main + merge | n/a | GMT+8 | verified |
| `claude` | claude | agent | — | off-plan support (orchestration / fixes on request) | n/a | — | n/a |
| `codex` | codex | agent | — | off-plan support (bounded verifiable sub-tasks) | n/a | — | n/a |

> **role legend:** `human-dev` gets a daily track in `plan`. `lead` runs the
> cadence. `agent` is off-plan support — never gets a track row in the plan.
> `designer` / others are listed for the username↔Feishu map but get no track.

## Platform accounts — go-live (2026-07-06)

The seeded login accounts for the deployed platform (world). Login = email
magic-link delivered to these `@ezagent.chat` mailboxes (mail service
`email.ezagent.chat`). Admin = 林懿伦. These are the "available usernames" the
go-live reseed provisions.

| feishu_name | email | role | github_username |
|---|---|---|---|
| 林懿伦 | `lin.yilun@ezagent.chat` | **admin** | `allenwoods` |
| 姚升悦 | `yao.shengyue@ezagent.chat` | user | `jjkysy` |
| 陈瑞华 | `chen.ruihua@ezagent.chat` | user | `ruihuachen-designer` |
| 李震宇 | `li.zhenyu@ezagent.chat` | user | `zyli-developer` |
| 张宁 | `zhang.ning@ezagent.chat` | user | `zhaomaota97` |
| 黄佳佳 | `huang.jiajia@ezagent.chat` | user | `gagameow` |

> Login flow: user enters their `@ezagent.chat` email on world → app mints a
> single-use magic-link (`/auth/magic/:token`, task #87, login-only for existing
> accounts) → delivered via `email.ezagent.chat` → user opens it from their
> mailbox → logged in. Old pre-2026-07-06 accounts/data are cleared on the
> go-live reseed (agent-identity + role-on-edge data-structure change).

## Profile — background（固定）+ 强项/适合任务（review 更新）

> agent 加持下所有工程师都具备**全栈/部署**能力；差异在**开发习惯、产品 sense、
> 架构熟悉程度**——这决定开发效能与**最佳派发点**。`background` 固定；`强项/适合任务`
> 由每次 close review 的 §2 更新（见末节流程）。

| github | background | 强项 / 适合任务（动态，据 review） |
|---|---|---|
| `allenwoods` (林懿伦) | 全栈工程师 · 背景 AI 博士 · 当期职责 lead programmer | 架构/地基、对抗评审驱动的大改造、跨域整合、运行时、部署。架构熟悉度最高。6-25：独力 A+B+C + RF-1..9 + kanban-as-role + py-agent + deploy |
| `jjkysy` (姚升悦) | 全栈工程师 · 背景 AI 博士 · 当期职责 lead programmer | 架构/原则把关（主动发现 kanban 原则问题）、kanban 插件原作（#964 13.5k LOC）、dev-together skill owner。适合地基/流程/评审 |
| `gagameow` (黄佳佳) | 运维工程师 | 部署/运维、agent console（6-25）、agent 配置验证。运维 + 产品 sense |
| `zyli-developer` (李震宇) | 全栈工程师 | 全栈、E2E 体系、Feishu 适配/产品缺口。端到端验证强 |
| `zhaomaota97` (张宁) | 全栈工程师 | 全栈、前端 json-render / hello 渲染底座。前端/渲染强 |
| `FatNine` (戴明) | 后端工程师 | 后端 / core |
| `ruihuachen-designer` (陈瑞华) | 产品经理 | 产品/设计版式、可外发文档版式输入（设计输入，不改代码） |

## 任务分配原则（lead 派发遵守）

1. **任务类闭环在一人 —— 避免当日 context 搬运。** 一类任务（含其验证）当日尽量落在
   同一人，即使历史上某子环节常由他人做。*例*：6-27 若 deploy-flow 在 `allenwoods`，
   deploy-flow **E2E 也归 `allenwoods`**（非按"zyli 常做 E2E"拆走）——当日最优点是
   context 持有者。**次日** context 进 main 后，任务可迁移。
2. **最大化并行。** 若当日任务须拆两人且 A 等 B，**在 A 插 mock-B、B 插 mock-A**，
   双方先对齐 mock 契约再各自并行，消除串行等待。
3. **围绕近期目标（最重要）。** 当日工作聚焦近期目标。**大量 out-of-scope = 信号**：
   要么开发偏离方向（避免/拉回），要么底层疏漏（系统排查）。out-of-scope 必须在 plan
   显式登记并归因到这两类之一。

## profile 更新流程（据 review）

每次 close review §2（开发效能）后，lead 据其更新本档每人"强项/适合任务"：高效低返工
→ 强化该类标签；踩坑/返工 → 记 `contributing/` 并调整派发（配 mock/评审）；主动发现深层
问题 → 记"原则把关"强项。profile 是**被数据持续修正的动态档**，非一次性背景。
