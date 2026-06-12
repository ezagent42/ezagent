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

### PR-2 · 三栏工作台 + SLA 标（B.2）
- 左栏：渠道/会话列表 + **SLA 红绿标**（规则 v0：最后一条客户消息距今未被
  AI/员工回复 >2min 红、>30s 黄、否则绿；阈值进 config）
- 中栏：复用 ConversationView（observe 模式，stream 订阅）
- 右栏：AI 协作面板（MemberPanel 变体：本会话 AI 成员 + 状态）
- 员工↔渠道授权模型 v0：workspace member declaration 上挂 `channels: [...]`
  标注（admin 在 workspace 页配置），dashboard 按它过滤
- **Gate**：两个浏览器（客户 + 员工）E2E——客户发消息，员工列表 30s 内变黄、
  点进可见实时对话

### PR-3 · 三模式协作 MVP（B.3，最大的一期）
- 会话级 `collab_mode` 状态（per employee×session）：`:auto`（默认，纯观察）
  / `:copilot` / `:takeover`，工作台一键切换
- **Takeover**：员工经 composer 直接 `chat.send`（已有能力，UI 上标明
  "您正在直接回复"）
- **Copilot**：员工建议以**员工→AI 私聊**实现——v0 用 mention-gated 私发
  （消息只 @ 目标 AI，客户渠道镜像按 visibility 过滤不出去）；
  AI 收到建议后修正下一条回复
- ⚠️ 依赖 §5 决策点 1（visibility 机制选型）——决策前本期只先落
  observe/takeover 两态
- **Gate**：E2E——Auto 观察 → 切 Copilot 发建议（客户侧渠道不可见）→
  切 Takeover 直接回（客户可见）

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

## 5. 待决策项（动 PR-3 前必须定）

1. **三模式建在哪套语义上？**（最大方向性问题）
   - 选项 A：在 loom/chat 的 mention-gated 体系上做简化 copilot（私发 + 渠道
     镜像过滤）——快，但**与 main 的 socialware Turn/visibility 是两套**，
     迁移时重做
   - 选项 B：把员工工作台直接建在 socialware `Behavior.Turn` 上（rebase 后
     本分支已有 turn.ex）——与 main 方向一致（SW-USE 不变式原生支持
     copilot/takeover + `:operator_only` 永不达客户），但 loom 会话要接 Turn，
     工作量大
   - **倾向 B 的语义 + A 的节奏**：PR-3 v0 用 A 落 demo，数据结构按 Turn 的
     `mode/owner/visibility` 命名对齐，给迁移留直通道。**需 Allen 拍板**
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
