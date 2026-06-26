# AutoService E2E Scenarios → Ezagent 复现映射

> gagameow · 2026-06-26 · FP2 agent 配置验证（对标原 autoservice）
>
> 源项目：`D:\Work\h2os.cloud\AutoService-dev-a`（Python FastAPI + React SPA）
> 目标项目：ezagent（Elixir/Phoenix + Behavior/Kind/URI 架构）
> 目的：验证地基大改后 agent 配置与运行时行为不回归

---

## §1 AutoService 项目概要

AutoService 是一个 **Python FastAPI 多租户 AI 客服框架**，单 monorepo 服务所有租户。三个核心角色：

| 角色 | 入口 | 认证方式 | 核心能力 |
|---|---|---|---|
| **Customer（客户）** | Web Chat Widget (`/tenant/:tid/chat`) 或 Feishu IM | 无认证（匿名 + sessionStorage `customerId`） | 发消息、收 AI 回复、语音通话、CSAT 评价 |
| **Operator（操作员）** | Operator Console (`/tenant/:tid/operator`) | 密码登录 → `auth_session` cookie | 查看对话列表、加入/接管对话、copilot/takeover 模式、斜杠命令 |
| **Admin（管理员）** | Admin Portal (`/master` / `/tenants/:tid`) | 密码登录（role=admin）| 租户管理、Soul 编辑（章节/技能/KB）、发布流程、CR 变更请求、Dream 引擎、操作员 CRUD |

### 架构分层

```
L1 socialware/     → 框架底座（pool, plugin_loader, session, config, mock_db）
L2 autoservice/    → 业务层（cc_pool, Pipeline V2, CR, KB, CRM, model_router）
   channels/       → 通道适配器（web/FastAPI + feishu/MCP）
L3 plugins/<tid>/  → 租户扩展（soul, skills, KB, 配置覆写）
frontend/apps/     → 3 个 React SPA（customer-chat, operator-console, admin-portal）
```

### 通信协议

- **WebSocket**（主要）：`/ws/customer`、`/ws/operator`、`/ws/admin`
- **帧协议**：`{v, type, id, ts, ref, payload}` JSON envelope
- **HTTP REST**：FastAPI 路由（`/api/*`、`/api/admin/*`）

---

## §2 AutoService 完整 E2E 场景

### A. Customer 端（客户视角）— 12 个场景

#### A1. 客户首次访问
1. 客户打开 `/tenant/acme/chat` → 加载 customer-chat SPA
2. 随机生成 `customerId`（`cust_xxxxxxxx`），存入 sessionStorage
3. WebSocket 连接 `/ws/customer?tenant=acme&source=cust_xxx`
4. 发送 `client_hello` 帧 → 收到 `server_hello`（session_id, brand_name）
5. 显示 ChatFAB（浮动按钮）→ 客户点击打开 ChatModal
6. 自动显示欢迎气泡（Welcome Message，per-tenant 配置）

#### A2. 客户发送文本消息 & 接收 AI 回复
1. 客户输入文本 → 发送 `customer_message` 帧（content, client_msg_id, conversation_id）
2. 后端 Pipeline V2 处理：DeepSeek ack+filler（红）→ KB MCP（蓝）→ cc with skills（绿）
3. 流式推送 `message` 帧（SSE-style via WS）
4. 前端逐字渲染 AI 回复气泡
5. 消息落库（conversation → messages）

#### A3. 客户发送图片附件
1. 客户上传图片 → `POST /api/upload`（multipart）
2. MIME 检测（python-magic），存储到 `.autoservice/sandbox/<tid>/uploads/<conv>/<uuid>.<ext>`
3. 发送 `customer_message` 帧带 `attachments: [{id, type, name, size}]`
4. Agent 接收附件上下文 → 回复

#### A4. 客户语音通话
1. 客户点击语音按钮 → WebSocket `/ws/voice` 连接
2. 前置预热：cc sticky + backend pre-establish + filler pre-synth
3. ASR 语音识别（Doubao）→ 文本
4. Pipeline V2 处理 → TTS 合成 → 音频流推送
5. 支持 DIRECT_TRANSFER 转人工（SIP）

