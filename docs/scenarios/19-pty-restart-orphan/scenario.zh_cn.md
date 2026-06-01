# 场景 19：PTY 重启保留 cwd + 孤儿回收

**类别**：7 — PTY 交互
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-26（PR #385 + PR #388 Allen 已验证）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 一个运行中的 cc agent `entity://agent/system/my_cc`，`cwd = /tmp/my-cc-cwd`
- Admin 已登录

## 角色

- **调用方**：admin（重启触发器）
- **目标**：cc agent + 其 PTY-spawn 的 `claude` 进程

## 步骤

### 捕获状态

1. iex：`pid = Process.whereis(...)` agent supervisor。
2. Shell：`cat $(claude_config_dir)/pids/claude.pid` — 记 `claude` 进程的 OS PID。
3. 在 `/admin/agents/<uri>/terminal` 输入内容到 `claude` 确认 cwd 是 `/tmp/my-cc-cwd`。

### 重启

4. iex：`Ezagent.Kind.Runtime.dispatch(<cc_agent_uri>, :restart, %{})`。
5. Agent supervisor 调 `terminate/2`；PTY handler：
   - 给 `claude` PID（从 pid-file）发 SIGTERM
   - 等待 up to 5s 优雅退出
   - 超时则发 SIGKILL
6. Supervisor 重启 agent；新 PTY 用同 `CLAUDE_CONFIG_DIR` 和同 `cwd` spawn 新 `claude`。

### 验证

7. 确认旧 OS PID（步骤 2）不再存在（`ps -p <old_pid>` 返回空）。
8. 确认 pid-file 中是新 OS PID。
9. 确认新 `claude` PTY 显示同 `cwd`。
10. Agent 转 `boot → ready`（跳过 `first-run` 因 theme 已持久化）。

### 孤儿回收

11. 故意泄漏：不经优雅 terminate 杀掉 agent supervisor（`Process.exit(pid, :kill)`）。
12. 孤儿回收器（PR #385 + PR #388）在 supervisor 重启时扫 `<claude_config_dir>/pids/*.pid` + 经 pid-file 查找杀死残留 `claude` 进程（无 `ps`-walk）。

## 预期结果

- 重启保留 `cwd` + `claude_config_dir`（第二次无 theme 对话框）。
- 旧 OS PID 被回收（无僵尸 `claude` 进程）。
- Pid-file 是原子的：经 `:open + write + close + rename` 写（无半写 pid）。

## 失败模式

- Pid-file 已写但 `claude` 在记录前死（race）：孤儿回收器扫到指向死 OS PID 的过期 pid-file。PR #388 检测 + 清理。
- Feishu 出站中途时重启：出站派发挂在死 PTY 上；新 PTY ready 时应优雅失败。

## 交叉引用

- 相关 PR：
  - PR #385 — feat(cc,np)：经 post_init hook + 孤儿回收器修复 orphan-on-restart
  - PR #388 — refactor(pty)：pid-file 发现替代 `ps`-walk
  - PR #390 — PTY/Python phase 状态机
  - PR #425 — refactor(domain_agent)：按 behavior 检测 PTY 生命周期
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`
- 测试：
  - `apps/ezagent_core/test/integration/sandbox_destroy_test.exs`
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs` — 重启路径

## 备注

- PR #388 把脆弱的 `ps -ef | grep claude` 基础的孤儿 walk 替换为确定性 pid-file 查找。教训：经稳定 artifact 做进程发现 > 字符串解析。
- 孤儿回收是有意的：cc agent 长期运行，重启常见，任何泄漏的 `claude` 消耗 API 配额。
