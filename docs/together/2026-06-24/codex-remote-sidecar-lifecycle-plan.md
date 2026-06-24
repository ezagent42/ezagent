# codex-remote / cc-headless Sidecar 生命周期治理方案

## 背景

codex-remote 测试过程中出现过旧测试进程残留现象，表现为旧的 `codex app-server`、Codex bridge sidecar 或 cc-headless SDK worker 在测试结束、服务重启或异常退出后仍然存在。

当前排查结论：

- 当前机器上未发现活跃的 codex/codex-remote/cc-headless 残留进程。
- 最小 Python smoke 正常退出后也未留下 `codex app-server` 或 `ezagent_codex_bridge.py`。
- 真实风险集中在服务内的 `Port.open` 生命周期治理：
  - `EzagentPluginCodex.AppServer`
  - `EzagentPluginCodex.BridgeSidecar`
  - `EzagentPluginCc.SdkSidecar`
- 这些模块目前退出时基本只执行 `Port.close(port)`，对 `uv -> python`、`codex wrapper -> vendor binary` 这类进程树不够强。
- 普通 cc PTY 路径已有更完整的治理：`:exec.stop/1` + pid-file + boot-time orphan reaper，可作为设计参考。

## 目标

本方案目标是把 codex-remote、codex 普通模式、cc-headless 的外部 sidecar 生命周期治理提升到生产可用水平，覆盖：

- 正常 stop 不留下 OS 进程。
- Supervisor restart 不产生双 sidecar。
- BEAM 异常退出后，下次启动能清理上一代残留。
- 测试失败、脚本异常或中断后尽量不污染后续测试。
- 清理逻辑必须精确，不使用宽泛 `pkill codex` / `pkill python`。

## 影响面

### 直接改动模块

- `ezagent_core`
  - 新增统一 sidecar process 管理模块。
  - 复用或扩展 `Ezagent.Runtime.PidFile`。
  - 新增 sidecar orphan reaper。

- `ezagent_plugin_codex`
  - `EzagentPluginCodex.AppServer`
  - `EzagentPluginCodex.BridgeSidecar`
  - codex 普通模式和 codex-remote 都会受影响，因为两者共享 AppServer / BridgeSidecar。

- `ezagent_plugin_cc`
  - `EzagentPluginCc.SdkSidecar`
  - cc-headless 会受影响。
  - 普通 cc PTY 原则上不改，只复用其 pid-file/reaper 设计经验。

- 测试与脚本
  - `apps/ezagent_plugin_codex/test/python/codex_app_server_thread_repro.py`
  - `apps/ezagent_plugin_codex/test/python/codex_bridge_thread_smoke.py`
  - `scripts/cc_headless_sdk_sidecar_e2e_seed.exs`

### 不改动范围

- 不改 agent bridge 协议。
- 不改 Codex app-server RPC 协议。
- 不改 cc-headless SDK worker JSON line 协议。
- 不改普通 cc PTY 实现路径。
- 不引入宽泛系统进程扫描或全局 pkill。

## 设计原则

1. 精确 ownership
   - 只清理当前 deployment/profile 写入 pid-file 的进程。
   - kill 前校验 PID start time，避免 PID recycle 误杀。

2. 进程树优先
   - 只杀 direct pid 不够，`uv` 和 `codex` wrapper 都可能派生子进程。
   - 优先采用 process group 方式管理整棵 sidecar 进程树。

3. 生产和测试共用同一套能力
   - 测试脚本可以加 `try/after`、`on_exit`。
   - 但生产异常退出只能靠 pid-file + boot-time reaper 兜底。

4. 分阶段交付
   - 先完成核心生命周期能力。
   - 再补脚本 cleanup 和 e2e 证据。

## 阶段一：统一 SidecarProcess 基础设施

### 新增模块

建议新增：

```text
apps/ezagent_core/lib/ezagent/runtime/sidecar_process.ex
apps/ezagent_core/lib/ezagent/runtime/sidecar_reaper.ex
```

`SidecarProcess` 职责：