#### A5. CSAT 满意度评价
1. 对话结束后，后端推送 `csat_request` 帧
2. 前端展示星级评分 UI（1-5 星）
3. 客户提交 → 发送 `csat_response` 帧（score, feedback）
4. 分数记录到 conversation.csat_score

#### A6. 客户查看历史消息
1. 客户重新打开页面 → WS 重连（带 `last_seen` cursor）
2. 发送 `history_request` 帧 → 后端 `get_messages()` 推送 `history_snapshot`
3. 前端渲染历史消息列表（带日期分隔符）

#### A7. 多语言切换
1. 客户在 widget 切换语言（en/zh-TW/ja）
2. 前端设置 `?lang=xxx` → 后端 `LANG_CONFIGS` 匹配
3. 系统提示词、欢迎语、CSAT 文案均按语言切换

#### A8. 客户等待队列
1. cc_pool 满负荷时，新消息进入 `turn_queue`
2. 前端显示 "typing..." 动画（placeholder 机制）
3. slot 释放后按 FIFO 处理

#### A9. 客户直接转人工（DIRECT_TRANSFER）
1. Triage 判断需转人工 → 发送 `DIRECT_TRANSFER` 信号
2. 对话 mode 变为 `waiting_human`
3. 操作员侧收到 escalation 通知
4. 操作员接管后，对话 mode 变为 `takeover`

#### A10. 客户通过 General Bot API 接入
1. 第三方系统 `POST /chat/{tenant_id}`（Bearer auth, SSE 响应）
2. 请求体：`{message, customer_id, conversation_id?}`
3. SSE 流式返回 AI 回复
4. 对话自动创建/关联

#### A11. 客户通过 Feishu IM 接入
1. 客户在 Feishu 群聊发送消息
2. Feishu Bot（MCP server）接收 → `channels/feishu/channel.py`
3. 路由到 channel_server → cc_pool → AI 回复
4. AI 回复通过 Feishu Bot 推回群聊

#### A12. 客户访问 public socialware app
1. 客户访问公开链接（无租户上下文）
2. 匿名绑定（AnonUser cookie）→ 只读观察
3. 如配置允许，可以发送消息

---

### B. Operator 端（操作员视角）— 10 个场景

#### B1. 操作员登录
1. 操作员打开 `/tenant/acme/operator` → 加载 operator-console SPA
2. App mount 时 probe `GET /api/auth/operator/me`（检测已有 cookie）
3. 未登录 → 显示 LoginPage（email + password）
4. `POST /api/auth/login`（email, password, tenant_id）→ bcrypt 验证
5. 成功 → 设置 `auth_session` cookie（30天 TTL）→ 跳转 WorkspacePage
6. 失败 → 速率限制（5次/10分钟/IP）

#### B2. 操作员查看对话列表
1. 登录后 → WebSocket 连接 `/ws/operator?tenant=acme`
2. 发送 squad 订阅帧 → `subscribe`（squad_id）
3. `GET /api/conversations/active` → 返回活跃对话列表
4. ConversationFeed 渲染卡片：客户名（脱敏）、squad、状态标签、最后消息预览、相对时间、SLA bar
5. 左侧 IMSidebar 按 squad 过滤，显示未读计数

#### B3. 操作员打开对话（Copilot 模式）
1. 点击对话卡片 → `openCopilot(convId)`
2. 发送 `history_request`（before_sequence=MAX）→ 获取最近 50 条消息
3. 发送 `operator_join` 帧 → 通知 squad
4. CopilotView 渲染消息流：客户气泡 + Agent 气泡 + 内部消息
5. 操作员可见 Agent 的 thinking 过程（SIDE visibility）

