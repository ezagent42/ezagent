# PTY/Python 子进程 phx 重启后孤儿问题修复 — 2026-05-26

## 问题

cc 和 np agent 是两层进程模型：

1. **Agent Kind**（Elixir GenServer）— OTP 监督；phx 重启时通过
   `Ezagent.Kind.Snapshot.load_or_init/3` 从 `kind_snapshots` 恢复。
2. **OS 子进程**（cc：在 `Ezagent.Domain.Pty.Server` 下的 claude TUI；
   np：在 `Ezagent.Domain.Python.Server` 下的 Python 解释器）— 由
   `:exec.run/2`（erlexec）拥有。**不跨 BEAM 重启被 OTP 监督**。

BEAM 退出时，erlexec 的 port-death 清理通常通过 SIGTERM 回收 OS 子进程。
但 **暴力杀死 BEAM**（SIGKILL、panic、SEGV）会跳过这层清理 — OS 级
claude / Python 进程会留在原死掉的 PTY 上继续活着。

phx 重启后，有两种失败模式：

### 模式 A — 孤儿重连，按需 spawn Kind，ESR 无法管理

1. 孤儿 claude 通过 cc bridge Phoenix.Channel 重连 ESR。
2. Channel join 调用 `Ezagent.SpawnRegistry.spawn(agent_uri)` —
   按需 spawn Agent Kind。
3. 之后 `Workspace.Loader.load_all/0` 遍历 workspace 的
   `session_templates`，触发 `cc.agent.instantiate/3`。
4. `instantiate/3` 看到 `agent_kind_alive?(uri) == true`，立即返回
   （codex round-8 — "拒绝接管外来 Kind"）。
5. **PtyServer 永远不会被 spawn**。Agent Kind 活着但没有 PTY → operator
   的 LV 终端页面是死的（无法写入，无输出流）。与此同时，OS 孤儿
   claude 还在和它老的 bridge channel 说话。

### 模式 B — 孤儿默默活着，阻塞新 spawn

1. 孤儿 claude 活着但没有重连（比如它的 token 已不匹配任何已知 bridge）。
2. `Workspace.Loader` 干净地触发 `cc.agent.instantiate/3`，启动新的
   PtyServer + claude。
3. 现在同一 agent URI 有两个 OS claude 在跑。资源竞争；per-instance
   MCP 配置（`.mcp.json`）被覆盖。

## 修复方案（Allen 2026-05-26 指定 Option A）

两个独立层：

### Layer 1 — post_init 重启钩子（覆盖模式 A）

`Ezagent.Behavior.Sandbox`（每个 cc Agent Kind 都挂载的 plugin-agnostic
Behavior）现在导出 `post_init/2` + `handle_continue/3`。启动时：

1. Sandbox slice（从 snapshot rehydrate）携带 `template_class` +
   `respawn_template_data`。
2. `post_init/2` 在两者都有值时排队一个
   `{:continue, :ensure_subprocess}`。
3. `handle_continue/3` 调用 plugin 的
   `Kind.Template.ensure_subprocess_alive(agent_uri, respawn_data)`
   optional callback（本 PR 新增）。
4. cc Template Class 实现该 callback：检查
   `Ezagent.Domain.Pty.alive?/1`；不在则用持久化的 template data 重新
   跑 `ensure_pty_server/3`。

np 的处理：`Ezagent.Behavior.NpAgent`（挂在 `Ezagent.Entity.NpAgent`
上的 plugin-specific Behavior）直接获得同样的 post_init 钩子 —
NpAgent Kind 不用 Sandbox（`:ephemeral` 持久化，无 config_dir）。
callback 派发对称：NpAgent slice 携带 `cwd`；启动时
`handle_continue/3` 调用
`Ezagent.PluginNp.Template.NpAgent.ensure_subprocess_alive/2`。

### Layer 2 — 孤儿收割器（覆盖模式 B + 让模式 A 不再可达）

每个 plugin 各自有 `OrphanReaper` 模块，在 `after_boot/0` 里调用，
**先于** `Workspace.Loader.load_all/0`（cc）/ template 实例化（np）。

收割器通过以下方式识别 cc/np 管理的 OS 子进程：

1. **Argv 签名** — cc：`--dangerously-load-development-channels
   server:esr-bridge`；np：`np_compute_server.py`。
2. **环境变量** — `EZAGENT_AGENT_URI=<uri>`（cc PtyServer 早有；np
   Template Class 现在通过 Domain.Python.Spec `env` 字段也设置）。
3. **URI 形状门** — cc：`entity://agent/<ws>/cc_*`；np：
   `entity://agent/<ws>/np_*`。
4. **Registry 检查** — `Ezagent.Domain.Pty.alive?/1`（cc）/
   `Ezagent.Domain.Python.alive?/1`（np）。URI 在 BEAM 内没活的 server
   就是孤儿。

每个孤儿被发送一次 `kill -TERM`。**绝不** 大范围 `pkill -9`（参考
memory `feedback_no_pkill_tmux_default_socket`）。

`:test` 环境下收割器默认 **关闭**（每个测试启动新 BEAM，空的
Pty/Python registry，所以每个残留 OS 进程都看起来可收割 — 会杀掉 e2e
想检查的孤儿）。通过 `config :ezagent_plugin_cc,
reap_orphans_on_boot: true` 开启。

## 三层架构保持

- Tier 1（core）：`Ezagent.Behavior.Sandbox` + 新的
  `Ezagent.Kind.Template.ensure_subprocess_alive/2` callback。Core
  **完全不知道** PTY / Python — 只通过 optional callback 路由。
