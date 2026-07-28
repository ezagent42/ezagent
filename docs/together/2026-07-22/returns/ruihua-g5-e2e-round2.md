> **Task:** G5 错误机制 E2E 实证（第 2 轮）
> **Branch:** `main`（已从 `feat/g5-error-mechanism` rebase）
> **Dev:** ruihua + Claude
> **returned_at:** 2026-07-22 10:00 +0800
> **deadline:** 2026-07-22
> **deadline_status:** blocked（跨 BEAM cap 下发未解决，G5 错误卡片未能触发）

## DoD reconciliation

| # | DoD 项 | status | proof |
|---|--------|:--:|-------|
| 1 | 隔离 E2E 环境搭建 | met | `EZAGENT_HOME=/tmp/ezagent_g5_e2e`，Postgres 55432，server :10042 |
| 2 | 种子脚本完善 | met | 用户 + agent(无 API key) + session + caps，`g5_e2e_seed.exs` |
| 3 | Playwright 自动化 | met | `scripts/g5-e2e-playwright.js`，登录→session→输入→发送 全流程 |
| 4 | `already_registered` 修复 | met | `layout_bootstrap.ex` 补 `{:already_registered, _} → :ok` pattern |
| 5 | rebase 到最新 main | met | `e0d07be17`，含 #1451/#1456 全部 G5 代码 |
| 6 | A/B/C 截图 | **blocked** | 消息在 `session.send` 被 `:missing_cap` 拒绝，未到 agent |

## 第 2 轮 vs 第 1 轮（07-17）的进展

| 方面 | 07-17 第 1 轮 | 07-22 第 2 轮 |
|------|-------------|-------------|
| 环境 | 本地 dev，依赖 PAT_PEPPER_V1 + Vite | 隔离 `EZAGENT_HOME`，独立 DB，可复现 |
| 种子 | 手动 IEx + SQL 修 7 个 infra 坑 | 一个 `mix run` 脚本完成全部初始化 |
| 测试 | 手动浏览器 | Playwright 自动化（9 轮截图） |
| UI 流程 | 卡"创建中"（LiveView push_patch 丢失） | 登录 ✅ session 加载 ✅ 消息输入 ✅ |
| 消息发送 | 被 `send` cap 拦截 | 同样 `:missing_cap`——跨 BEAM cap 下发是根本原因 |
| 代码基底 | `feat/g5-error-mechanism`（落后 main） | 最新 `main`（含 #1451 #1456） |

## 核心卡点：跨 BEAM cap 下发

### 现象

```
[error] Kind.Server: fire-and-forget cast dispatch FAILED
reason=:missing_cap
target=session.send session://system/default/g5-e2e-test
```

### 根因

种子脚本运行在 `mix run` BEAM，服务器运行在 `mix phx.server` BEAM。两个 BEAM 各自维护独立的 `kind_cap_authorities` key store。种子发的 cap 签名用 `mix run` BEAM 的 key，`mix phx.server` BEAM 验证时找不到对应 key → `:missing_cap`。

### 已尝试方案

- 种子中通过 `Cap.issue({:admin, admin}, founder, cap)` 发 cap → 签名不跨 BEAM
- 种子后再通过 `mix run -e` 单独补 cap → 同样不跨 BEAM
- 在 `phx.server` 同一 BEAM 内操作 → 需要 IEx 或 API dispatch，未尝试（种子依赖完整的 Elixir 模块加载）

### 需要 lead 裁定

1. 跨 BEAM cap 下发的标准做法是什么？（种子 → 运行中 server 的 cap 如何被识别）
2. 或者接受当前 Playwright 截图作为 UI 流程实证，G5 错误卡片的效果用单元测试覆盖？

## Playwright 截图

9 张截图在 `scripts/g5-screenshots/`：
- `01-login-page` → `02-sessions` → `03-pre-send` → `04-message-typed` → `05-after-send`
- UI 全链路通过（登录、session 加载、消息输入框可见、发送按钮可用）
- `05-after-send` 显示消息发送后的页面（消息在后端被拒，前端可能无反馈）

## 附带修复

| 修复 | 文件 | 说明 |
|------|------|------|
| `already_registered` race | `apps/ezagent_plugin_world/lib/ezagent/world/layout_bootstrap.ex` | `ensure_system_workspace_runtime` 补 `{:already_registered, _} → :ok` |
| `Ezagent.Cap.authorization_context` | `g5_e2e_seed.exs` | `{:genesis, _}` → `{:admin, _}`（API 变更） |

## 产物

| 文件 | 路径 |
|------|------|
| 种子脚本 | `apps/ezagent_plugin_world/assets/scripts/g5_e2e_seed.exs` |
| Playwright 脚本 | `scripts/g5-e2e-playwright.js` |
| 截图 | `scripts/g5-screenshots/` (9 张) |
| 服务器日志 | `/tmp/g5-server.log` |
