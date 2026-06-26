# kanban 自举开发流程：当前规划缺失的能力

> 日期 2026-06-26 ｜ 综合 4 路研究（dev-together 流程演进 / 07 系列接力链产品语义 / kanban 插件现状能力盘点 / dev-together↔kanban 接线缺口）
> 已用 `project-discussion-esr-ng` skill 逐文件读码核实（github.ex、connectors.ex、miro_sync.ex、external_mirror 域）。每条结论带 file:line。
> 用大白话写，技术名词第一次出现都解释。

---

## 一句话结论

整条"自举开发流程"（09 接力链：定位→…→issue→测试→PR→上线回收）现在卡在**一个人工断点**上：PR 在 GitHub 那边开出来后，ezagent 收不到任何回声，必须有人肉眼看到 PR 号、手工敲 `register_pr` 把号填进看板节点。这一步堵住了它下游的**全部**自动化（硬 CI 门、自动合并推进、接力唤醒下一个 agent）。**应该新增一个独立的 github 入站插件**，把"PR 出现→登记→事件驱动 CI"自动化掉。其余缺失能力按优先级列在后面。

---

## 二、重点：register_pr 人工断点 + 该不该有新的 github plugin

### 2.1 断点到底卡在哪（现状，带证据）

现在 kanban 插件跟 GitHub 的所有交互**只有出站，没有入站**。`github.ex` 的模块注释把这点写死了：

> "纯出站（投查定论）：ezagent 真相源，GitHub 是投影——建 issue / 读 PR / post 评论，**无 inbound webhook**。"
> —— `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:9`

`github.ex` 全文只有 4 个出站方法：`create_issue`（:59）、`post_comment`（:70）、`get_pull`（:88，主动去读某个 PR）、`create_commit_status`（:117，推 CI 状态）。**没有任何一条路径能让 GitHub 主动把"有人开了 PR"这件事告诉 ezagent**。

"开 PR"这个动作发生在 GitHub 那一侧（人或 agent 在 GitHub 上点了 Create PR）。ezagent 这边要知道 PR 号，只有一条路：有人手工调 `register_pr`，把 `pr` 这个字符串（比如 `"#42"`）当参数传进来：

- `register_pr(%{id, pr}, ctx)` 的 `pr` 完全是调用方手填的 —— `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex:116`
- 它内部 `to_pr_number/1` 把 `"#42"` 解析成 42、拼出 `https://github.com/<repo>/pull/42`、挂一个 `kind="pr"` 的产物到节点（`connectors.ex:128-136`）。**没有一行代码会自己去发现 PR 号**。

这一个手填动作，同时卡住它下游的三条自动化链（全靠从节点里读回那个 `kind="pr"` 产物）：

1. **硬 CI 门发不出**：`push_pr`（`connectors.ex:75`）先靠 `node_pr(node)`（`connectors.ex` 内）从节点抠 PR 号，抠不到就直接返回 `:no_pr_registered`（`connectors.ex:94-95`）——软留言（把需求摘要 post 到 PR）和硬门（把 CI 判据推成 GitHub commit status 来挡合并）**两个都发不出去**。
2. **自动合并推进不发生**：`sync_prs`（`connectors.ex:193`）只轮询"已登记 PR"的节点，没登记的节点直接跳过，"PR merged → 节点 set_status done"这步永远不会自动触发。
3. **接力唤醒断掉**：`register_pr` 是 B1 接力动作之一（`@relay_actions`，`kanban.ex:702`），登记成功才会 fire 一条 `[kanban:pr_registered]` 公告去唤醒下一个（CI）agent。手没填，接力链就停在这。

**对称性证据**：Miro 那侧反而**有**非破坏性入站。`MiroSync` 是 kanban 插件自有的轮询进程，每个 tick 去 `GET Miro → Sync.detect_inbound`（探测人在 Miro 上新加的节点）→ `dispatch add_node` 回 ezagent（`miro_sync.ex:7`、`miro/sync.ex:166`）。也就是说 **Miro 能把"人在外部新增"自动同步回来，GitHub 完全做不到**。这个不对称就是缺口本身。

### 2.2 该不该有一个新的 github plugin？—— 该有