- Tier 2（domain）：`Ezagent.Domain.Pty.alive?/1` 和
  `Ezagent.Domain.Python.alive?/1` 是 registry 检查原语。Plugin 收割器
  消费它们。
- Tier 3（plugin）：cc + np 实现 callback + 拥有自己的孤儿收割器。
  每个收割器知道自己 plugin 的 argv 签名。

无新的跨层耦合。无新的 plugin-to-plugin 耦合。Sandbox behaviour 扩展
是 plugin-agnostic 的（仅通过 optional `function_exported?/3` 探测加入）。

## let-it-crash 纪律

遵循 `feedback_let_it_crash_no_workarounds`：
- 收割器本身是 best-effort：`ps` 失败或 `kill` 失败会记录日志但
  **不会** 让 plugin Application 启动崩溃。漏杀的孤儿会在下次 phx
  重启的收割中再被处理。
- Round-2（codex finding #3）：post_init 失败路径改用 log + telemetry +
  `:ignore`（DEGRADED 状态）替代 raise。详见下面"Round-2 修复"。

## Round-2 修复（codex adversarial-review）

Codex 审核了 PR #385（round 1）给出 4 个 finding（3 HIGH + 1 MEDIUM）。
全部修复：

### Finding #1（HIGH）— cc demand-spawn 竞态窗口

**问题**：chat router 通过 `SpawnRegistry.spawn` 按需启动 cc Agent Kind
时，Sandbox slice 没有 `template_class` / `respawn_template_data`，
`post_init/2` 返回 `:ok`（不排队重启）。之后 `Workspace.Loader.load_all/0`
跑 `cc.agent.instantiate/3` 时，codex round-8 的"拒绝接管外来 Kind"
短路触发，新的 PtyServer 永远不被启动。

**修复**：`instantiate/3` 的 `:already_started` 分支现在加了
**workspace-segment ownership gate**（`owns_this_agent?/2`）：如果
agent URI 的 workspace 段匹配 `workspace_uri`，这就是我们模板的 agent
（Workspace.Loader 路径）→ 通过新的 `ensure_subprocess_alive/2` callback
启动 PTY。如果段不匹配，codex round-8 不变量保持 — 拒绝 PTY 启动
（跨 workspace 接管被拒绝，和以前一样）。

### Finding #2（HIGH）— 多 BEAM 安全（误伤友军）

**问题**：孤儿收割器通过"URI 不在本 BEAM `Pty.alive?/1` registry"识别
孤儿。同一 OS user 下的并行 BEAM 可能有合法的活 claude，其 URI 自然
不在本 BEAM 的 registry → 收割器会 SIGTERM B 的活进程。

**修复**：每个 spawn 出来的子进程现在带 `EZAGENT_DEPLOYMENT_ID` 环境
变量 = `Ezagent.DeploymentId.deployment_id/0`（组成 `node()|cwd_at_load`）。
收割器拒绝杀任何 deployment_id 与当前 BEAM 不匹配的进程。同源码树启动
的两个 `iex -S mix phx.server` 得到同一个 deployment_id（合法的同部署
互相收割）。两个并行 worktree 得到不同的 deployment_id（防止跨部署误伤）。

### Finding #3（HIGH）— 持续失败导致紧密重启循环

**问题**：我 round-1 用 `raise` 在 `Sandbox.handle_continue/3` 处理
callback 的 `{:error, _}`。这触发 `Kind.Server` GenServer 崩溃 →
`EzagentDomainInstanceMessage.AgentSupervisor` 用 DynamicSupervisor 默认
intensity 重启（`max_restarts: 3, max_seconds: 5`）。持续失败（claude
被从 PATH 移除）在毫秒内耗尽 3 次重启 → AgentSupervisor 自己崩溃 →
**连带杀掉其他正常 agent**。

**修复**：把 `raise` 换成 `Logger.error + :telemetry.execute(
[:ezagent, :sandbox, :subprocess_unhealthy], ...) + :ignore`。Kind
进入 `:ready` 的 DEGRADED 状态 — 活着但没子进程。这**不是**静默
降级：telemetry event 会浮到 admin LV health panel + 日志大声报错。
operator 通过现有 UI 手动点 Restart。

正确的结构性修复（per-agent supervisor + 隔离 intensity）**不在本
PR 范围**内 — 跟进单独处理。

### Finding #4（MEDIUM）— np `ensure_python_alive` 吞错

**问题**：`ensure_python_alive/2` 通过 `_ = start_python(...)` 丢弃
结果，无条件返回 `:ok`。被接管 Kind 分支上 Python spawn 失败会让 agent
看起来活但没工作子进程（失败只在第一次用户流量 dispatch 时才暴露）。

**修复**：`ensure_python_alive/2` 现在传递 `start_python/2` 的结果。
调用方（`instantiate/3` 被接管 Kind 分支）记日志 + 返回错误给 chat
domain（chat domain 会把错误浮上来）。

### Round-2 新增文件

- `apps/ezagent_core/lib/ezagent/deployment_id.ex` — **新增**：部署身份
  helper。

## 已知限制 + 后续工作

- **持续 post_init 失败 → DEGRADED 状态**（codex finding #3）：Kind
  保持活着但没子进程，直到 operator 手动 Restart。未来 PR 应该引入
  per-agent 监督 + 隔离 intensity，让暂态失败用退避自动重试而不级联。
- **EZAGENT_DEPLOYMENT_ID 升级窗口**（codex finding #2）：本 PR 之前
  的 BEAM 启动的进程**没有** deployment_id env 变量 — 收割器拒绝杀
  这些（fail closed）。从老版本升级的 operator 必须在第一次 post-PR
  启动前手动 `pkill claude`，或者接受"第一次启动收割器什么都不做；
  孤儿靠手动清理"的过渡。