#### B4. 操作员接管对话（Takeover）
1. 点击 Hijack 按钮 → 发送 `operator_command /hijack`
2. 对话 mode 从 `auto`/`copilot` 变为 `takeover`
3. TakeoverIndicator 显示倒计时（idle 自动释放）
4. 操作员输入变为 PUBLIC visibility → 直接发给客户
5. 接近超时 → TakeoverWarning banner（"继续" / "释放"）

#### B5. 操作员发送 Copilot 建议
1. 在 copilot 模式下输入 → 发送 `operator_message`（visibility: SIDE）
2. 仅 Agent 可见 → Agent 参考建议后回复客户
3. 客户看不到操作员的 SIDE 消息

#### B6. 操作员使用斜杠命令
1. `/hijack` → 接管对话
2. `/release` → 释放对话回 auto 模式
3. `/resolve` → 标记对话已解决
4. `/abandon` → 放弃对话
5. `/assign <squad_id>` → 转派到其他 squad
6. 所有斜杠命令发送为 `operator_command`（不是 chat message），不产生重复气泡

#### B7. 操作员编辑/删除消息
1. 操作员发送 `edit_request` 帧（msg_id, new_content）
2. 后端更新消息 → 广播 `message_edited` 帧
3. 操作员发送 `delete_request` 帧（msg_id）
4. 后端软删除 → 广播 `event` 帧

#### B8. 操作员查看 SLA 指标
1. 顶部 IMTitlebar 显示 SLA pill（P95 响应时间）
2. 侧边栏 footer 显示今日接管数、CSAT、P95、zchat 状态
3. `GET /api/sla/summary` → 聚合 SLA 数据
4. `GET /api/metrics/takeover-trend` → 接管趋势
5. `GET /api/metrics/operator-leaderboard` → 操作员排行榜

#### B9. 操作员收到 AI Pool 繁忙警告
1. 前端每 3 秒轮询 `GET /api/cc_pool/runtime`
2. cc_pool 使用率 > 阈值 → PoolBusyWarning banner
3. 操作员了解系统压力，调整接管节奏

#### B10. 操作员登出
1. 点击侧边栏 Logout → `POST /auth/operator/logout`
2. 后端吊销 session → 清除 `auth_session` cookie
3. 前端回到 LoginPage

---

### C. Admin 端（管理员视角）— 15 个场景

#### C1. 管理员登录 & 模式识别
1. 管理员打开 `/` → admin-portal SPA 加载
2. V1/V2 路由分发（`/legacy/*` → V1，其余 → V2）
3. `GET /api/session/mode` → 返回 `master` 或 `tenant` 模式
4. `GET /api/auth/operator/me` → 获取 session（role=admin）
5. Master admin → MasterLayout（租户列表 + 平台管理）
6. Tenant admin → TenantLayout（单租户管理）

#### C2. Master 查看租户列表
1. `GET /api/master/tenants` → 所有租户
2. TenantListPage 渲染租户卡片（名称、状态、最后发布版本）
3. 点击进入租户管理 → `/tenants/:tid`

#### C3. 创建新租户（Onboarding Wizard）
1. 点击 "新租户" → `/onboard` → OnboardStartPage
2. 多步向导（`/onboard/:wizid/:step`）：
   - Step 1: 基本信息（名称、行业、语言、时区）
   - Step 2: Soul 配置（customer role → translate role → lead role）
   - Step 3: 通道配置（Feishu / Web / API）
   - Step 4: 操作员创建
   - Step 5: 预览 & 确认
3. 提交 → 创建租户目录结构 + 初始 soul + sandbox

#### C4. 编辑 Soul 章节（Section Editor）
1. 进入 `/tenants/:tid/soul` → SectionBrowser（角色×章节网格）
2. 点击某章节 → `/tenants/:tid/soul/:role/:sid` → SectionEditor
3. 加载模板 + 当前 slots：`GET /api/admin/section/{tid}/{role}/{sid}`（返回 etag）
4. 编辑 slot 值（Markdown/富文本）
5. 保存：`PUT /api/admin/section/{tid}/{role}/{sid}`（需要 `If-Match: etag`）→ 防并发冲突
6. AI 辅助：`POST /api/admin/section/{tid}/{role}/{sid}/ai_propose` → AI 建议

