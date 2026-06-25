你（codex）实现 ezagent **agent-runtime 整合的子任务 C：LocalRuntime 收口（#99）**。工作目录 `/Users/h2oslabs/Workspace/esr-ng`，分支 `feat/localruntime-migration-c`（off 当前 `main`）。

**第一步 — 加载 skill（你没有 Skill 工具，请直接 `cat` 读完这些 SKILL.md 再动手；不读会写出过时 Elixir + 违反 ezagent 不变量）**：
- `.claude/skills/ezagent-developer/SKILL.md`（ezagent 架构/Kind/Behavior/cap 不变量 —— 必读）
- `.claude/skills/elixir-phoenix-helper/SKILL.md`（现代 Elixir/Phoenix 写法，别写 2023 老语法）

**先读**（以它们为准，别凭记忆）：
- handoff：`docs/together/2026-06-25/handoffs/allenwoods-C-localruntime-migration.md`
- 主文档（冲突点）：`docs/together/2026-06-25/handoffs/allenwoods-agent-runtime-consolidation-plan.md`
- 先例：#95 已把 cc/codex/echo/feishu/advisor 迁过 LocalRuntime，照同样 pattern。

**任务（机械、已 well-scoped）**：把 hello/protocol_api/world 这 6 处直接调 `SpawnRegistry`/`KindRegistry` 改走 `Ezagent.LocalRuntime`：
- `hello/.../template/hello_session.ex:41` `KindRegistry.lookup(uri)==:error` → `not LocalRuntime.kind_alive?(uri)`
- `protocol_api/.../conversation_registry.ex:53,90` `SpawnRegistry.spawn(uri)` → `LocalRuntime.ensure_started(uri)`
- `protocol_api/.../openai_chat_plug.ex:109` `KindRegistry.lookup` / `:195` `SpawnRegistry.spawn` → 同上
- `world/.../workspace_plugin_data.ex:122,164` `KindRegistry.lookup` → `kind_alive?`
- **LocalRuntime 保持 URI-only，不要给它加 behaviors/参数**（behaviors 归子任务 A）。
- 之后**下调** `arch_baseline_manifest.exs` 的 `spawn_registry_call_sites` / `off_chokepoint_modules` 到新实际值（lowering 免注解）。

## ⚠️ dev-together 纪律（必须严格遵守 —— 这是硬门槛，不是建议）
1. **机器 return 闸**：返还前，PR 的 **CI（`precommit + check_invariants`）必须在 PR head 绿**，且**已 rebase 到当前 `main`**。"我本地过了/应该没问题"不算数 —— **以 PR 上的 CI 绿为准**。
2. **四性质 DoD 逐条核**（见 handoff）：目标派生 / 可验证带证明 / 在用户面 / 闭集。返还时逐条对账（met/deferred/not-met + 证据）。单节点行为必须不变（owner-gate 为 no-op），关键路径（protocol_api 起 agent、hello/world liveness）要有测试覆盖。
3. **不准自合 main**：推 PR、写 return（`docs/together/2026-06-25/returns/`，dev-together 格式），交回 lead（allenwoods）统一合并。
4. **不准自行延期 DoD 某条**：要延期 → 标 deferred + 列给 lead 裁定，别自宣"可合并"。
5. **冲突点**：B 与 C 都改 `arch_baseline_manifest.exs` → 若 B 先合，你 rebase 后重新 ratchet。
6. **澄清原则（快速迭代）**：开工前**一次性想清所有可能要澄清的问题**（一起问 lead，或带明确默认假设），然后**自驱做到完成、过程中不要逐个停下问**；完成后回头和 lead 澄清是否要改。只有"猜错会推翻整个方案"的决策才中途停。本任务是机械迁移、几乎无需新决策；若发现某处不是 URI-only（需传参），按默认假设标注实现 + 完成后一并上报（那是 A 的边界），别中途卡住。

完成把 PR 号 + return 交回 lead。