# 场景 06：codex agent — spawn → bridge → 回复

**类别**：2 — Agent 生命周期
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-28（PR #441 UDS WS 修复 Allen 已验证）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- `codex` CLI 在 PATH（OpenAI codex TUI）
- `codex` 已对 provider（OpenAI / Azure / etc.）认证
- Bridge sidecar `app-server` 监听 UDS socket — 通常由 `mix ezagent.bootstrap` 在 PR #436 后启动
- Admin 已登录

## 角色

- **调用方**：admin（`entity://user/system/admin`）
- **目标**：codex agent `entity://agent/system/my_codex`（Kind：`Ezagent.Entity.CodexAgent`，经 PR #436）
- **外部系统**：codex TUI 二进制；bridge_sidecar JSON-RPC over UDS WebSocket

## 步骤

1. 经 `/admin/templates` 或 iex 创建 codex.agent 模板（类比场景 05 cc.agent）。
2. Spawn codex agent。
3. 观察 bridge sidecar 日志：
   - Codex TUI 连 UDS WS `${EZAGENT_HOME}/sockets/codex-bridge.sock`
   - JSON-RPC 握手建立 `thread_id`
4. 在 `/admin/sessions/<session-uri>` 发消息："write a haiku about Erlang"。
5. 验证路由：
   - `chat.send` → Session 扇出
   - codex agent `chat.receive` → bridge 写一轮到 UDS WS
   - codex CLI 摄入 + LLM 响应
   - bridge 用**同一** `thread_id` 经同一 UDS WS 写回响应
   - codex agent 派发 `chat.send`（回复）
6. Admin 在 session LV 看到回复。

## 预期结果

- TUI + bridge 共享 `thread_id`（PR #437 fix）。可读 codex 的 bridge thread log 验证。
- `invocations` 行：spawn + chat.send + chat.receive + chat.send（回复）。
- UDS WS 不丢帧不乱序（PR #441 fix）。

## 失败模式

- Bridge sidecar 未运行：codex agent spawn 失败 `:bridge_unavailable`。
- Codex CLI 中途退出：bridge 检测 EOF；codex agent 转 `:degraded`；supervisor 退避重启。
- 过期 `thread_id`（codex TUI 重启但 bridge 以为还有 thread）：smoke 脚本 `codex_app_server_thread_repro.py` 是规范回归。
- LLM API key 无效：codex CLI 报错；bridge 把错误作为 chat 消息浮到 session。

## 交叉引用

- 相关 PR：
  - PR #421 — SPEC：AgentBridge domain 提取（PR-A）
  - PR #424 — PR-B TokenStore + Registry
  - PR #428 — PR-C Socket + Channel
  - PR #429 — PR-D Agent chat 走 BridgeAdapter
  - PR #432 — PR-E 移除 domain_instance_message cc 依赖
  - PR #425 — PR-F 按 behavior 检测 PTY 生命周期
  - PR #436 — PR-G 加 codex agent plugin
  - PR #437 — TUI bridge thread 恢复
  - PR #439 — 操作员 e2e bootstrap 解阻
  - PR #441 — fix：app-server UDS WebSocket 帧处理
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
  - `docs/agent-bridge-pr-b-tokenstore-registry.md` 到 `docs/agent-bridge-pr-g-codex-plugin.md`
- 测试：
  - `apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_domain_agent_bridge/test/...`（PR-A 脚手架）
- Smoke 脚本：
  - `scripts/codex_app_server_thread_repro.py` — bridge UDS WS 回归
  - `scripts/codex_bridge_thread_smoke.py` — thread 连续性

## 备注

- Bridge 架构与 cc 共享（`Ezagent.Domain.AgentBridge`），使 cc-codex 成为并行 flavor 对。
- 按 `feedback_north_star_plugin_isolation`，cc 和 codex 必须把 bridge 当黑盒消费；bridge 不嵌 cc 或 codex 特定逻辑。
- ⚠️ 状态由于今天对真 codex 二进制无自动化 e2e（操作员驱动经 `codex_app_server_thread_repro.py`）。（曾被设想为 codex-v2 前置的场景 04「跨 workspace 委派 token」已于 2026-06-14 删除（YAGNI）；若 codex-v2 将来需要跨 workspace acting-as 派发，从全新 SPEC 起步。）