#### C5. 编辑 Skill 技能文件
1. 进入 `/tenants/:tid/skills/:role` → SkillManagerPage（技能网格）
2. 点击技能 → SkillEditor（.md 编辑器）
3. `GET /api/admin/skill/{tid}/{role}/{name}` → 加载
4. `PUT /api/admin/skill/{tid}/{role}/{name}` → 保存
5. AI 辅助：`POST /api/admin/skill/{tid}/{role}/{name}/ai_propose`

#### C6. 管理 KB 知识库
1. 进入 `/tenants/:tid/kb` → KbManagerPage
2. `GET /api/admin/kb/{tid}/sources` → 列出 KB 来源
3. `POST /api/admin/kb/{tid}/ingest_url` → URL 摄取
4. `POST /api/admin/kb/{tid}/ingest_doc` → 文档摄取
5. `DELETE /api/admin/kb/{tid}/sources/{source_id}` → 删除来源

#### C7. 管理 Flow 指令
1. `GET /api/admin/flow/{tid}/{intent}` → 读取 KV flow 块
2. `PUT /api/admin/flow/{tid}/{intent}` → 更新（etag 并发控制）
3. `POST .../enable` / `POST .../disable` → 启停意图

#### C8. CR 变更请求流程
1. AI（Dream）或人工发起 CR → 生成 CR 记录
2. `GET /api/admin/inbox/{tid}` → 查看待处理提案
3. `/tenants/:tid/crs` → CRListPanel（提案列表）
4. `/tenants/:tid/crs/:crid` → CRDetailPanel（diff 预览）
5. `POST /api/admin/inbox/{tid}/{cr_id}/accept` → 接受
6. `POST /api/admin/inbox/{tid}/{cr_id}/reject` → 拒绝（含原因）

#### C9. Sandbox 预览 & 发布
1. 修改后在 `/tenants/:tid/preview` → SandboxPreviewPage 预览
2. `GET /api/admin/sandbox_diff/{tid}` → 查看所有未发布变更
3. `POST /api/tenants/{tenant_id}/publish` → 6 步发布流水线：
   - check_publish_gate（合规 + rehearsal + soul 完整性 + KB>=50）
   - build_publish_archive（打包 .tar.gz）
   - write_publish_record（写 JSON）
   - write_runbook（生成 README）
   - freeze_sandbox（标记状态）
   - archive_sandbox（移动到归档目录）
4. 发布后 recycle cc_pool → 新配置生效

#### C10. 版本管理 & 回滚
1. `GET /api/tenants/{tenant_id}/versions` → 发布历史
2. `/tenants/:tid/versions` → VersionTimeline UI
3. `POST /api/tenants/{tenant_id}/rollback` → 回滚到上一版本

#### C11. 测试控制台（干运行）
1. 进入 `/tenants/:tid/soul/test` → TestConsole
2. `POST /api/admin/test/{tid}/{role}` → 发送测试消息
3. 返回：分类结果 + KB 预取 + 完整提示词预览（不实际调用 LLM）
4. 用于验证 soul 配置是否正确

#### C12. 管理操作员
1. 进入 `/tenants/:tid/operators` → TenantOperatorsPage
2. CRUD：`GET/POST/PATCH/DELETE /admin/{tenant_id}/operators`
3. 创建操作员 → 发送邀请链接（magic link）
4. 密码重置（admin-initiated）→ 设置 `password_must_reset=1`
5. 禁用操作员 → 吊销所有 session

#### C13. Dream 引擎管理
1. Master: `/master/dream` → MasterDreamPanel
2. Tenant: `/tenants/:tid/dream` → TenantDreamPage
3. `POST /api/dream/trigger` → 触发 Dream run
4. `GET /api/dream/status` → 查看状态
5. `GET /api/dream/runs` → 历史运行记录
6. Dream 自动分析 soul 质量 + 生成改进建议（CR 提案）

