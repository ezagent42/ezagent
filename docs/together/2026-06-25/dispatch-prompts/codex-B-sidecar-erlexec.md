你（codex）实现 ezagent **agent-runtime 整合的子任务 B：sidecar 统一到 erlexec + 禁 Port gate**。工作目录 `/Users/h2oslabs/Workspace/esr-ng`，分支 `feat/sidecar-erlexec-b`（off 当前 `main`）。

**第一步 — 加载 skill（你没有 Skill 工具，请直接 `cat` 读完这些 SKILL.md 再动手；不读会写出过时 Elixir + 违反 ezagent 不变量）**：
- `.claude/skills/ezagent-developer/SKILL.md`（ezagent 架构/Kind/Behavior/cap 不变量 —— 必读）
- `.claude/skills/elixir-phoenix-helper/SKILL.md`（现代 Elixir/Phoenix 写法）
- `.claude/skills/erlexec-elixir/SKILL.md`（**erlexec 用法 —— 本任务核心，必读**）

**先读**（以它们为准）：
- handoff：`docs/together/2026-06-25/handoffs/allenwoods-B-sidecar-erlexec.md`
- 主文档（冲突点）：`docs/together/2026-06-25/handoffs/allenwoods-agent-runtime-consolidation-plan.md`
- 样板：`apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex`（erlexec `:exec.run` 用法，治理良好）；gaga `docs/together/2026-06-24/codex-remote-sidecar-lifecycle-plan.md`（验收口径）。

**任务（按子步骤做，别一次性大改）**：把 4 个裸 `Port.open({:spawn_executable})` 的 sidecar 统一到 erlexec，根治孤儿进程。
- **背景/根因**：原生 `Port.close` 只杀直接子进程，杀不到 `uv→python`/`codex→vendor`/node 子树 → 孤儿。erlexec（PTY 已用）有进程组 + `:exec.stop` + BEAM-death reaping。
- **子步骤（建议每步一个可验证 commit）**：
  1. 建**统一 erlexec 封装模块**（`apps/ezagent_core/lib/ezagent/runtime/`，复用 `pid_file.ex`）：run + stdin（`:exec.send`）+ stdout（`{:stdout,...}`）+ stop + 进程组。
  2. 迁 `EzagentPluginCc.SdkSidecar`（`sdk_sidecar.ex:214`）→ 封装；**先验证 JSON-line 协议跑通**。
  3. 迁 `EzagentPluginCodex.AppServer`（`app_server.ex:111`）+ `EzagentPluginCodex.BridgeSidecar`（`bridge_sidecar.ex:130`）。
  4. 迁 `EzagentPluginFeishu.WsClient`（`ws_client.ex:92`，node ws）；若有特殊性无法迁，**显式 allowlist + 写明理由**（别默默跳过）。
  5. 加 **arch gate**：禁裸 `Port.open({:spawn_executable})`（仿 `ezagent.arch.scan.ex` 里 SpawnRegistry/raw_home_path gate），封装模块是唯一 sanctioned 出口。
- **不改普通 cc PTY**（已是 erlexec 样板）。

## ⚠️ dev-together 纪律（必须严格遵守 —— 硬门槛）
1. **机器 return 闸**：返还前 PR 的 **CI（`precommit + check_invariants`）必须在 PR head 绿** + **rebase 到当前 `main`**。以 PR 的 CI 绿为准，不是你的断言。
2. **四性质 DoD 逐条核**（见 handoff）：尤其"**不留孤儿**"要有验证（精确 ownership、**不准用宽泛 `pkill codex`/`pkill python`**）+ JSON-line 协议在 erlexec 下确实跑通的证明。
3. **不准自合 main**：推 PR + 写 return（`docs/together/2026-06-25/returns/`，dev-together 格式），交回 lead 合并。
4. **不准自行延期 DoD**：要延期 → 标 deferred + 列给 lead 裁定。
5. **冲突点**：B 与 C 都改 `arch_baseline_manifest.exs` → 串行；若 C 先合你 rebase 重 ratchet。
6. **澄清原则（快速迭代）**：开工前**一次性列清所有可能要澄清的问题**（一起问 lead，或带明确默认假设），然后**自驱做到完成、过程中不逐个停问**；完成后回头澄清是否要改。只有"猜错会推翻整个方案"才中途停。例：某 sidecar 协议在 erlexec 下行为存疑 → 带默认假设实现 + 完成后一并上报，别中途卡住。

完成把 PR 号 + return 交回 lead。