**该做**。理由：去掉人工断点的唯一办法，就是给 ezagent 补一条 GitHub→ezagent 的入站路径，把"PR 出现"这件事自动接回来、自动 `register_pr`、并用 PR 事件驱动 CI。这正好补上 GitHub 相对 Miro 缺的那条入站。

为什么是**独立 plugin**而不是往现有 `github.ex` 里塞：

- 现有 `github.ex` 是 kanban 插件内部的纯出站客户端（HTTP 调用工具），定位很清楚（`github.ex:9` 注释）。入站是另一种东西——它要么是 webhook（需要 Phoenix 暴露一个 HTTP 端点收 GitHub 推送）、要么是轮询（一个常驻 GenServer 去 list PRs）。这两种都是"渠道入站"形态，跟 feishu/email 插件是同一类（入站渠道 plugin），不该挤进一个出站客户端模块。
- 按项目的命名约定，入站渠道是独立 OTP app（`:ezagent_plugin_<name>`，见 CLAUDE.md 命名表 + feishu `inbound_dispatcher.ex` / email `inbound.ex` 的先例）。github 入站理应是 `ezagent_plugin_github`（或 `ezagent_adapter_github` 入站侧）。

### 2.3 新 github plugin 的职责边界（做什么 / 不做什么）

**做（plugin 的核心职责）：**

1. **入站捕获 PR**。两种实现都可，建议先做轮询、webhook 作为升级：
   - 轮询版（简单、不依赖公网回调）：一个 GenServer 定时 `GET /repos/<repo>/pulls?state=open`，按 PR 的 `head_ref`（分支名）匹配看板节点（dev-together 是 per-task 分支命名，分支名能携带节点信息），自动算出"这个 PR 属于哪个节点"。这跟 `MiroSync` 的轮询入站是同一个模式（`miro_sync.ex:7`），照抄即可。
   - webhook 版（实时、需要 Phoenix 暴露端点）：收 GitHub `pull_request` / `check_suite` / `push` 事件，验签后转成入站 dispatch。
2. **自动 register_pr**。捕获到 PR 后，不再让人手填，直接 `Ezagent.Invocation.dispatch` 调 kanban 的 `register_pr`（系统 admin 身份，对齐 `MiroSync` 用系统 cap 的先例，`miro_sync.ex:16`），把 PR 号写回节点。这一步成功会自然触发 B1 接力唤醒（因为 `register_pr` 已经在 `@relay_actions` 里，`kanban.ex:702`）。
3. **PR 事件驱动 CI**。PR 有新 commit（push 事件）或被 reopen 时，自动触发 `push_pr` 重算 CI 判据并刷新 GitHub commit status，而不是等人手动再调一次。

**不做（边界外，留给现有模块）：**

- **不自己实现 CI 判据**。判据逻辑已经在 kanban 的 `ci.ex` 里（`check_pr_gate/2` 的 4 条判据 upstream_done/gherkin/issue/test_green，`ci.ex:22`；`gate_state` 映射成 GitHub state，`ci.ex:58`）。新 plugin 只负责"在对的时机触发"，判据本身不搬家。
- **不自己推 commit status**。推状态是 `github.ex:117` + `connectors.ex:100` 已有的出站能力，新 plugin 通过 dispatch 调 kanban 动作来用，不重复实现 GitHub 出站客户端。
- **不持有看板真相源**。真相源永远是 ezagent 的看板节点（`get_tree`）。新 plugin 只是把外部世界（GitHub）的变化非破坏性地同步进来，跟 `MiroSync` 的"真相源=ezagent，GitHub/Miro 是投影"定位一致（`miro_sync.ex:9-14`）。
- **不接管出站**。建 issue / post 评论 / 推状态仍走现有出站，新 plugin 只补入站这半边。

### 2.4 跟现有出站（github.ex）/ ExternalMirror 的关系

