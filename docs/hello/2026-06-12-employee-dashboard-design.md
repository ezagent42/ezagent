# 员工工作台 Dashboard — 设计整理 + 开发计划

> 状态：Draft v0.1（2026-06-12）
> 分支：`feat/employee-dashboard`（基于 `feat/loom` @ 58504c80）
> 需求源：`docs/hello/product-handbook.md` **Module B · 我是员工（客服 / 运营 / 销售）**
> 性质：实现整理文档，不改 ARCHITECTURE.md；方向性问题（§5）走 Allen review

---

## 1. 需求提炼（手册 Module B → 功能清单）

| 节 | 功能 | 验收要点 |
|---|---|---|
| B.1 | **登录工作台** | 员工（非 admin User）登录后落地到员工 dashboard：① admin 授权给我的渠道列表 ② 我负责的客户群体 ③ 我的业绩看板 |
| B.2 | **加入会话**（三栏工作台） | 左：渠道列表（**SLA 红绿标**）；中：当前会话实时对话；右：AI 同事协作面板。可观察 / 进入任一活跃会话 |
| B.3 | **三模式协作** | **Auto**（AI 独立处理，员工旁观）/ **Copilot**（员工私密建议给 AI，客户不可见）/ **Takeover**（员工直接发消息）。任何时候一键切换 |
| B.4 | **个人业绩 + operator-agent** | 业绩看板（会话数 / 平均时长 / CSAT / 客户类型分布）+ **跟 operator-agent 对话**查业绩、要建议 |
| B.5 | **沙箱陪练** | 模拟客户对话 + 导师 AI 实时点评 + 复盘（新场景上手前练 50 轮） |

手册里员工的登录方式是"邮箱 magic-link / 微信扫码"——magic-link 已有（`/login`），
**微信扫码超出本期范围**（标后置）。

---

## 2. 现状资产盘点（feat/loom @ 58504c80 上能复用什么）

| 资产 | 位置 | 对 Module B 的价值 |
|---|---|---|
| **LiveAuth 双级身份** | `ezagent_web/live_auth.ex`：`:require_entity`（任何登录实体）/ `:require_admin` | 员工 = 非 admin 的 User entity（`entity://<ws>/user/<name>`），`:require_entity` 直接可用，**无需新身份体系** |
| **登录链路** | `/login`（magic-link）+ `/login/credentials`（密码） | B.1 登录开箱即用 |
| **AdminLive（/sessions）** | `ezagent_plugin_liveview/admin_live.ex` + `admin/` 拆出的 SessionContext / SessionEditor / MemberPanel / Compose / ConversationView | **B.2 三栏工作台的 80%**：session 选择器、实时对话流（stream + restream 修复）、成员面板、composer、view switcher 全部现成 |
| **AppShell 统一外壳** | `app_shell.ex`（avatar / 通知 / ⌘K，perspective 机制） | 员工 dashboard 作为新 perspective 挂入 |
| **AdminDashboardLive（/admin）** | `admin_dashboard_live.ex`（KPI 卡片网格模式） | B.4 业绩看板的版式参照 |
| **socialware `Behavior.Turn`** | `ezagent_domain_socialware/behavior/turn.ex`：已有 `mode: :auto / :copilot`、`owner`、`:awaiting_human`、visibility（`:customer_visible` / `:operator_only`） | **B.3 三模式的语义基础**（rebase 后从 main 带入）——但 loom 的会话走 chat 不走 Turn，见 §5 决策点 1 |
| **agent 装配模式** | loom 的 Team / Template Class 模式；cc/codex flavor | B.4 的 operator-agent、B.5 的导师 AI 都可按"一套三件套 + @-only"的 loom 模式造 |
| **MessageStore / audit telemetry** | `ezagent_core` | B.4 业绩指标的原始数据源（会话数 / 响应时长 / 接管次数可算） |

**缺口（要新建）**：SLA 计算与红绿标（无任何现有资产）、员工↔渠道授权模型（"admin
授权给您的渠道"）、业绩聚合查询、operator-agent、沙箱（customer-simulator + 导师 AI）、
CSAT 数据源（无客户评分入口）。

