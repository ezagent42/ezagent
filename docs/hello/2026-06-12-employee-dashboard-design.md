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
| **loom orchestrator 编排闭环** | `ezagent_plugin_loom/behavior/loom_orchestrator.ex`：in-flight turn map、mention-gated、ref_id 回执、dead-worker 兜底；WebPlug 入站默认 @ orchestrator | **B.3 三模式的宿主**（§5 决策 1 v2）：`:coach`/`:standby`/`collab_mode` 都作为它的 plugin action/slice 扩展 |
| socialware `Behavior.Turn`（参照系） | `ezagent_domain_socialware/behavior/turn.ex` | **不在本期使用**（评审证实状态机不支持本需求，见 §5 决策历史）；仅作 `mode/owner` 字段命名对齐的参照 + 迁移目标。注：visibility（`:customer_visible/:operator_only`）实际属 core `Ezagent.Message`，Turn 只是调用方 |
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
- `EmployeeDashboardLive`（`/workbench`）+ AppShell 接入 + 路由；AppShell 加
  per-perspective 开关隐藏 ⌘K（`:require_entity` 链固定 assign
  `cmdk_nav_routes`，需要小改）
- 三块卡片：我的渠道（先列 workspace 内全部渠道，授权过滤留 PR-2）/
  我的活跃会话（复用 `SessionContext.list_sessions_for`）/ 业绩占位卡
- **B.1②"您负责的客户群体"的承接**（评审 H5）：不单独设卡——由
  A3 活跃会话（按渠道/客户聚合视图）+ 页面 C 的客户类型分布共同承接，
  本期在 A3 卡头加"我的客户"计数占位
- **Gate**：员工身份登录 → 落地 `/workbench` 看到三块；admin 不受影响
- 测试：LV 渲染 + 权限（未登录 redirect、entity 可进）

### PR-2 · 三栏工作台 + SLA 标（B.2，会话即 loom 会话）
- **会话装配零成本**：工作台直接接 `session.loom` 模板实例化的会话
  （loom 团队 + 客户 tmp_user 全现成），无需新装配
- 左栏：渠道/会话列表 + **SLA 红绿标**（规则 v0：最后一条客户消息距今未被
  回应 >2min 红、>30s 黄、否则绿；阈值进 config，5s tick 刷新）+ 会话处于
  Copilot/Takeover 时显示 **owner 徽标**（"您" / "王五"）
- 中栏：复用 ConversationView（observe 模式，stream 订阅）+ **编排状态条**
  （orchestrator 当前在飞回合：拆解中 / 等 worker（N/M 已回）/ 组合中——
  读 orchestrator `:loom` slice 的 in-flight turn map；claude_code 后端下
  叠加 `loom:gen_progress` 流式进度）
- 右栏：AI 协作面板（MemberPanel 变体：本会话 AI 成员 + 状态）
- 员工↔渠道授权模型 v0：**需要 schema/存储变更**——workspace 成员目前是纯
  URI 列表（`member_uris`），无 per-member metadata 槽。本期加
  per-member `channels: [...]` 存储（migration 注意不变式：per-tenant 表带
  `workspace_uri NOT NULL`）+ admin 在 workspace 页的配置 UI
- **Gate**：两个浏览器 E2E——客户开 loom 页发消息，员工工作台列表 30s 内
  变黄、点进可见实时对话 + 编排状态条推进（loom 页面就是客户入口，
  双浏览器即可执行）

### PR-3 · 三模式协作（B.3，loom 旁路方案——映射与铁律见 §5 决策 1）
- orchestrator Behavior 新增 plugin actions：`:coach`（收员工建议进 slice，
  下轮 compose 注入）/ `:standby` / `:resume`（Takeover 进出）/
  `:set_collab_mode`（slice 记 `collab_mode` + `owner`，action 内校验
  caller==owner——互斥做实）
- UI 模式指示 = orchestrator slice 的 `collab_mode/owner` 投影（不另造状态）
- **Auto**：composer 禁用。**Copilot**：composer 发 `:coach` dispatch（不进
  session）。**Takeover**：orchestrator standby + 员工 `chat.send` 直接回复
- 建议历史 + 模式切换记录：旁路存储（仿 stitch_chat）+ audit telemetry，
  **不写 session 消息**
- **Gate**：双浏览器 E2E——Auto 旁观（客户即时收到 AI 回复）→ 切 Copilot
  发建议（**客户 loom 页 / `/stream` / 飞书镜像三处均不可见**，AI 下轮回复
  体现建议）→ 切 Takeover 直接回（AI 不抢答，客户看到员工消息）→ 切回
  Auto（AI 恢复应答）。**不变式测试**：coach 内容在 MessageStore 中零记录

### PR-4 · 业绩 + operator-agent（B.4）
- 业绩聚合查询（per employee），**各指标数据通路明确**（评审 M6）：
  - 会话数 / 平均时长 / 客户类型分布（渠道×语言）→ MessageStore 实算
  - 平均首响 → 客户消息↔首条回应配对查询（MessageStore，按 session 扫描，
    v0 接受全表扫 + 限定时间窗，量大再谈索引/物化）
  - **接管次数 → PR-3 的模式切换旁路存储 + audit telemetry**（不在
    MessageStore 里，gate 据此分开验证）
  - CSAT 标"待数据源"占位
- 业绩卡接 PR-1 占位；operator-agent（loom 三件套模式，@-only，
  prompt 注入业绩查询结果）支持手册 B.4 的对话式问答
