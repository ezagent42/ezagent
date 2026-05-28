# 场景 18：PTY 首启 theme 对话框处理

**类别**：7 — PTY 交互
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-26（PR #385 + PR #390 phase 状态机合并）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- `claude` CLI 已安装（**尚未**认证 — 本场景复现全新安装的运行）
- 全新 `claude_config_dir`（例如 `/tmp/fresh-cc-dir-$(date +%s)`）— **未** seed
- Admin 已登录

## 角色

- **调用方**：admin
- **目标**：使用全新 config_dir 的 cc agent
- **外部系统**：`claude` TUI（首启 theme picker）

## 步骤

1. 创建 cc.agent 模板，`claude_config_dir = /tmp/fresh-cc-dir-XXX`。
2. Spawn cc agent。
3. 打开 `/admin/agents/<url-encoded-agent-uri>/terminal`。
4. PTY 显示 `claude` 首启 theme picker：列 theme 的 TUI 菜单。
5. PR #390 状态机：agent 转 `boot → first-run`。
6. PTY handler 盲打 `<Enter>` 接受默认 theme。
7. Agent 转 `first-run → ready`。
8. LV terminal 显示 theme 后的 `claude` REPL 提示符。

## 预期结果

- 首启 phase **无需**操作员干预即完成。
- Agent 在约 10 秒内（热缓存更快）到达 `:ready`。
- 发出 telemetry `[:ezagent, :pty, :first_run_dismissed]`。
- `kind_snapshots` 行更新反映 `:ready` phase。
- **同一** agent（同 config_dir）后续 spawn 跳过首启，因为 theme 已持久化到 `claude_config_dir/themes.json`。

## 失败模式

- `claude_config_dir` 只读：`claude` 写 theme 失败；对话框每次 spawn 都重现（无进展）。PR #390 超时后检测为卡 `:first-run` + 转 `:degraded`。
- 非默认首启提示（例如新版 `claude` 的同意屏）：盲 `<Enter>` 可能**无法**关闭。PR #390 持续 first-run > 30s 时记 telemetry。

## 交叉引用

- 相关 PR：
  - PR #385 — feat(cc,np)：经 post_init hook 修复 orphan-on-restart
  - PR #388 — refactor(pty)：pid-file 发现替代 `ps`-walk
  - PR #390 — feat(pty,python,sandbox,np,lv)：PTY/Python phase 状态机 + LV 可见性
  - PR #425 — refactor(domain_agent)：按 behavior 检测 PTY 生命周期（PR-F）
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
- 测试：
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — 含首启的完整链
  - `apps/ezagent_plugin_cc/test/integration/real_claude_hotfixes_test.exs`

## 备注

- 按 `feedback_open_terminal_first_when_debugging`，LV PTY 镜像是任何 cc/np/codex 问题的**首要**调试步骤。
- 盲 `<Enter>` 的脆弱性是已知悬崖 — Anthropic 任意版本可改首启流程。缓解：PR #390 超时 + telemetry。