- **跟 `github.ex`（kanban 内出站）**：互补的两半。`github.ex` 是出站客户端（ezagent→GitHub），新 plugin 是入站捕获（GitHub→ezagent）。新 plugin 不碰 `github.ex` 的代码，只通过 dispatch 调 kanban 动作间接复用它的出站能力。合在一起 GitHub 才像 Miro 一样"双向"。
- **跟 ExternalMirror 域**：建议**不复用**，自带轮询/webhook 进程，跟 kanban 处理 Miro 的做法保持一致。证据：`MiroSync` 的注释明确写它是"**plugin 自有进程，不复用 session 锁死的 external_mirror 域**"（`miro_sync.ex:3-4`）。ExternalMirror 是统一出站（push/pull adapter，绑在 session 上，email 插件用它做出站），它的 KIND 轴是 push/pull 的**出站**抽象，不是为"外部事件入站回灌"设计的。看板节点不是 session-owned 的消息流，硬套 ExternalMirror 会被它的 session 绑定锁死——所以照 Miro 的先例，github 入站也走 plugin 自有进程 + 全程 `Ezagent.Invocation.dispatch/1`（P14：Kind 之间只能走 dispatch）。

### 2.5 取舍（先做什么、风险在哪）

- **先轮询、后 webhook**。轮询不依赖公网回调、本地 e2e 好测（跟 `MiroSync` 同款），先把人工断点拔掉；webhook 实时性更好但要 Phoenix 暴露端点 + 验签 + 公网可达，作为第二步。
- **分支名约定是轮询匹配的命门**。轮询版靠 `head_ref` 把 PR 对回节点，需要 dev-together 的 per-task 分支命名里能编码节点 id（见下面缺失能力 #3）。约定不齐，轮询就匹配不上。
- **幂等**。入站会重复（轮询每 tick 都看到同一个 PR；webhook 会重试）。必须走 ezagent 的幂等原语（`ctx.idempotency_key` + `Idempotency.seen?`，CLAUDE.md "重复 inbound" 条款），否则会重复挂产物 / 重复唤醒接力。
- **不做的取舍**：如果短期不想新增一个 app，**最低成本兜底**是给现有 kanban 加一个 `sync_open_prs` 动作（在 `sync_prs` 旁边），主动 `GET /pulls` 按分支名自动 register。这能拔掉人工断点，但仍是"拉"模式、没有事件驱动 CI 的实时性，且把入站逻辑塞进了出站插件（违背 2.2 的边界理由）。**推荐独立 plugin，兜底方案仅在排期紧张时用。**

---

## 三、其它缺失能力（按优先级）

### P0 — dev-together ↔ kanban 零接线（流程跑不起来的根因）

四路研究里最硬的缺口：**dev-together 这套日常开发流程，跟 kanban 看板之间没有任何代码/文件级接线**，全靠口头约定。

- dev-together 8 个命令的产品输入**只有 `team.md` 花名册**，没有任何 product board 当 work-source（`commands/plan.md:9-31` 只读花名册）。`grep -rl kanban .claude/skills/dev-together` = 空。
- kanban 的两个 skill（kanban-off-ezagent / kanban-on-ezagent）是 dev-together 的 **fork**（各自重写了全部 8 个命令），不是调用方。两 kanban skill 单向 reference dev-together，但 dev-together 不反向指向 kanban——没有一句"若存在产品 board，用 kanban skill 取代本流程"。
- dev-together 的 plan/return/stack 台账**没有 board node id 字段**，所以即使有看板，产物也回指不到节点（kanban skill 给每条加了"board node id"必填，dev-together 缺，见 `commands/return.md:33-44`）。
- dev-together 的 return 机器闸只闸 CI+rebase，**不把进度写回看板节点**（kanban 版会 dispatch `set_status`/`attach_artifact`）。
- `handoff-standard.md` 在 dev-together 和两 kanban skill 里各存一份**拷贝**，不是单一来源。

**要补**：dev-together SKILL 委托链加 kanban 指针；board-node 字段下沉成可选台账列；handoff-standard 抽成单一来源。**这是 P0，因为没有这层接线，"看板驱动开发"只是文档里的话，机器层根本不联动。**

### P1 — feature-point（FP）口径未定义

6-26 的 plan 已经用 FP1–FP6 编号排期，但 **FP 这个计量单位的口径从没正式定义过**（`docs/together/2026-06-26/dev-together-skill-improvement-plan.md` 开放问题①、`plan.html:45`）。约定自 6-27 起在 plan 阶段先正式定义 FP 口径再排期。这直接影响"每天 100+PR 怎么收束到产品价值"的闸（07 接力链第 4 条"只做该功能"）能不能量化。**优先级 P1：不定义，统计和排期都缺一致基准。**