---

## 3. 架构定位（按 P9 "reads what data decides tier ownership"）

- **员工 dashboard LiveView** 读 session / message / identity / channel 数据 →
  归 `ezagent_plugin_liveview`（operator UI 全在此，同层新增 `employee/` 目录 +
  `EmployeeDashboardLive`），**不开新 plugin**
- **业绩聚合**（纯读 MessageStore + audit）→ liveview plugin 内的查询模块起步；
  若膨胀再谈下沉
- **operator-agent / 导师 AI** → 按 loom 三件套模式放
  `ezagent_plugin_loom`（或独立 `ezagent_plugin_workbench`，见 §5 决策点 2）
- **路由**：`live "/workbench", EmployeeDashboardLive`（`:require_entity`，
  admin 也可进——admin 是员工的超集）；不占用 `/dashboard`（语义留给 admin 业绩）

---

## 4. 分期开发计划（5 个 PR，每期独立可验收）

### PR-1 · 员工落地页骨架（B.1）
- `EmployeeDashboardLive`（`/workbench`）+ AppShell 接入 + 路由
- 三块卡片：我的渠道（先列 workspace 内全部渠道，授权过滤留 PR-2）/
  我的活跃会话（复用 `SessionContext.list_sessions_for`）/ 业绩占位卡
- **Gate**：员工身份登录 → 落地 `/workbench` 看到三块；admin 不受影响
- 测试：LV 渲染 + 权限（未登录 redirect、entity 可进）

### PR-2 · socialware 会话装配 + 三栏工作台 + SLA 标（B.2）
- **会话装配先行**：员工工作台接的 demo 会话用 socialware 三件套装配
  （`Behavior.Chat + Turn + Surface`，SessionTemplate seed 方式，参照
  socialware 既有 E2E fixtures）——这是选项 B 的地基
- 左栏：渠道/会话列表 + **SLA 红绿标**（规则 v0：最后一条客户消息距今未被
  回应 >2min 红、>30s 黄、否则绿；turn 处于 `:awaiting_human` 的会话恒黄
  ——扣着 visibility 等员工，就是"需要关注"；阈值进 config）
- 中栏：复用 ConversationView（observe 模式，stream 订阅）+ **turn 状态条**
  （当前 turn 的 status：delegating / aggregating / composing / awaiting_human）
- 右栏：AI 协作面板（MemberPanel 变体：本会话 AI 成员 + 状态）
- 员工↔渠道授权模型 v0：workspace member declaration 上挂 `channels: [...]`
  标注（admin 在 workspace 页配置），dashboard 按它过滤
- **Gate**：两个浏览器（客户 + 员工）E2E——客户发消息开 turn，员工列表
  30s 内变黄、点进可见实时对话 + turn 状态推进

### PR-3 · 三模式协作（B.3，建在 Turn 上）
- 模式 ↔ Turn 映射见 §5 决策 1 的表。UI 状态不另造：**工作台的模式指示
  = 当前 turn 的 `mode`/`owner`/`status` 的投影**
- **Auto**：默认。composer 禁用，turn 不 claim 自动 settle
- **Copilot**：切换 = `turn.claim(by: 员工)`；员工建议经 dispatch 发给
  orchestrator（`:operator_only` 类内容，**不进 customer feed**）；AI 重新
  compose 后员工 `turn.settle` 放行 / 继续改
- **Takeover**：claim 后员工在 composer 直接写最终回复（作为 turn result）
  → `turn.settle`；客户经 settlement/outbox 看到员工内容
- 切回 Auto：settle 或 cancel 当前 turn；他人已 claim 的会话模式切换器禁用
  （`turn.owner` 不是我 → 只读观察）
- **Gate**：E2E——Auto 旁观（客户即时收到 AI 回复）→ 切 Copilot（claim 后
  **客户侧 customer_feed 什么都看不到**，员工建议后 AI 重 compose，settle
  后客户一次性看到改进版）→ 切 Takeover 直接回（客户看到员工内容）。
  红线断言：claim~settle 间隔内 customer feed 零增量

