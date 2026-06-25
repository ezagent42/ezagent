# Handoff — B: sidecar 统一到 erlexec + 禁 Port gate（allenwoods）

> 三条并行子任务之一（见主文档）。Allen 会对本 handoff 走 brainstorm 完善。

## 目标
把所有 OS 子进程的生成/治理统一到 **erlexec**，根治 `Port.open` 退出留孤儿的问题；并加 **arch gate 禁止未来裸用 `Port.open({:spawn_executable})`**。

## 背景（现状）
- 无共享封装：PTY 裸用 `:exec.run`（`pty/server.ex:509`，治理良好 = 样板）；**4 处裸 `Port.open({:spawn_executable})`**：
  - `EzagentPluginCc.SdkSidecar`（`sdk_sidecar.ex:214`）
  - `EzagentPluginCodex.AppServer`（`app_server.ex:111`）
  - `EzagentPluginCodex.BridgeSidecar`（`bridge_sidecar.ex:130`）
  - `EzagentPluginFeishu.WsClient`（`ws_client.ex:92`，node ws sidecar）
- 根因：原生 `Port.close` 只杀直接子进程，杀不到 `uv→python`/`codex→vendor`/node 子树 → 孤儿。
- 已有 `Cc.OrphanReaper` 但只覆盖 PTY。

## 设计（待 brainstorm 定稿）
1. **统一 erlexec 封装模块**（`ezagent_core`，复用/扩展 `Runtime.PidFile`）：`run/stop` + stdin/stdout 收发 + 进程组 + BEAM-death reaping。所有子进程走它。
2. **逐个迁移 4 个 sidecar** Port.open→封装：**先 `Cc.SdkSidecar` 验证 JSON-line 协议跑通**，再 codex 两个、feishu ws。每个的 IO 从 Port 消息改成 erlexec `{:stdout,...}` + `:exec.send`。
3. **arch gate**：禁裸 `Port.open({:spawn_executable})`（同 SpawnRegistry/raw_home_path gate 款）。封装模块是 sanctioned 唯一出口。
4. 全用 erlexec 后 **gaga #952 的独立 pid-file/reaper 方案基本不需要**（erlexec 自带）。

## DoD（四性质）
- [ ] erlexec 封装模块 + 4 个 sidecar 全走它（无裸 Port.open，feishu ws 迁移或显式 allowlist 带理由）。
- [ ] **arch gate** 上线：裸 `Port.open({:spawn_executable})` 计数被钉死/禁止。
- [ ] **不留孤儿**：stop/restart/崩溃后无残留 OS 进程（按 #952 的验收口径，精确 ownership、不用宽泛 pkill）—— 给出验证（如 sidecar 启停后无残留进程的检查）。
- [ ] **不改普通 cc PTY**（它已是 erlexec 样板）。
- [ ] 全量 mix test 绿；CI 绿 + rebase。

## 关键文件
- 新封装：`apps/ezagent_core/lib/ezagent/runtime/`（+ 复用 `pid_file.ex`）
- 迁移：`cc/.../sdk_sidecar.ex`、`codex/.../app_server.ex`、`codex/.../bridge_sidecar.ex`、`feishu/.../ws_client.ex`
- gate：`apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` + `arch_baseline_manifest.exs`
- 样板参考：`pty/server.ex`（erlexec 用法）；gaga #952 `codex-remote-sidecar-lifecycle-plan.md`（验收口径）

## 冲突点
- **与 C 都改 `arch_baseline_manifest.exs`** → 串行改该文件（谁先合，另一个 rebase 重 ratchet）。
- feishu ws 迁移触及 feishu 插件（无人今日在改 feishu，低冲突）。

## 必读
skill `ezagent-developer`；主文档；gaga #952 sidecar 方案；`pty/server.ex` erlexec 样板；dev-together。
