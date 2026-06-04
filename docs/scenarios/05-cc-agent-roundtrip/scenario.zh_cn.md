# 场景 05：cc agent — spawn → 首启 → 消息 → 回复

**类别**：2 — Agent 生命周期
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-22（V1 签收 + 持续 PR 回归）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- `claude` CLI 在 PATH（真实 Anthropic TUI）— `claude --version` 成功
- `uv` 在 PATH（用 PEP-723 inline metadata 跑 MCP bridge）
- 已认证的 `claude` — 见 `docs/runbook/cc-agent-e2e.md` 凭据复制章节
- Admin 已登录
- Sandbox 凭据已 seed：`mix ezagent.demo.seed_cc_sandbox --name my-cc-agent --seed-template my-cc-agent`

## 角色

- **调用方**：admin（`entity://user/system/admin`）
- **目标**：cc agent `entity://agent/system/my_cc_agent`（Kind：`Ezagent.Entity.CcAgent`）
- **外部系统**：spawn 的 `claude` TUI 二进制；cc-bridge Phoenix Channel `ws://127.0.0.1:10042/cc_socket/websocket`

## 步骤

### Spawn

1. 在 `/admin/templates` 点 "Create cc.agent template"；填 working_directory、claude_config_dir、default_caps；提交。
2. 导航到 `/admin/agents`（TODO — 当前 404，用 iex 替代 — 见场景 29）。
3. iex 等价：
   ```elixir
   {:ok, _} = Ezagent.Workspace.add_template(
     URI.new!("workspace://system"),
     "my-cc-agent",
     %{"class" => "cc.agent",
       "agent_uri" => "entity://agent/system/my_cc_agent",
       "cwd" => "/tmp/my-cc-cwd",
       "claude_config_dir" => "/tmp/my-cc-claude-dir"})
   ```
4. cc Template Class spawn agent；PTY 用 `CLAUDE_CONFIG_DIR=/tmp/my-cc-claude-dir` 启动 `claude`。

### 首启

5. 观察 `/admin/agents/<url-encoded-agent-uri>/terminal`（LV PTY 镜像）。
6. 首启显示 TUI theme picker；ezagent PTY handler 盲打 `<Enter>`（PR #390 状态机：boot → first-run → ready）。
7. 确认 LV terminal 显示 theme 后的 `claude` REPL 提示符。

### 消息 + 回复

8. 在 `/admin/sessions/<session-uri>` 发消息："say hello in one sentence"。
9. 链路：
   - admin → `chat.send` → Session 扇出
   - Agent `chat.receive` → `BridgeRegistry.lookup`（live claude 已加入 `/cc_socket`）
   - `to_claude` 推送到 Phoenix Channel
   - claude MCP stdio 的 `notifications/claude/channel`
   - claude 的 LLM 读 channel + 调 `reply` MCP 工具
   - `reply` 事件经 WS 回 → agent 派发 `chat.send`
   - Session events 流收到回复
10. Admin 在 `/admin/sessions/<session-uri>` LV 看到回复。

### 重启

11. iex：`Ezagent.Kind.Runtime.dispatch(<cc_agent_uri>, :restart, %{})`。
12. Agent supervisor 重启；PTY 重启；孤儿回收（PR #385 + #388）确保旧 `claude` 进程经 pid-file lookup 被杀。
13. 验证重启后 agent 拾取同一 `claude_config_dir` + workspace 状态。

## 预期结果

- 写 `invocations` 行：spawn、chat.send（admin）、chat.receive（agent）、chat.send（agent 回复）。
- `kind_snapshots` 行的 cc agent 在 `:on_change`（或 `:on_terminate`，按 Decision #115）更新。
- PTY pid-file 在 `<config_dir>/pids/claude.pid` 于 ready 状态存在，terminate 时清理。
- `/admin/sessions/<session-uri>` LV 显示 admin 消息 + agent 回复。

## 失败模式

- `claude` 不在 PATH：spawn 失败 `:enoent`；supervisor 日志 + 重试上限 3 次。
- 过期凭据（sandbox `.credentials.json` 缺失）：claude 提示登录 + PTY 在 prompt 卡死（"首启前凭据复制" 失败模式）。
- Bridge socket 在回复中途断开：cc agent 的 MCP server 检测 `notifications/claude/channel` socket close + 经 `BridgeRegistry.register/2` 重新注册。
- LLM API 限流：claude 返回错误 tool 响应；reply MCP 工具用错误文本发 `chat.send`；admin 在 session 看到错误。

## 交叉引用

- 相关 PR：
  - PR #385 — pty-orphan-restart 修复（post_init hook + orphan reapers）
  - PR #388 — pid-file 替代 `ps`-walk 孤儿发现
  - PR #389 — api-key 从 User flip 到 Agent Kind
  - PR #390 — PTY/Python phase 状态机 + LV 可见性
  - PR #424 — agent_bridge PR-B：TokenStore + Registry 从 cc 提升
  - PR #428 — agent_bridge PR-C：Socket + Channel 提升
  - PR #432 — agent_bridge PR-E：移除 domain_instance_message cc 依赖
  - PR #436 — agent_bridge PR-G：加 codex plugin（cc 的正交验证点）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
  - `docs/superpowers/specs/2026-05-27-agent-bridge-domain-extraction.md`
- 测试：
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — 确定性 CI e2e（FakeCcAgent stand-in）
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/real_claude_hotfixes_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/dev_channels_confirm_test.exs`
- 证据 + runbook：
  - `docs/runbook/cc-agent-e2e.md`（Test B — 操作员驱动的真 claude smoke）
  - `docs/runbook/cc-agent-config.md` — 操作员配置旋钮

## 备注

- 确定性 CI e2e 用 `FakeCcAgent` 留在 umbrella 测试 wall-clock 预算内；runbook 覆盖真二进制 smoke。
- 按 `feedback_open_terminal_first_when_debugging`，任何 cc-agent 调试 session **首先**打开 `/admin/agents/<uri>/terminal`。
- Bug A（config_dir 原子化） — 见场景 27 — 是首启幂等性的 open gap。
