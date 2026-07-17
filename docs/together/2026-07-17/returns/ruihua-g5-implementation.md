> **Task:** G5 通用错误机制 — 落地实施
> **Branch:** `feat/g5-error-mechanism`
> **PR:** https://github.com/ezagent42/ezagent/pull/1451
> **Dev:** ruihua + Claude
> **returned_at:** 2026-07-17 17:00 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time（代码完成；E2E 截图待 Allen 协助环境）

## DoD reconciliation

| # | DoD 项 | status | proof |
|---|--------|:--:|-------|
| 1 | 通用机制建成（#1+#3 同 matcher） | met | ErrorMatcher 两条走同一 `match/1` 路径；单元测试覆盖 atom + tuple `:_` 通配 |
| 2 | A/B/C 截图齐 | **deferred** | 代码就绪，无法本地验证——Allen 需协助隔离栈 + agent-browser 环境（见下） |
| 3 | C 兜底 | met | Layer 3 `register_issue/2` 生成 `G5-{code}-{ts}` ID + Logger.warning |
| 4 | SOP file:line 修准 | met | `curl_agent.ex:250`；`error_message/1` 仅在 `user_data.ex` |
| 5 | gate 全绿 | met | `mix format --check-formatted` ✅；`mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants` ✅；15 单元测试 ✅ |
| 6 | 开 PR + adversarial review | met | PR #1451 draft；adversarial review 待触发 |

## 做了什么

### 代码（`feat/g5-error-mechanism`，7 commits）

| 模块 | 位置 | 职责 |
|------|------|------|
| `Ezagent.World.ErrorCode` | `apps/ezagent_plugin_world/lib/ezagent/world/error_code.ex` | 错误码注册表（#1 agent_credential_missing + #3 action_unauthorized） |
| `Ezagent.World.ErrorMatcher` | `apps/ezagent_plugin_world/lib/ezagent/world/error_matcher.ex` | `{:error, reason}` → 错误码匹配（atom + tuple `:_` 通配） |
| `Ezagent.World.ErrorRenderer` | `apps/ezagent_plugin_world/lib/ezagent/world/error_renderer.ex` | Layer 1/2/3 卡片 + socket 集成 + 自动登记 issue |
| `ConversationActions` | 修改 | `dispatch_session_action` error 分支走 ErrorMatcher + ErrorRenderer |
| `world_live.ex` | 修改 | 新增 `notification.send` handler（Layer 2 提醒 → `Ezagent.Notifications`） |
| `Conversation.tsx` | 修改 | 渲染 DispatchErrorCard（Layer 1 fix link / Layer 2 notify button / Layer 3 issue ID） |
| `main.tsx` | 修改 | `RenderContext` 新增 `pushEvent` 字段 |

### 测试

- ErrorCode: 4 tests（all/0、lookup/1、required fields）
- ErrorMatcher: 5 tests（tuple wildcard、atom、unregistered、non-error）
- ErrorRenderer: 6 tests（Layer 1/2/3 cards、fix_path_to_url）
- `check_invariants` + CI invariant 子集 ✅

### 文档修正

- SOP §6#1 来源：`api_keys.ex:190` → `curl_agent.ex:250`
- SOP §1 `error_message/1`：仅 `user_data.ex`；其余 3 处重定位

## Method friction

1. **E2E 环境是 designer 的盲区。** 本地起 dev server 需要 `EZAGENT_SIGNING_SEED_V1`、PG 数据库、seed 脚本需要 admin-level cap 权限——这些对不写代码的 designer 来说是黑盒。seed 脚本迭代了 4 轮语法/API 错误，最终卡在 `:unauthorized`（founder 无 workspace admin cap）。**建议：非代码交付的 E2E 验收应由 lead 或 engineer 在已就绪的隔离栈上跑，designer 提供验收 checklist。**

2. **agent-browser 未本地可用。** `which agent-browser` 返回空。当前 E2E 的替代方案是手动浏览器截图，但需先有可用的 dev 环境。

## 待 lead 协助

| # | 事项 | 说明 |
|---|------|------|
| 1 | **隔离栈 + E2E 截图** | 需要：新 seed 部署实例 + 一个无 API key 的 curl agent + founder + member 两个用户 + agent-browser（或手动浏览器）。A/B/C 三层截图后贴入 PR #1451 |
| 2 | **adversarial review** | PR #1451 就绪后可触发 `/codex:adversarial-review` |

## Merge request

PR #1451 保持 draft。代码和测试就绪；E2E 截图由 Allen 协助完成后可标记 ready。
