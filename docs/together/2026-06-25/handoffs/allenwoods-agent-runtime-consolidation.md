# Handoff — agent 运行时后端整合（allenwoods / 林懿伦）

> **任务**: 把 LocalRuntime + agent 后端（cc-headless sidecar + protocol_api）整合为一个完整、连贯的运行时。
> **分支**: `feat/agent-runtime-consolidation`（off `main`，保持 rebase）
> **本周目标**: 团队日用（目标①）的底座 —— agent 运行时一致、可去中心化。
> **前置（clarify-first）**: 等 `gagameow` 的 `agent-runtime-situation.md` 现状 handoff 落地后再动手定方案。

## 背景
LocalRuntime（#95，owner-gated facade）已迁了 cc/codex/echo/feishu/advisor，但：
- hello/protocol_api/world 还直接调 SpawnRegistry/KindRegistry（#99，6 处 URI-only 调用点已盘点）。
- echo→Entity.Agent（#918）需要 LocalRuntime 一个**带 behaviors 的 spawn arity**，现 facade 是 URI-only —— 这是和 #918 共用的关键决策。
- cc-headless sidecar 生命周期（#97）+ protocol_api 的 spawn/lookup 各自为政，没有统一在 LocalRuntime 这个 chokepoint 下。

## 要做什么（待 gagameow 现状 handoff 厘清后定稿）
1. **决策**：LocalRuntime 是否加带-behaviors 的 spawn arity（建议加，#918/#99 都受益）还是给 echo sanctioned 例外。
2. **迁移 #99**：hello/protocol_api/world 的 6 处 SpawnRegistry/KindRegistry 调用 → LocalRuntime；arch cap 相应下调（lowering 免注解）。
3. **整合 sidecar + api**：把 cc-headless sidecar + protocol_api 的运行时入口统一到 LocalRuntime chokepoint；明确 sidecar 生命周期（#97 范围）。
4. echo→Entity.Agent（#918）的 LocalRuntime 侧按决策落地（业务侧与 `FatNine` 协调，见 plan 的待分派项）。

## DoD（四性质）
- [ ] **现状 handoff 已消化** + 整合方案写清（先 clarify 再 build）。
- [ ] hello/protocol_api/world 不再直接调 SpawnRegistry/KindRegistry（走 LocalRuntime）；arch 扫描 off_chokepoint/spawn_registry 计数下降并 ratchet。
- [ ] LocalRuntime spawn arity 决策落地，#918 echo 能据此 rebase。
- [ ] **回归 + 单节点行为不变**：迁移后全量 `mix test` 绿（单节点 owner-gate 为 no-op，行为保持）；关键路径（protocol_api 起 agent、cc-headless 起 session）有测试覆盖。
- [ ] **CI 绿** + rebase 到当前 main。

## 关键文件
- `apps/ezagent_core/lib/ezagent/local_runtime.ex`（facade + 可能的新 arity）
- `apps/ezagent_plugin_protocol_api/lib/.../{conversation_registry.ex, openai_chat_plug.ex}`
- `apps/ezagent_plugin_hello/.../template/hello_session.ex`、`apps/ezagent_plugin_world/.../workspace_plugin_data.ex`
- `apps/ezagent_plugin_cc`（sidecar 生命周期）
- arch 基线：`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`

## 必读
- `gagameow` 的 `docs/together/2026-06-25/handoffs/agent-runtime-situation.md`（前置）
- skill `ezagent-developer`；`docs/together/2026-06-24/review.zh_cn.md`（#99/#918 背景）
- dev-together skill（core/插件隔离=clarify-first；DoD 四性质；返还前 rebase+自测绿）