#### C14. Billing & 仪表盘
1. `GET /api/billing/invoices` → 账单
2. `GET /api/sla/summary` → SLA 聚合
3. `/tenants/:tid/dashboard` → DashboardV2（仅 master）
4. `/tenants/:tid/billing` → BillingV2（仅 master）

#### C15. Master Soul 层级编辑
1. L1 平台 Soul：`/master/soul/platform` → `GET/PUT /api/admin/master/platform/{role}`
2. L2 行业 Soul：`/master/soul/industry` → `GET/PUT /api/admin/master/industry/{industry}/{role}`
3. L3 模板：`/master/soul/templates` → `GET/PUT /api/admin/master/templates/{role}/{sid}`
4. Priority 配置：`/master/soul/priority` → `GET/PUT /api/admin/master/priority`

---

## §3 Ezagent 能力映射

### 3.1 核心概念对应

| AutoService | Ezagent | 匹配度 |
|---|---|---|
| Customer（匿名客户） | `anon_user` (cookie) + `customer_feed` (socialware) | 🟡 部分 |
| Operator（操作员） | `entity://<ws>/user/<name>` + session member | 🟢 存在 |
| Admin（管理员） | `entity://system/user/admin` (bootstrap) + workspace admin | 🟢 存在 |
| Agent（AI agent） | `entity://<ws>/agent/<name>` (cc/codex/curl/py) | 🟢 存在 |
| Conversation/Session | `session://<tpl>/<ws>/<name>` + routing rules | 🟢 存在 |
| Tenant/Workspace | `workspace://<name>` + per-workspace caps | 🟢 存在 |
| Soul/Skill/KB | SessionTemplate + Behavior 配置 | 🟡 不同模型 |
| Pipeline V2 | Routing rules + Behavior dispatch chain | 🟡 不同模型 |
| cc_pool | Agent flavor (cc/codex) + agent bridge | 🟢 存在 |
| Feishu Channel | `ezagent_plugin_feishu` | 🟢 存在 |
| OpenAI API | `ezagent_plugin_protocol_api` (`/v1/chat/completions`) | 🟢 存在 |
| Web Widget | `public_view` session + `customer_feed` + React SPA | 🟡 部分 |

### 3.2 关键差异

| 维度 | AutoService | Ezagent |
|---|---|---|
| **语言/框架** | Python FastAPI | Elixir Phoenix |
| **通信协议** | 自定义 WS envelope 协议 | Phoenix Channels + MCP |
| **配置模型** | Soul 4-layer（L0-L3）+ Skill + KB + Flow | SessionTemplate + Behavior 配置 + Role+Flavor |
| **Operator 模型** | 专门的 operator 角色 + takeover/copilot 模式 | Session member + CapBAC 权限 |
| **Admin UI** | React SPA（V1 legacy + V2 new） | World LiveView（React+LV hybrid） |
| **发布流程** | 6-step pipeline（sandbox → archive） | 无对应概念（配置即代码） |
| **CR 变更请求** | Dream → CR → Inbox → Accept/Reject | 无对应概念 |
| **Triage/路由** | FastClassifier + ModelRouter | Routing rules + `always()` matcher |

---

## §4 场景逐条复现分析

### 图例
- ✅ **可直接复现** — ezagent 有对应能力，配置即可
- 🔧 **需要配置/适配** — ezagent 有基础能力，需要额外配置或小幅开发
- 🚧 **需要开发** — ezagent 缺失该能力，需要实现
- ❌ **不适用** — 概念模型不同，不应直接复现

---

### A. Customer 端复现分析

