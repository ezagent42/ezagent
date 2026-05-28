# 场景 27：Per-agent api-key + 沙箱隔离

**类别**：15 — 资源管理
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-26（PR #389 + #390；Bug A "config_dir 原子化" 推迟）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 同 workspace 中两个 agent：cc agent A1 + curl agent A2
- A1 的 `claude_config_dir` 设为 `/tmp/A1-claude-dir`
- A2 持有 DeepSeek api-key
- Admin 已登录

## 角色

- **调用方**：admin + agent 本身（运行时）
- **目标**：
  - cc agent 沙箱化的 `.claude/` 目录
  - curl agent 的 api-key slice（PR #389 后在 Agent Kind 上）
- **Behavior**：`Ezagent.Behavior.ApiKeys`（按 PR #389）在 Agent Kind 上

## 步骤

### 沙箱隔离（cc）

1. Shell：`ls /tmp/A1-claude-dir/` — 观察 `.credentials.json`、`settings.json`、`mcp_servers.json`、`pids/`。
2. 从 `/admin/sessions/<sess>` 发消息给 A1；验证 A1 响应时用**其** config_dir 的凭据（**非**主机 `~/.claude/`）。
3. 同 phx 中，spawn 第二个 cc agent A1b，`claude_config_dir = /tmp/A1b-claude-dir`（不同）。
4. 验证 A1 和 A1b 独立运作 — session 历史、MCP 缓存、凭据无交叉污染。

### API-key 隔离（curl）

5. 在 `/admin/agents/<A2-uri>/api-keys` 观察 mask 的 DeepSeek key。
6. 尝试从**其他** agent 的 slice 读 A2 的 api-key（经 `Ezagent.Kind.Runtime.dispatch(<other_agent_uri>, :get_api_key, %{...})`）：调用方缺 cap 则期望 `:unauthorized`。
7. 验证 api-key 在任何日志或 session 消息中**永不**出现。

### Config_dir 原子化（Bug A — 推迟）

8. 用指向**不**存在路径的 `claude_config_dir` spawn cc agent。
9. Bug A：今天 cc Template Class **非**原子地创建目录 + 写配置文件。若 agent setup 中途重启，部分状态残留。
10. 预期修复：原子创建-填充（Phase 2 PR 8 按 SPEC #445 §3.3 把这些提升为 `resource://` URI）。

## 预期结果

- 每个 cc agent 的 `.claude/` 隔离（沙箱）。
- api-key per-agent（PR #389 后），仅经 cap-gated `:get_api_key` action 可读。
- 日志 / 审计 / session 中无 key 泄漏。

## 失败模式

- `claude_config_dir` 无法创建（权限拒绝）：cc agent spawn 失败；supervisor 记日志。
- agent 中途调用时 api-key 被撤销：下次派发失败；飞行中调用用缓存 key。
- 两个 agent 共享 `claude_config_dir`（操作员配错）：互相损坏 session 历史 + 凭据。缓解：`docs/runbook/cc-agent-config.md` 文档警告；应作为配置时验证。

## 交叉引用

- 相关 PR：
  - PR #389 — refactor(api_keys)：ApiKeys Behavior 从 User Kind flip 到 Agent Kind
  - PR #390 — PTY/Python phase 状态机
  - PR #385 — orphan reaper
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §3.3 — Resource 模式（Phase 2 PR 8 把 config_dir + api-key 提升为 `resource://` URI）
- 测试：
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
- Open bug / gap（todo 条目）：
  - **Bug A**：config_dir 原子化 — 推迟到 Phase 2 SPEC #445 §3.3 Resource 模式。
  - **日志 / 审计中 api-key 不泄漏的不变式测试不存在**。值得加 property 测试。

## 备注

- 按 `feedback_north_star_plugin_isolation`，Resource（config_dir、api-key、binding、cap-grant）在 SPEC #445 设计中是一等 URI — 但 Phase 1（PR #451）仅发布 Router/Behavior/Kind 原语；Phase 2 改造 Resource。
- 今天的沙箱隔离是 "按约定"（每个 agent 的 config_dir 是不同路径）；更严格的强制（如 cgroups、namespace）不在 scope。
