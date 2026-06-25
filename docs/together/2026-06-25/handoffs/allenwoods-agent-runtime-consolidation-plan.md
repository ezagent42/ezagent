# 规划（主文档）— agent 运行时后端整合（allenwoods）

> 总方向（@林懿伦）：**所有 agent 的配置接口收拢到 `domain.agent` 的统一入口 + 注册器**。
> 结构（@林懿伦 2026-06-25 拍板）：**拆成 A/B/C 三条并行子任务**，各有独立 handoff（Allen 逐个 brainstorm 完善）。本主文档 = 三条总览 + **统一冲突点** + **gaga console 接口契约**。
> 设计已厘清的两点：①**LocalRuntime 保持 behavior-agnostic（只吃 URI）**，behaviors 由 Entity.Agent 从存储的 flavor 统一解析（撤销之前的 spawn-arity 想法）。②**sidecar 用 erlexec 根治**（不另建 reaper）。

## 三条并行子任务
| 子任务 | 一句话 | handoff |
|---|---|---|
| **A** 配置统一 → domain.agent | Entity.Agent 从存储 flavor **统一解析 config+behaviors**（含 curl 去 thread、echo 接入），所有 flavor 经 domain.agent 统一入口/registrar | `allenwoods-A-config-unification.md` |
| **B** sidecar → erlexec | 建统一 **erlexec 封装** + **arch gate 禁裸 `Port.open`**，4 个 sidecar 迁移 | `allenwoods-B-sidecar-erlexec.md` |
| **C** LocalRuntime 收口 | hello/protocol_api/world 的 spawn/lookup 走 LocalRuntime（#99），LocalRuntime 保持 URI-only | `allenwoods-C-localruntime-migration.md` |

## 统一冲突点（Allen 要的"可能的冲突点统一规划"）
1. **A ↔ C 已解耦**（关键）：因为 behaviors 不再 spawn-thread（A 在 Entity.Agent 内解析），C 的 LocalRuntime 保持 URI-only，**两者不再互相依赖**，可真并行。
2. **B ↔ C 都改 arch 基线**：B 加 `Port.open` gate + 可能 ratchet；C 下调 `spawn_registry_call_sites`/`off_chokepoint`。**两者都写 `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`** → **串行改这个文件**（谁先合，另一个 rebase 后重新 ratchet）。
3. **A ↔ gaga 的 console**：A 改的是 console 消费的**配置后端**；见下"接口契约"——**必须提前约定**，否则 console 会被 A 的重构打断。
4. **A ↔ #918（echo，FatNine 今日休息）**：echo→Entity.Agent 的逻辑并入 A（echo 作为统一 flavor 解析的一个 case）；FatNine 不在，无并发写冲突。
5. **C ↔ zyli 的 F9/F12**：zyli 触及 session/feishu 接线，C 触及 protocol_api/world 的 spawn —— 文件面基本不重叠；若 zyli 改到 world spawn 路径则按 world-coordination 协调。
6. **B ↔ feishu**：B 的 `Port.open` gate 会命中 `PluginFeishu.WsClient`（node ws sidecar）——要么一起迁 erlexec、要么显式 allowlist 带理由（B handoff 里定）。

## gaga console 接口契约（Allen 问的"是否需要提前约定" → 需要）
**需要，且现在约定。** console（gaga）消费 agent 配置后端；A 要在底下把它收拢到 domain.agent。为不打断 gaga：
- **契约 = 保持 `Ezagent.AgentConfig` facade 的签名稳定作为 console 的消费面**：`read_cascade/4`、`read_key/5`、`apply_delta/4`、`delete_path/4`、`repoint/4` + 配置数据形状（cascade/key + 结构化每字段 schema）。
- **A 在这个 facade 之下做收拢**（domain.agent 成为实现），**不改 facade 签名**；若必须改，先在群里改契约 + 通知 gaga。
- 这样 **gaga 按这个稳定契约建 console（A 没好也能用/可 mock）**，A 在底下重构，互不阻塞。
- 待 gaga/你 ratify 这个契约（或指定一个新的 domain.agent.config_* 统一入口作为契约）。

## DoD（总）
所有 4 个 flavor（cc/codex/curl/echo）的 config+behaviors 都经 domain.agent 统一解析/入口（parity：4/4）；3 个子任务各自 CI 绿 + rebase；console 契约不破。