| # | 场景 | 状态 | 复现方案 / 缺失项 |
|---|---|---|---|
| A1 | 客户首次访问 | 🔧 | `public_view` session + `customer_feed` 已有。需要：配置 public session template + 前端 widget 嵌入 |
| A2 | 发送消息 & AI 回复 | ✅ | Session.send → routing → agent.receive → reply。核心闭环已通 |
| A3 | 图片附件 | 🔧 | 消息可带 attachment metadata。需要：upload endpoint + 文件存储（ezagent 当前无） |
| A4 | 语音通话 | ❌ | ezagent 无 ASR/TTS/voice channel。AutoService 依赖 Doubao 外部服务 |
| A5 | CSAT 评价 | 🔧 | Session 可发自定义 action frame。需要：CSAT behavior + UI 组件 |
| A6 | 历史消息 | ✅ | MessageStore + snapshot 已存在。session replay 已实现 |
| A7 | 多语言 | 🔧 | Behavior 配置可带 locale。需要：i18n 模板渲染 |
| A8 | 等待队列 | 🔧 | 消息队列天然存在（dispatch 异步）。需要：typing indicator + placeholder 机制 |
| A9 | 转人工 | 🔧 | Session.turn mode 切换已存在。需要：escalation 通知 + operator 接管 UI |
| A10 | General Bot API | ✅ | `ezagent_plugin_protocol_api` 提供 OpenAI 兼容 `/v1/chat/completions` |
| A11 | Feishu IM | ✅ | `ezagent_plugin_feishu` 已实现 webhook + inbound dispatch |
| A12 | Public socialware | 🔧 | `public_view` session 已存在。需要：匿名访问 UI |

### B. Operator 端复现分析

| # | 场景 | 状态 | 复现方案 / 缺失项 |
|---|---|---|---|
| B1 | 操作员登录 | ✅ | SessionController + Identity 已实现密码登录 + magic link |
| B2 | 查看对话列表 | 🔧 | Session 列表已存在。需要：operator 专用 session 过滤 + squad 概念映射 |
| B3 | 打开对话（Copilot） | 🔧 | Session.join + history replay 已存在。需要：copilot 模式（SIDE visibility） |
| B4 | 接管对话（Takeover） | 🔧 | Session.turn mode 切换 + CapBAC。需要：takeover UI + 倒计时 |
| B5 | Copilot 建议 | 🔧 | operator_message（SIDE visibility）需要实现。消息已有 visibility 字段 |
| B6 | 斜杠命令 | ✅ | operator_command → Behavior action dispatch 天然支持 |
| B7 | 编辑/删除消息 | 🔧 | 消息编辑/软删除需要实现（当前 MessageStore 不可变?） |
| B8 | SLA 指标 | ❌ | ezagent 无 SLA/分析模块 |
| B9 | Pool 繁忙警告 | 🔧 | cc_pool capacity 可暴露。需要：前端轮询 + UI banner |
| B10 | 登出 | ✅ | Session 吊销 + cookie 清除已实现 |

### C. Admin 端复现分析

| # | 场景 | 状态 | 复现方案 / 缺失项 |
|---|---|---|---|
| C1 | 管理员登录 | ✅ | admin bootstrap user + workspace admin 角色已存在 |
| C2 | 租户列表 | ✅ | workspace:// 列表 + World UI 已有 |
| C3 | 创建租户（Wizard） | 🔧 | Workspace 创建已存在。需要：wizard UI + 初始模板生成 |
| C4 | 编辑 Soul 章节 | 🔧 | SessionTemplate 配置编辑。需要：section editor UI + etag 并发控制 |
| C5 | 编辑 Skill | 🔧 | Agent 配置编辑。需要：skill .md editor UI |
| C6 | KB 管理 | ❌ | ezagent 无 KB 概念（AutoService 有向量搜索 + 摄取管道） |
| C7 | Flow 指令 | 🔧 | Routing rules 可表达 flow。但概念模型不同：AutoService 是 intent→KV block，ezagent 是 dispatch rules |
| C8 | CR 变更请求 | ❌ | ezagent 无 CR/Dream 概念（AutoService 有完整的提案→审查→接受/拒绝流程） |
| C9 | Sandbox 预览 & 发布 | ❌ | ezagent 无 sandbox/publish 概念（配置直接生效，无预览→发布流程） |
| C10 | 版本管理 & 回滚 | 🔧 | 无版本概念。可通过 git tag + 配置快照实现 |
| C11 | 测试控制台 | 🔧 | 可构建 test session 发送消息验证。需要：干运行 UI |
| C12 | 管理操作员 | ✅ | User CRUD + invite 已实现 |
| C13 | Dream 引擎 | ❌ | ezagent 无自动分析/改进建议引擎 |
| C14 | Billing & 仪表盘 | ❌ | ezagent 无 billing/分析模块 |
| C15 | Master Soul 层级编辑 | 🔧 | SessionTemplate 层级已存在。但 4-layer（L0-L3）概念需要适配 |