- 启动外部命令。
- 返回结构化 sidecar handle：
  - `port`
  - `os_pid`
  - `agent_uri`
  - `kind`
  - `start_seconds`
  - `pid_file_path`
- 写 pid-file。
- close 时执行：
  - `SIGTERM`
  - 等待短时间，例如 2 秒
  - 仍存活则 `SIGKILL`
  - 删除 pid-file

sidecar kind 建议：

```elixir
:codex_app_server
:codex_bridge
:cc_sdk_sidecar
```

### 启动策略

优先目标：每个 sidecar 拥有独立 process group。

可选实现路径：

- 复用现有 `:exec` 能力，如果能稳定支持非 PTY、env、cwd、stdout/stderr、monitor 和 stop。
- 或实现一个很小的 launcher wrapper，通过独立 session/process group 启动真实命令。

不建议只保留当前 `Port.open` + `Port.close`，因为它无法可靠覆盖孙进程。

### Reaper 规则

`SidecarReaper` 规则沿用 cc PTY orphan reaper：

- 枚举当前 deployment/profile 下指定 kind 的 pid-file。
- 如果对应 registry 当前已有 live owner，跳过。
- 如果 OS pid 不存在，删除 stale pid-file。
- 如果 start time 不匹配，删除 pid-file，不 kill。
- 如果 start time 匹配，TERM/KILL 清理。

## 阶段二：改造 codex / cc-headless 使用点

### Codex AppServer

改造：

```text
apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/app_server.ex
```

当前：

- `Port.open({:spawn_executable, codex}, ...)`
- `terminate/2` 中 `Port.close(port)`

目标：

- `SidecarProcess.open(:codex_app_server, agent_uri, codex, args, opts)`
- state 保存 sidecar handle。
- `terminate/2` 调 `SidecarProcess.close(sidecar)`。

### Codex BridgeSidecar

改造：

```text
apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_sidecar.ex
```

当前：

- `Port.open({:spawn_executable, runner}, args: ["run", "--script", script])`
- `terminate/2` 中 `Port.close(port)`

目标：

- `SidecarProcess.open(:codex_bridge, agent_uri, runner, runner_args ++ [script], opts)`
- 保持现有 env/cwd/stdout 行为。
- stop 时清理完整 `uv -> python` 进程树。

### cc-headless SdkSidecar

改造：

```text
apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex
```

当前：

- `Port.open({:spawn_executable, runner}, args: ["run", "--script", script])`
- `terminate/2` 中 `Port.close(port)`

目标：

- `SidecarProcess.open(:cc_sdk_sidecar, agent_uri, runner, runner_args ++ [script], opts)`
- 保持 JSON line stdin/stdout 通信能力。
- stop 时清理完整 `uv -> python -> claude sdk/cli` 相关进程树。

## 阶段三：Boot-time Reaper 接入

### codex plugin

codex plugin 启动时，在恢复 agent 或 load workspace 前清理：

- `:codex_app_server`
- `:codex_bridge`

目的：

- 避免上一代 BEAM 残留 bridge 重新连接 AgentBridge。
- 避免旧 app-server 持有旧 socket/thread 状态。

### cc plugin

cc plugin 保留现有普通 cc PTY orphan reaper，并新增：

- `:cc_sdk_sidecar`

目的：

- 避免 cc-headless SDK worker 在服务重启后继续占用会话或配置目录。

## 阶段四：测试脚本与 e2e cleanup

### Python smoke

改造：

```text
apps/ezagent_plugin_codex/test/python/codex_app_server_thread_repro.py
apps/ezagent_plugin_codex/test/python/codex_bridge_thread_smoke.py
```

建议：

- `subprocess.Popen(..., start_new_session=True)`
- terminate 时：
  - `os.killpg(proc.pid, signal.SIGTERM)`
  - 等待
  - `os.killpg(proc.pid, signal.SIGKILL)`

### cc-headless e2e seed

改造：

```text
scripts/cc_headless_sdk_sidecar_e2e_seed.exs
```

建议：