- **Gate**：会话数/首响与 MessageStore 实算一致；接管次数与切换记录一致；
  @operator-agent 问"我今天接了几个会话"答案正确

### PR-5 · 沙箱陪练 v0（B.5，可后置）
- 沙箱 = 一个特殊 workspace/session：customer-simulator AI（loom worker 模式
  + 场景 persona prompt）+ 导师 AI（点评走旁路通道——同 PR-3 coach 模式，
  不进 session 消息流，只在员工陪练 UI 显示）
- 场景库 v0：3 个内置（日语议价 / 投诉处理 / 大促咨询）
- **Gate**：员工从 dashboard 进沙箱跑完一轮，看到导师复盘

---

## 5. 决策项

1. **三模式建在哪套语义上？——已定（2026-06-12 v2）：loom 插件通讯方式 + Turn 命名对齐**

   > 决策历史：v1 曾定为 socialware `Behavior.Turn`（选项 B）；subagent 评审
   > （2026-06-12）发现该映射 5 行中 4 行与 turn.ex 真实状态机冲突（claim 仅
   > `:composing` 窗口合法、`:awaiting_human` 无 recompose 路径、无 human-result
   > action、无 `:takeover` mode），且全仓库无 Turn 驱动者、ExternalMirror 无
   > visibility 过滤——成立需改 socialware domain spec（Allen 范畴）。
   > **v2 改为在 loom 现有机制上实现**，理由：loom orchestrator 是现成驱动者
   > （WebPlug 入站默认 @ `loomorch_<sid>`）、loom 页面就是客户入口（E2E gate
   > 可执行）、无状态机窗口限制（"任何时候一键切换"成立）。

   三模式 ↔ loom 机制映射：

   | 工作台模式 | loom 实现 |
   |---|---|
   | **Auto** | 现状即是：客户消息 → orchestrator 拆解/fan-out/聚合/回复，员工纯旁观 |
   | **Copilot** | 员工建议经 **dispatch 直达 orchestrator 的新 plugin action `:coach`**，存进 `:loom` slice，下一轮 compose 注入 prompt。**建议完全不进 session 消息流**（铁律，见下） |
   | **Takeover** | ① 员工切换时 orchestrator 进 `:standby`（新 action：暂不应答客户消息）② 员工 `chat.send` 直接回复（不 @ 任何 AI → mention-gated 路由只投 User 成员，AI 不抢答；客户经渠道/页面正常看到） |
   | 模式状态 | 存 orchestrator slice：`collab_mode`（`:auto/:copilot/:takeover`）+ `owner`（员工 URI）。**字段命名与 socialware Turn 的 mode/owner 对齐**，为迁移留直通道。action 内校验 caller==owner（互斥做实，不只靠 UI） |

   **铁律——Copilot 私密性走旁路**：loom 的 `/stream` SSE 是
   `MessageStore.recent_in_session` + session 事件订阅（routing-blind 全量），
   飞书镜像同样全量——**任何写进 session 消息流的内容客户都看得到**。因此
   Copilot 建议、模式切换系统提示一律不落 MessageStore：建议走 `:coach`
   action 进 slice，员工 UI 的建议历史与切换记录走旁路存储（仿 stitch_chat
   模式）+ audit telemetry。PR-3 必须带不变式测试：coach 内容不出现在
   MessageStore / `/stream` / 飞书镜像。

   接受的代价（明示）：
   - **无"批准前客户看不到"的审批语义**——Auto/Copilot 下 AI 回复即时可见。
     这与手册 B.3 原文一致（"客户看到的还是 AI 同事，但答得更好"），不是缺陷；
     但与 socialware SW-USE 的 hold-visibility 是两种产品行为，**迁移到
     socialware 时三模式需在 Turn 上重做**（迁移债，记入 loom-guide
     migration-map 的补判清单）
   - `:coach` / `:standby` / `collab_mode` 是 loom 插件（orchestrator Behavior）
     的改动——新代码不得扩大 feat/loom 既有 gate 违规面（URI canonical、
     不直调 `*Registry`、无 raw `Home.path()`）
2. operator-agent / 导师 AI 放 `ezagent_plugin_loom` 还是新
   `ezagent_plugin_workbench`？（倾向新 plugin——它们不是 loom 页面生成域的）
3. SLA 阈值与"渠道"粒度（per channel? per session?）的产品定义
4. 后置确认：微信扫码登录、CSAT 评分入口、B.5 是否进本期

---

## 6. 风险

- **feat/loom 自身的 23 个 main 侧 gate 欠账**（清单见 PR #722 的 loom-guide
  skill `references/pitfalls.md`；feat/loom 本体的 loom-developer skill 没有
  这份清单）：本功能新增代码**不要扩大违规面**——新代码用
  `Ezagent.URI.new!`、不直调 `*Registry`、不加 raw `Home.path()`
- **Copilot 私密性是本设计最大安全面**：loom 的 `/stream` SSE 与飞书镜像都是
  routing-blind 全量——私密性**不靠过滤、靠"根本不进 session 消息流"**
  （§5 决策 1 铁律 + PR-3 不变式测试）。后续任何人把建议/系统提示"顺手"
  写成 session 消息 = 立即泄漏，这是要在 code review 里盯死的模式
- 手册是产品愿景文档，"客户群体 / CSAT / 微信扫码"等无后端事实——按 §4
  的占位策略推进，不为愿景造假数据
