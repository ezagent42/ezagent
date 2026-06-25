# Handoff — C: LocalRuntime 收口（#99，allenwoods）

> 三条并行子任务之一（见主文档）。Allen 会对本 handoff 走 brainstorm 完善。

## 目标
让 hello/protocol_api/world 的 spawn/lookup 走 `LocalRuntime`（owner-gated chokepoint），不再直接调 `SpawnRegistry`/`KindRegistry`。**LocalRuntime 保持 URI-only / behavior-agnostic**（behaviors 由 A 在 Entity.Agent 内解析，C 不碰）。

## 背景（现状，调用点已盘点，全是 URI-only）
- `hello/.../template/hello_session.ex:41` — `KindRegistry.lookup(session_uri) == :error`（liveness）
- `protocol_api/.../conversation_registry.ex:53,90` — `SpawnRegistry.spawn(session_uri)`
- `protocol_api/.../openai_chat_plug.ex:109` — `KindRegistry.lookup(agent_uri)`；`:195` — `SpawnRegistry.spawn(agent)`
- `world/.../workspace_plugin_data.ex:122,164` — `KindRegistry.lookup(ws.uri)`
- #95 已把 cc/codex/echo/feishu/advisor 迁过；这是剩下的 hello/protocol_api/world。

## 设计（待 brainstorm 定稿）
- `KindRegistry.lookup(uri) == :error`（liveness）→ `not LocalRuntime.kind_alive?(uri)`。
- `SpawnRegistry.spawn(uri)` → `LocalRuntime.ensure_started(uri)`。
- 单节点下 WorkspaceOwnerGate 为 no-op，**行为保持**。
- **不需要带-behaviors 的 arity**（A 把 behaviors 解析放进 Entity.Agent）→ LocalRuntime 维持 URI-only。

## DoD（四性质）
- [ ] hello/protocol_api/world 不再直接调 SpawnRegistry/KindRegistry（走 LocalRuntime）。
- [ ] arch 扫描 `spawn_registry_call_sites`/`off_chokepoint_modules` 计数下降并**下调 cap**（lowering 免注解）。
- [ ] **单节点行为不变**：全量 mix test 绿；protocol_api 起 agent、hello/world liveness 路径有测试覆盖。
- [ ] CI 绿 + rebase。

## 关键文件
- `apps/ezagent_plugin_hello/.../template/hello_session.ex`
- `apps/ezagent_plugin_protocol_api/lib/.../{conversation_registry.ex, openai_chat_plug.ex}`
- `apps/ezagent_plugin_world/.../workspace_plugin_data.ex`
- `apps/ezagent_core/lib/ezagent/local_runtime.ex`（只读，不加 arity）
- arch 基线：`arch_baseline_manifest.exs`

## 冲突点
- **与 B 都改 `arch_baseline_manifest.exs`** → 串行改该文件。
- 与 A 已解耦（LocalRuntime 维持 URI-only）。
- protocol_api 命名/拆分是 #96（Allen 拍），不在本子任务；本子任务只收口 spawn/lookup。

## 必读
skill `ezagent-developer`；主文档；#95 的 LocalRuntime 迁移先例（cc/codex 等）；dev-together。