- 用 `try/after` 包裹从 `SdkSidecar.start/2` 到等待回复的主体逻辑。
- `after` 中执行 `EzagentPluginCc.SdkSidecar.stop(agent_uri)`。

## 测试计划

### Core 单测

新增：

```text
apps/ezagent_core/test/ezagent/runtime/sidecar_process_test.exs
apps/ezagent_core/test/ezagent/runtime/sidecar_reaper_test.exs
```

覆盖：

- 启动 sidecar 后写入 pid-file。
- close 后删除 pid-file。
- close 后 direct pid 不存在。
- fake runner 派生 child，close 后 child 也不存在。
- start time 不匹配时不 kill。
- dead pid 只清 stale pid-file。

### Codex 测试

覆盖：

- `AppServer.stop/1` 调用后 sidecar pid-file 清理。
- `BridgeSidecar.stop/1` 调用后 sidecar pid-file 清理。
- codex-remote rollback 后 AppServer + BridgeSidecar 都停止。
- restart 场景不会产生双 bridge/double app-server。

### cc-headless 测试

覆盖：

- `SdkSidecar.stop/1` 后 pid-file 清理。
- pending request 在 sidecar exit 时仍按现有行为回复 error。
- e2e seed 异常路径也会 stop。

### 验证命令

```bash
mix test apps/ezagent_core/test/ezagent/runtime/sidecar_process_test.exs
mix test apps/ezagent_core/test/ezagent/runtime/sidecar_reaper_test.exs
mix test apps/ezagent_plugin_codex/test
mix test apps/ezagent_plugin_cc/test/bridge_adapter_test.exs
mix precommit
```

额外人工检查：

```bash
ps -eo pid=,ppid=,pgid=,stat=,etime=,args= | \
  awk '/codex app-server|ezagent_codex_bridge.py|ezagent_cc_sdk_worker.py/ && $0 !~ /awk/ {print}'
```

## 验收标准

- 正常 stop 后无残留：
  - `codex app-server`
  - `ezagent_codex_bridge.py`
  - `ezagent_cc_sdk_worker.py`
- codex-remote session 重启不会出现旧 bridge 重连。
- codex 普通模式不回退。
- cc-headless session 往返不回退。
- BEAM 异常退出后，下次启动能清理旧 sidecar。
- 测试失败或脚本异常后，不污染下一轮测试。
- 不使用宽泛 `pkill`。
- 所有 kill 都基于 pid-file ownership + start time 校验。

## 风险与控制

### 风险：process group 边界处理错误

控制：

- 只对 sidecar wrapper 创建的新 process group 下发信号。
- 不对当前 shell、BEAM、用户手动运行的 codex/claude 进程下发信号。

### 风险：env/cwd/argv 传递变化

控制：

- 改造时保持现有 env/cwd/args 逐项对齐。
- 为 AppServer、BridgeSidecar、SdkSidecar 分别补参数断言测试。

### 风险：macOS/Linux 差异

控制：

- 不依赖 fragile `ps -E` 扫描。
- 使用 pid-file + start time。
- kill 命令只接受明确 pid/pgid。

### 风险：一次改动过大

控制：

- 阶段一只做基础设施和 fake process 测试。
- 阶段二再接入三个 sidecar。
- 阶段三接 reaper。
- 阶段四补脚本和 e2e 证据。

## 建议 PR 拆分

### PR 1：Sidecar 生命周期基础设施

内容：

- 新增 `SidecarProcess`
- 新增 `SidecarReaper`
- 新增 core 单测

### PR 2：codex / cc-headless 接入

内容：

- 改造 `AppServer`
- 改造 `BridgeSidecar`
- 改造 `SdkSidecar`
- 补 plugin 层测试

### PR 3：测试脚本与 e2e cleanup

内容：

- Python smoke process group cleanup
- cc-headless e2e seed `try/after`
- 补残留检查记录和人工验证证据

## 当前建议

建议优先推进 PR 1 + PR 2，先解决生产侧和服务内 supervisor restart 的根因；PR 3 可以紧随其后补齐测试脚本残留治理。