### P1 — 北极星指标的实测回收闭环（⑨→②）没有落库

07 接力链的核心闭环是"PR 上线→实测指标回收→回 ②对照北极星阈值→不达标 drop 砍子树"（`07-定版-自举开发流程-10分钟.md` §二）。现状 kanban 只有 `set_metric`（按 name upsert 一个指标，`kanban.ex:122`）和 `drop_subtree`（砍子树 + 追加到 `tree.drops`，`kanban.ex:130`）这两个**手工**动作。**缺的是自动回收**：没有任何采集器把上线后的真实指标（PostHog / ezagent telemetry / 小红书导出）自动写回对应节点的 metric，也没有"窗口内未达阈值自动建议 drop"的判定。现在 drop 全靠人看数据手工砍。**P1：这是接力链"自举"闭环的另一半，跟 github 入站是同一类"外部世界→ezagent 自动回灌"的缺口。**

### P2 — 跨渠道统一客户身份缺失（`entity://customer` 不存在）

知识库明确："`entity://customer`（客户身份）不存在——fleet 跨渠道统一客户身份缺口持续。"对自举开发流程影响较小（这条更多服务 socialware/客户产品线），但只要流程要把"运营回收的用户行为"对回具体客户，就会撞到这个缺口。**P2：当前 kanban 流程不直接依赖，但 ②验证/运营阶段接真实用户数据时会浮现。**

### P2 — 本仓库没有 CI（红了不会被自动发现）

知识库反复强调"本仓库没有 `.github/workflows`，测试红了靠人工跑"。这跟看板里的"硬 CI 门"（`ci.ex` 的 `ezagent/ci-gate` commit status）是**两件事**：前者是仓库自身的工程 CI（跑 mix test），后者是 kanban 给产品 PR 算的 4 条业务判据。新 github 入站 plugin 若做事件驱动 CI，理应也能顺带触发真正的 `mix test`（而不只是业务判据）。**P2：跟 github plugin 同源，可一并规划，但属于工程基建而非流程本身。**

### P3 — handoff/plan/review 的团队向产物与机器台账未打通

6-26 流程把产物升级成数据驱动 HTML（`plan.html` / `review.html` 读 `stats/cycle-data.json`），并新增 `contributing/` 台账 + `CURRENT_DATE` flag。这些是 dev-together skill 改进 plan 的内容（`dev-together-skill-improvement-plan.md:9-13`），**实现留给 jjkysy**，目前是 PLAN 级草图、未落地。跟 kanban 接线（P0）叠加看：团队向 HTML 统计若要按 feature-point 聚合（plan §3），就需要 FP 口径（P1）+ board-node 字段（P0）都先就位。**P3：依赖 P0/P1 先落地，本身是表现层。**

---

## 附：核实过的关键 file:line 清单

| 结论 | 证据 |
|---|---|
| GitHub 侧纯出站、无 webhook 入站 | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:9` |
| register_pr 的 pr 是手填字符串 | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex:116` |
| 没登记 PR → push_pr 返回 :no_pr_registered | `…/connectors.ex:94-95` |
| sync_prs 只轮询已登记 PR 节点 | `…/connectors.ex:193` |
| register_pr 是 B1 接力动作 | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:702` |
| CI 判据 4 条 + gate_state 映射 | `…/ezagent_plugin_kanban/ci.ex:22` / `:58` |
| Miro 有非破坏性入站（detect_inbound） | `…/ezagent_plugin_kanban/miro/sync.ex:166`、`miro_sync.ex:7` |
| MiroSync 是 plugin 自有进程、不复用 external_mirror 域 | `…/ezagent_plugin_kanban/miro_sync.ex:3-4` |
| dev-together 对 kanban 零感知 | `.claude/skills/dev-together/commands/plan.md:9-31` |
| FP 口径未定义 | `docs/together/2026-06-26/dev-together-skill-improvement-plan.md`（开放问题①）、`plan.html:45` |
| ⑨→②回收闭环（drop 阈值） | `docs/discuss/df-prd/07-定版-自举开发流程-10分钟.md` §二 |