### PR-4 · 业绩 + operator-agent（B.4）
- 业绩聚合查询（per employee）：今日/本周会话数、接管次数、平均首响时长、
  客户类型分布（按渠道/语言粗分）；**CSAT 标"待数据源"占位**
- 业绩卡接 PR-1 占位；operator-agent（loom 三件套模式，@-only，
  prompt 注入业绩查询结果）支持手册 B.4 的对话式问答
- **Gate**：dashboard 数字与 MessageStore 实算一致；@operator-agent
  问"我今天接了几个会话"答案正确

### PR-5 · 沙箱陪练 v0（B.5，可后置）
- 沙箱 = 一个特殊 workspace/session：customer-simulator AI（loom worker 模式
  + 场景 persona prompt）+ 导师 AI（旁观点评，`:operator_only` 类可见性）
- 场景库 v0：3 个内置（日语议价 / 投诉处理 / 大促咨询）
- **Gate**：员工从 dashboard 进沙箱跑完一轮，看到导师复盘

---

## 5. 决策项

1. **三模式建在哪套语义上？——已定（2026-06-12）：选项 B，socialware `Behavior.Turn`**
   工作台直接建在 Turn 状态机上，与 main 方向一致。三模式 ↔ Turn 映射：

   | 工作台模式 | Turn 语义 |
   |---|---|
   | **Auto** | turn 正常走 `open → dispatch → deliver → compose → settle`，员工不 `claim`，纯旁观 |
   | **Copilot** | 员工 `turn.claim(by: 员工URI)` → turn 进 `mode: :copilot / status: :awaiting_human`，**visibility 被扣住**（`hold_visibility`）；员工建议 → AI 重新 compose → 员工 `turn.settle` 放行 |
   | **Takeover** | `turn.claim` 后员工**自己写最终结果**（替代 AI compose 产物）→ `turn.settle`。客户看到的是员工内容 |
   | 切回 Auto | 当前 turn `settle`（放行）或 `cancel`（丢弃），之后新 turn 不再 claim |

   推论（对 PR 计划的影响，已在 §4 更新）：
   - 工作台接的会话必须是 **socialware 装配的 session**（`Behavior.Chat + Turn
     + Surface`），不是 loom chat 会话——PR-2 先做 session 装配，再做 UI
   - **客户侧任何投影只能读 `Socialware.CustomerFeed`**（gated query +
     outbox），员工侧（内部人）可读 MessageStore——红线自动满足：
     claim 后 settle 前客户什么都看不到
   - ⚠️ 本分支的 socialware 是 main@bf9525b2 时点（P1/P2/P2.5/P3/P6 已有，
     **P4 customer SPA #732 / config-evolve #733 不在本分支**）；工作台是
     operator 侧 UI 不依赖 P4，但若要演示客户侧页面需注意此差距
2. operator-agent / 导师 AI 放 `ezagent_plugin_loom` 还是新
   `ezagent_plugin_workbench`？（倾向新 plugin——它们不是 loom 页面生成域的）
3. SLA 阈值与"渠道"粒度（per channel? per session?）的产品定义
4. 后置确认：微信扫码登录、CSAT 评分入口、B.5 是否进本期

---

## 6. 风险

- **feat/loom 自身的 23 个 main 侧 gate 欠账**（见 loom-guide skill 的
  pitfalls.md）：本功能新增代码**不要扩大违规面**——新代码用
  `Ezagent.URI.new!`、不直调 `*Registry`、不加 raw `Home.path()`
- 三模式若选 A 路线，copilot 的"客户不可见"只在 demo 渠道成立，
  ExternalMirror 类渠道需逐一确认过滤点（参照 socialware 红线：
  `:operator_only` 不经任何路径到达客户）
- 手册是产品愿景文档，"客户群体 / CSAT / 微信扫码"等无后端事实——按 §4
  的占位策略推进，不为愿景造假数据
