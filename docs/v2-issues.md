# AutoService V2 — 已实现功能 vs UI 缺口分析

> 分析日期: 2026-06-12

## 1. 架构概览

```
ezagent_plugin_autoservice/   ← 业务逻辑层（后端）
  customer_session.ex          provision + ensure_joined
  turn_adapter.ex              open/claim/compose/settle 完整实现
  filler_loop.ex               Task 安抚消息循环（孤儿代码）
  roles.ex                     4 角色 cap bundle
  uris.ex                      URI 推导
  chat_ui.ex                   共享 UI 组件
  autoservice_assembly.ex      预览/slot 编辑器

ezagent_plugin_liveview/       ← UI 层（路由到此）
  autoservice/customer_live.ex   /autoservice
  autoservice/operator_live.ex   /autoservice/operator
  master/master_dashboard_live.ex /admin/autoservice
  tenant/tenant_dashboard_live.ex
  tenant/tenant_onboard_live.ex
  tenant/cr_dashboard_live.ex
  tenant/operators_live.ex
```

## 2. 有后端代码但 UI 无入口

### 2.1 Operator 接管/释放按钮（缺失）⭐⭐⭐

**后端**: `TurnAdapter.claim_turn/3` + `settle_turn/2` 完整实现，负责 operator 接管会话 → 禁用 routing rule → 人工回复 → 释放后恢复 rule。

**现有 UI**: `operator_live.ex` 有 `handle_event("claim", ...)` 和 `handle_event("settle", ...)` 两个事件处理器，代码完整。但 `render/1` 中**没有对应的按钮**。operator 能发消息（composer），但无法触发接管/释放流程。

**缺口**: render 函数缺少:
- 消息列表中的"接管"按钮（每条消息附带 turn_id）
- 接管状态指示
- "释放/结束人工对话"按钮

### 2.2 FillerLoop 安抚消息（孤儿代码）⭐⭐⭐

**后端**: `filler_loop.ex` 完整——在 slow agent 等待期间周期性发送"正在为您查询…"安抚消息。

**现有 UI**: 无。没有任何 LiveView 或 session 生命周期调用 `FillerLoop.start/1`。

**缺口**: 需要在 slow agent 响应超时后启动 FillerLoop Task，并在 slow agent 回复后取消。

### 2.3 Customer 消息未走 Turn 生命周期 ⭐⭐

**设计**: 客户消息 → `Turn.open` → fast agent ACK → slow agent compose → `Turn.settle` → feed 推送。

**实际**: `customer_live.ex` 直接 dispatch `chat.send` 到 session，跳过了 Turn 状态机。

### 2.4 Soul slot 编辑器（无 UI）⭐⭐

**后端**: `SoulStore` + `SoulRenderer` + `SoulSlotParser` 完整实现。`Assembly.write_slot/5` 提供 slot 写入入口。

**现有 UI**: 无。路由也未注册。

### 2.5 Skill 编辑器（无 UI）⭐⭐

**后端**: `SkillStore` + `SkillLoader` + `SkillIndexer` 完整实现。

**现有 UI**: 无。路由也未注册。

### 2.6 KB 管理器（无 UI）⭐⭐

**后端**: `KbStore` + `KbRebuilder` + `KbMcpProvider` 完整实现。

**现有 UI**: 无。路由也未注册。

## 3. V2 计划但未实现的功能

### 3.1 Platform 内容编辑器

V2 spec §8.5 列的 `platform_content_live.ex`（`/admin/platform/soul` + `/admin/platform/skills`）未构建。

### 3.2 Loom (customer SPA)

决策 D1 推迟到单独分支，当前用 `CustomerLive` (Phoenix LiveView) 做验证。

### 3.3 路由缺失

| 路由 | 状态 |
|---|---|
| `/admin/tenants/:tid/soul` | 未注册 |
| `/admin/tenants/:tid/skills` | 未注册 |
| `/admin/tenants/:tid/kb` | 未注册 |

## 4. 优先修复顺序

1. **Operator claim/settle 按钮** — handler 已有，只需在 render 加 UI
2. **FillerLoop 集成** — 在 session 生命周期中启动/停止
3. **Customer Turn 生命周期** — 改造 customer_live 的消息发送路径
4. **Soul/Skill/KB 编辑器** — 需从零构建 UI

## 5. 本会话已修复的问题

| 问题 | 提交 | 文件 |
|---|---|---|
| Feishu WsClient 死循环重试 | `4067c39d` | `ws_client.ex` |
| Admin URL `&` 被 cmd.exe 截断 | `2edf339a` | `dev_test_start.sh` |
| CSS `gray-*` 全部替换为 `zinc-*` | `76fabc9f` | 5 个组件文件 |
| Dark mode 类未生成（`@source` 缺目录） | `b3f4617c` | `app.css` |
| Customer 看不到 AI 回复 | `6009d112` | `customer_live.ex` ×2 |
| 消息双条 | `9978c241` | `customer_live.ex` |
| 两套死代码 `customer_live/operator_live` | `6f9adf12` | 删除 2 个文件 |
| `list_cs_sessions` filter `session://cs/` 失配 | `3c8b4231` | `operator_live.ex` ×2 |
| `_ensure_joined` 没 re-join fast agent | `3c8b4231` | `customer_session.ex` |
| Slow agent 未默认启用 | `b3f4617c` | `dev_test_start.sh` |
| 输入框文字看不清 | `2edf339a` | `chat_ui.ex` |

## 6. Lessons Learned

### 6.1 不要为测试场景加防护代码

本会话中两次尝试给 `CustomerLive` / `ensure_joined` 加 admin/非 customer 拦截逻辑，均被拒绝。

**错误模式**: "admin 误入 customer 页面 → 加 guard 拒绝非 customer"

**为什么错**: guard 隐藏了真正的问题（admin 为何到达了不该去的页面），在症状处打补丁。正确的做法是修正数据流/浏览器重连机制。

**记录**: 详见 `docs/debugging/admin-session-leak.md`
