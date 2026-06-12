# AutoService V2 — 设计实现缺口 & 技术上下文

> 分析日期: 2026-06-12 | 可交付给下一个实施 session
>
> **📋 已整合为实施回顾**: 本文档的缺口分析 + 调试记录 + M2 retro + Phase C 流程退化已统一整合到
> [`docs/superpowers/retros/2026-06-12-autoservice-v2-implementation-retro.md`](superpowers/retros/2026-06-12-autoservice-v2-implementation-retro.md)
> — 包含 prd2impl 流程退化链、M2 NO-GO 裁决、调试问题、技术约束、Lessons Learned。
>
> **⚠️ Core Issues Tracker**: 三个 PR #731 发现的 core 问题 → [`docs/superpowers/retros/core-issues-tracker.md`](superpowers/retros/core-issues-tracker.md)
> — 合并完成后逐项验证，不可遗漏。
>
> 本文档保留作为快速参考。

## 快速导航

- [§1 架构总览](#1-架构总览) — 模块分布和路由
- [§2 待实现的 UI 缺口](#2-待实现的-ui-缺口) — 每个缺口的文件、函数、接入点
- [§3 本会话已修复](#3-本会话已修复) — 已完成的内容
- [§4 关键技术约束](#4-关键技术约束) — 下一个 session 必须知道的坑
- [§5 Lessons Learned](#5-lessons-learned)

---

## 1. 架构总览

```
路由层 (router.ex):
  /autoservice                    → EzagentPluginLiveview.AutoService.CustomerLive
  /autoservice/operator           → EzagentPluginLiveview.AutoService.OperatorLive
  /admin/autoservice              → Master.MasterDashboardLive
  /admin/autoservice/tenants/:tid → Tenant.TenantDashboardLive
  /admin/autoservice/tenants/:tid/operators → Tenant.OperatorsLive
  (soul/skill/kb 编辑路由 未注册)

业务层 (ezagent_plugin_autoservice/lib/):
  customer_session.ex          provision/2 + ensure_joined/1 (种子 + 运行时)
  turn_adapter.ex              open_turn/2, claim_turn/3, compose_turn/3, settle_turn/2
  filler_loop.ex               start/1 (孤儿代码——无处调用)
  chat_ui.ex                   共享组件: message_list/1, composer/1, row/2
  roles.ex                     bundle(:customer|:operator|:admin|:master_admin)
  uris.ex                      纯 URI 推导
  autoservice_assembly.ex       provision_agent/2, preview_provision/3, write_slot/5

UI 层 (ezagent_plugin_liveview/lib/):
  autoservice/customer_live.ex  mount → ensure_joined → chat (直接 chat.send)
  autoservice/operator_live.ex  mount → list_cs_sessions → select → chat + claim/settle
  master/master_dashboard_live.ex  T2A.1 主控面板
  tenant/tenant_onboard_live.ex    新租户 wizard
  tenant/tenant_dashboard_live.ex  租户仪表盘
  tenant/cr_dashboard_live.ex      CR 管理
  tenant/operators_live.ex         客服人员管理
```

---

## 2. 待实现的 UI 缺口

### Gap A: Customer 走完整 Turn 生命周期 ⭐⭐⭐

**当前行为**: `customer_live.ex:handle_event("send")` 直接 dispatch `chat.send`（mode: cast）到 session，跳过了 Turn 状态机。

**设计目标**:
```
客户消息 → Turn.open → fast agent 收到 → FillerLoop 安抚 → 
slow agent compose → Turn.settle → CustomerFeed 推送 → LV 显示
```

**涉及文件**:
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/customer_live.ex`
  - `mount/3`: 已有 `ensure_joined`，正确
  - `handle_event("send", ...)`: 当前 `chat.send` → 改为 `TurnAdapter.open_turn/2`
  - 新增 `handle_info({:turn_settled, ...})`: 接收 Turn settle 通知，更新 UI

**后端已就绪**:
```elixir
# turn_adapter.ex — 可直接调用
TurnAdapter.open_turn(session_uri, %{customer_uri: customer_uri, text: text})
# → dispatches to session?action=turn.open
```

---

### Gap B: FillerLoop 集成 ⭐⭐⭐

**当前行为**: `filler_loop.ex` 完整但为孤儿代码——没有任何地方调用 `FillerLoop.start/1`。

**设计目标**: slow agent 响应超时（如 >5s）后，启动 FillerLoop 周期性向 session 发送安抚消息（"正在为您查询…"），slow agent 回复后取消。

**涉及文件**:
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/filler_loop.ex`
  - `FillerLoop.start(session_uri)` — 启动安抚 Task
  - `FillerLoop.timeout_apology()` — 超时致歉消息
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/customer_live.ex`
  - 在 `handle_event("send")` 中（或 Turn.open 后），启动 `FillerLoop.start(session_uri)`
  - 在收到 agent 回复后，取消 FillerLoop Task

**后端 API**:
```elixir
# filler_loop.ex
# 发送安抚消息的间隔和文案可配置
{:ok, task_pid} = FillerLoop.start(session_uri)
# slow agent 回复后 kill task
Process.exit(task_pid, :kill)
```

---

### Gap C: Soul slot 编辑器 ⭐⭐

**后端已就绪**:
- `SoulStore` (CRUD)
- `SoulRenderer.full_claude_md/3` (渲染 CLAUDE.md)
- `SoulSlotParser` (解析 `{{key}}` 占位符)
- `AutoserviceAssembly.write_slot/5` (写入 slot 值并触发 CR lint)

**需要构建**:
- 新文件: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/soul_editor_live.ex`
- 新路由: `live "/admin/autoservice/tenants/:tid/soul", Tenant.SoulEditorLive`
- UI: 列出所有 slot → 编辑 → 保存 → CR lint 预览

---

### Gap D: Skill 编辑器 ⭐⭐

**后端已就绪**:
- `SkillStore` + `SkillLoader` + `SkillIndexer` (4 层结构: Platform/Tenant/Industry/Framework)

**需要构建**:
- 新文件: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/skill_editor_live.ex`
- 新路由: `live "/admin/autoservice/tenants/:tid/skills", Tenant.SkillEditorLive`
- UI: 4 层 Tab → 每层的 skill 列表 → CRUD

---

### Gap E: KB 管理器 ⭐⭐

**后端已就绪**:
- `KbStore` + `KbRebuilder` + `KbMcpProvider`

**需要构建**:
- 新文件: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/kb_manager_live.ex`
- 新路由: `live "/admin/autoservice/tenants/:tid/kb", Tenant.KbManagerLive`
- UI: URL 导入 → 条目管理 → kb.db 重建按钮 → MCP 配置预览

---

### Gap F: Platform 内容编辑器（V2 计划未实现）

- V2 spec §8.5 规划的 `platform_content_live.ex` 和路由均不存在
- 需要从零构建：`/admin/platform/soul` + `/admin/platform/skills`

### Gap G: Loom customer SPA（决策 D1 推迟）

- 决策推迟到单独分支

---

## 3. 本会话已修复

| 问题 | 根因 | 修复 |
|---|---|---|
| Feishu WsClient 死循环 | `@restart_backoff_ms 5000` 无上限 | 永久错误不重试 + 指数退避 5s→300s |
| Admin URL `&` 被截断 | cmd.exe 把 `&workspace=system` 当命令分隔符 | 改用 `?as=entity://system/user/admin` |
| 输入框/气泡颜色失效 | Tailwind v4 `source(none)` 不生成 `gray-*`，项目全用 `zinc-*` | 5 个组件 41 处 `gray-*` → `zinc-*` |
| Dark mode 对比度问题 | `@source` 缺 `ezagent_plugin_autoservice/lib`，`dark:` 类未生成 | 加 `@source` + dark 变体 |
| Customer 看不到 AI 回复 | 只订阅 `CustomerFeed.topic`，缺 `Chat.session_events_topic` + `_ensure_joined` 没 re-join fast agent | 双订阅 + re-join |
| 消息双条 | `chat_message` handler 无去重 | 消息 ID 去重 |
| 两套 customer_live/operator_live | `43e6c845` 迁移时旧文件未删 | 删除 `ezagent_plugin_autoservice` 中的死代码 |
| Operator 列表为空 | `session://<ws>/cs/<name>` filter 写死 `session://cs/` | 改为 `String.contains?("/cs/")` |
| Slow agent 不回复 | `--with-slow` 是可选的 | `dev_test_start.sh` 默认 `--with-slow` |
| Operator 接管/释放无按钮 | handler 有但 render 无 UI | 加 claim/settle 按钮+状态 |
| DevAutoLogin + 启动脚本 | 每次手动登录 3 个角色 | plug + 脚本一键启动 |

---

## 4. 关键技术约束

### 4.1 Tailwind v4 CSS 生成

```css
/* apps/ezagent_web/assets/css/app.css */
@import "tailwindcss" source(none);
@source "../../../ezagent_plugin_liveview/lib";
@source "../../../ezagent_plugin_autoservice/lib";  /* ← 本会话新增 */
```

- **规则**: `source(none)` 不扫描任何文件，CSS 类靠 `@source` 声明 + daisyUI 主题生成
- **新增 `@source` 目录时必须同步加到这里**，否则新组件的 `zinc-*`/`dark:` 类不会生成
- **颜色规范**: 用 `zinc-*`（项目 convention），不用 `gray-*`（不会生成）
- **Dark mode**: 所有颜色类必须配 `dark:` 变体（如 `bg-white dark:bg-zinc-950`）

### 4.2 URI 格式约定

```elixir
# Uris 模块定义的格式（3-segment canonical）
session://<workspace>/cs/<name>   # ← 注意: <ws> 在前，/cs/ 在后
entity://<ws>/user/<name>
entity://<ws>/agent/curl_fast-<name>
entity://<ws>/agent/cc_slow-<name>

# 错误示例（之前的代码 bug）
session://cs/<name>               # ← 不存在，filter 会失配
```

### 4.3 PubSub 双通道

Customer LV 需要**同时订阅**两个 topic，否则收不到 agent 实时回复：
```elixir
Phoenix.PubSub.subscribe(PubSub, CustomerFeed.topic(session_uri))  # feed 更新
Phoenix.PubSub.subscribe(PubSub, Chat.session_events_topic(session_uri))  # agent 回复
```

### 4.4 `_ensure_joined` 必须 re-join agent

Server 重启后 session Kind rehydrate，join 关系丢失。`_ensure_joined` 必须 re-join fast agent（和 slow agent 如果存在）：
```elixir
# customer_session.ex:_ensure_joined
with :ok <- ensure_session(...),
     :ok <- join(session, customer, ctx),
     :ok <- join(session, fast_uri, ctx),    # ← 必须
     :ok <- maybe_join_slow(session, slow_uri, ctx) do  # ← 必须
```

### 4.5 消息去重

`chat_message` 和 `customer_delivery` 对同一条消息都会触发。任何新 handler 必须按消息 ID 去重：
```elixir
already_shown? = Enum.any?(socket.assigns.messages, &(&1.id == msg.id))
```

### 4.6 代码位置

- **UI 层** (`customer_live.ex`, `operator_live.ex`): 在 `ezagent_plugin_liveview`
- **业务逻辑层** (`customer_session.ex`, `chat_ui.ex`, `turn_adapter.ex`): 在 `ezagent_plugin_autoservice`
- `ezagent_plugin_autoservice` 中**不存在** `customer_live.ex` / `operator_live.ex`（已被删除）
- 路由注册在 `apps/ezagent_web/lib/ezagent_web/router.ex`

### 4.7 登录和测试

- DevAutoLogin plug: dev 环境 `?as=<handle>` 自动登录
- 启动脚本: `bash scripts/dev_test_start.sh` — seed + 启动 + 3 无痕窗口
- `--with-slow` 现在是默认参数

---

## 5. Lessons Learned

### 5.1 不要为测试场景加防护代码

本会话中两次尝试给 `CustomerLive` / `ensure_joined` 加 admin 拦截逻辑，均被拒绝。

**错误模式**: "admin 误入 customer 页面 → 加 guard 拒绝非 customer"

**为什么错**: guard 隐藏了真正的问题，在症状处打补丁。

### 5.2 删除旧文件

重构迁移后务必删除旧文件。`43e6c845` 迁移 LiveView 模块时漏了删，导致两套代码并存一个月。

### 5.3 跨 VM 种子

Seed 脚本在单独 BEAM 中运行，Session/Agent Kind 进程在 seed VM 退出后死亡。Server VM 启动时通过 KindSnapshot + Workspace Loader 重新实例化。