---

## §5 可在 Ezagent 复现的流程（优先级排序）

### 🟢 Tier 1 — 核心闭环（可直接验证，匹配 handoff 三条流程）

#### 流程 1：API 同步（OpenAI 兼容端点）
```
第三方 HTTP Client → POST /v1/chat/completions
  → ezagent_plugin_protocol_api (OpenaiChatPlug)
  → dispatch 到 py_default agent
  → agent.receive → handle → reply
  → 流式返回 SSE response
```
- **覆盖场景**：A10（General Bot API）
- **ezagent 状态**：✅ 已实现
- **验证方法**：codex 作 HTTP 客户端发送请求，验证往返
- **依赖**：`py_default` agent 已正确配置且运行中

#### 流程 2：Feishu 同步（双向）
```
Feishu 用户发消息 → webhook → ezagent_plugin_feishu
  → inbound dispatch → session.send
  → routing → agent.receive → reply
  → outbound → Feishu Bot 推回消息
```
- **覆盖场景**：A11（Feishu IM）
- **ezagent 状态**：✅ 已实现
- **验证方法**：Feishu 群聊发送消息，验证 agent 回复
- **依赖**：Feishu app 配置 + webhook URL + agent 配置

#### 流程 3：原流程重跑（Session 内 agent 交互）
```
创建 session → 加入 agent + user
  → user 发送消息 → dispatch 到 agent
  → agent 处理 → reply → 消息落库
  → user 查看历史 → session replay
```
- **覆盖场景**：A1, A2, A6, B1, B3
- **ezagent 状态**：✅ 核心已实现
- **验证方法**：创建 session，发送消息，验证 agent 回复 + 历史
- **依赖**：workspace + agent 配置 + session template

### 🟡 Tier 2 — 需要配置/小幅适配

#### 流程 4：Operator Copilot → Takeover 闭环
- **覆盖场景**：B2-B6
- **需要**：operator session 模板 + copilot/takeover mode + visibility 控制
- **预估工作量**：配置为主，可能需要 1-2 个小 Behavior 实现

#### 流程 5：Admin 配置 Agent（Soul/Skill 编辑）
- **覆盖场景**：C3-C7
- **需要**：World UI 中 agent 配置面板（已在 feat/agent-console 分支开发中）
- **预估工作量**：UI 适配为主

#### 流程 6：Public Socialware App（匿名客户访问）
- **覆盖场景**：A1, A12
- **需要**：配置 public_view session template + 前端嵌入
- **预估工作量**：配置 + 前端

### 🔴 Tier 3 — 缺失，需要开发

| 功能 | AutoService 场景 | 缺失原因 |
|---|---|---|
| KB 知识库（向量搜索 + 摄取） | C6 | ezagent 无 KB 子系统 |
| CR 变更请求 + Dream 引擎 | C8, C13 | 概念模型不同（AutoService 的 AI 自我改进闭环） |
| Sandbox → Publish 发布流程 | C9 | ezagent 配置即代码，无预览→发布流程 |
| Billing & 仪表盘 | C14 | 非 ezagent 核心关注点 |
| 语音通话（ASR/TTS） | A4 | 依赖外部 Doubao 服务 |
| SLA 分析 | B8 | 无分析模块 |
| CSAT 评价 | A5 | 需要开发 |

