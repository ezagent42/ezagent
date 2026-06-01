# 场景 26：Codex bridge UDS WS thread 连续性（PR #441 回归）

**类别**：14 — Codex bridge
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-28（PR #441 Allen 签收）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Bridge sidecar `app-server` 运行，UDS WS 在 `${EZAGENT_HOME}/sockets/codex-bridge.sock`
- Codex agent 注册 + 连接（场景 06）
- Codex TUI 在 tmux（以便观察 session 崩溃 + 重启）

## 角色

- **调用方**：codex TUI + ezagent bridge sidecar
- **目标**：跨重连的共享 `thread_id` 一致性

## 步骤

### 建立 thread

1. 启动 codex TUI；观察 bridge 日志连接建立。
2. 在 `/admin/sessions/<session-uri>` 给 codex agent 发消息。
3. Bridge JSON-RPC over UDS WS 携带本轮；codex CLI 返回；bridge 写回同一 WS。
4. 记下 bridge 日志中打印的 `thread_id`。

### 崩溃 + 重连（PR #441 回归测试）

5. 杀 codex TUI（其 tmux pane 中 `Ctrl+C` 两次）。
6. 从**同**`claude_config_dir` 重启 codex TUI。
7. Codex CLI 重连到 bridge UDS WS；bridge 识别 `thread_id`。
8. 在 session 发新消息；验证 codex 响应时知晓前轮（thread 状态连续 — PR #437）。
9. 验证握手中途 UDS WS **不**丢帧不乱序（PR #441 特定修复）。

### Bridge 侧重连

10. 杀 bridge sidecar；重启。
11. Codex TUI 重连（自动重试）；thread_id 重新协商；对话继续。

### Smoke 脚本

12. 跑 `scripts/codex_app_server_thread_repro.py` — 演练 JSON-RPC 握手 + thread 重用。
13. 跑 `scripts/codex_bridge_thread_smoke.py` — 演练 bridge 上的完整 chat 轮。

## 预期结果

- `thread_id` 跨 TUI 重启 + bridge 重启一致（PR #437 + #441）。
- UDS WS 处理部分帧 + 重连无状态丢失。
- 每种重启变体后完整 `chat.send → codex turn → 回复` 循环都工作。

## 失败模式

- UDS socket 文件被移除：bridge 重新 bind；socket 重新出现时 codex TUI 重连。
- Socket 路径权限问题：bridge 无法 bind；操作员日志可见错误。
- 两个 codex TUI 同时连：bridge 各自分配 `thread_id`（独立 thread）。
- 握手**期间**到达的 `chat.receive`：PR #441 缓冲 + 握手后派发。

## 交叉引用

- 相关 PR：
  - PR #437 — fix(codex)：在 bridge thread 恢复 TUI
  - PR #439 — fix(codex)：解阻操作员 e2e bootstrap
  - PR #441 — fix(codex)：使用 app-server UDS websocket
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
- 测试：
  - `apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_bridge_test.exs`（相关 cc 侧；与 codex 正交但演练 bridge 原语）
  - `apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_e2e_test.exs`
- Smoke 脚本（操作员驱动）：
  - `scripts/codex_app_server_thread_repro.py`
  - `scripts/codex_bridge_thread_smoke.py`

## 备注

- PR #441 是规范的 "UDS WS 帧处理" 教训。JSON-RPC over WS over UDS 有 3 层帧；纠正它们花了 2 次迭代。
- 按 `feedback_study_mature_projects_first`，bridge 设计借鉴成熟 WebSocket app-server 模式（LiveView Phoenix.Socket、Hotwire stream socket）。
- 两个 smoke 脚本特意操作员可跑（无需 `mix test`），按 `feedback_codex_companion_no_mix`。