---

## §6 复现依赖清单

### 6.1 环境依赖

| 依赖 | 用途 | 状态 |
|---|---|---|
| Elixir 1.19 + OTP 27 | ezagent 运行时 | ✅ 已安装 |
| Phoenix 1.8 | Web 层 | ✅ 已安装 |
| Docker（ disposable stack） | 隔离测试环境 | 🔧 需确认 |
| Feishu App（bot 凭证） | Feishu 通道测试 | 🔧 需配置 |
| codex CLI | API HTTP 客户端测试 | 🔧 需确认 |
| Node.js + pnpm | 前端（World UI） | 🔧 需确认 |

### 6.2 Ezagent 内配置依赖

| 配置项 | 对应 AutoService | 设置方法 |
|---|---|---|
| Workspace | Tenant | `POST /api/workspaces` 或 World UI 创建 |
| Agent (py_default) | cc agent | World UI Agent 配置页 |
| Session Template | Soul/Skill 配置 | World UI Session 模板 |
| Feishu webhook URL | Feishu channel | ezagent_plugin_feishu 配置 |
| API keys (protocol_api) | General Bot API key | `.env` 或 World UI |
| User (operator) | Operator account | 注册/邀请流程 |
| Routing rules | Flow 指令 | Session 内 routing 配置 |

### 6.3 数据依赖

| 数据 | 来源 | 用途 |
|---|---|---|
| autoservice soul 内容 | AutoService `.autoservice/sandbox/<tid>/` | 参考 agent 配置 |
| autoservice skill 文件 | AutoService `plugins/<tid>/skills/` | 参考 skill 定义 |
| autoservice KB chunks | AutoService `.autoservice/database/` | 参考 KB 结构 |
| 测试用 Feishu 群 | Feishu 后台 | Feishu E2E |
| 测试用 API key | 生成 | API E2E |

---

## §7 总结：Ezagent 对 AutoService 的覆盖度

```
整体覆盖度：~55-60%

核心消息闭环：     ████████████████████ 95%
Agent 配置/路由：   ██████████████████░░ 85%
Operator 工作台：   ████████████░░░░░░░░ 60%
Admin 管理面板：    ██████████░░░░░░░░░░ 50%
KB/知识管理：      ░░░░░░░░░░░░░░░░░░░░  0%
分析/仪表盘：      ░░░░░░░░░░░░░░░░░░░░  0%
CI/CD 发布流程：   ░░░░░░░░░░░░░░░░░░░░  0%
```

### 核心结论

1. **ezagent 可以复现 AutoService 的核心消息闭环**：消息入站 → 路由分发 → agent 处理 → 回复。这是 handoff 要求的三条流程（API/Feishu/流程重跑）的基础。
2. **ezagent 的架构更通用但更底层**：AutoService 是垂直的客服 SaaS，ezagent 是水平的 agent 编排平台。AutoService 的很多"功能"在 ezagent 里是"配置组合"，而非内置功能。
3. **最大缺口在运营面**：KB 管理、CR 提案、发布流程、分析仪表盘——这些是 AutoService 作为 SaaS 产品的功能，不是 agent 运行时的能力。验证 agent 配置不回归不需要这些。
4. **本次验证应聚焦 Tier 1 三条流程**，它们直接验证 agent 配置（domain.agent）+ 运行时行为（路由→回复）在地基大改后是否回归。

---

## §8 下一步行动

1. **确认 ezagent 当前可运行** — `mix phx.server` 启动 + World UI 可访问
2. **确认 py_default agent 存在且配置正确** — World UI 查看 agent 列表
3. **配置 Feishu webhook** — 连接测试 Feishu 群
4. **逐条跑 Tier 1 三条流程** — API → Feishu → Session 内交互
5. **记录证据** — 截图 + 请求/响应日志
6. **发现的回归开 issue**

---

*生成时间：2026-06-26 | 源项目分析深度：文件级（主要入口 + 关键路由 + 前端结构）*
