# Handoff — A: 配置统一 → domain.agent（allenwoods）

> 三条并行子任务之一（见主文档 `allenwoods-agent-runtime-consolidation-plan.md`）。Allen 会对本 handoff 走 brainstorm 完善。

## 目标
所有 agent flavor（cc/codex/curl/echo）的 **config + behaviors 都从存储的 flavor 统一解析**，收拢到 `domain.agent` 的统一入口 + 注册器。消除"spawn 时 thread behaviors"的特例。

## 背景（现状）
- `Entity.Agent.behaviors/0 = base ++ [CurlAgent, CcHeadlessAgent]`（Kind 声明的超集）。
- **只有 curl 在 spawn 时 thread 一个缩减集 `curl_behaviors`**（`entity/agent.ex:121`）；cc/codex 用 Kind 默认；echo（#918）照抄 curl 去 thread `echo_behaviors`。
- config 后端 = `Ezagent.AgentConfig` facade（cap-gated，#938/#943/#966）。

## 设计（待 brainstorm 定稿）
1. **Entity.Agent 在 init 从存储 flavor 统一解析 behaviors**：spawn 只给 URI；`Entity.Agent` 读自己的 flavor（stored attr，经 UriQuery）→ 解析该 flavor 的 behavior 集。**curl 的 spawn-thread 重构成同一机制**（不再特例）。→ 这同时让 LocalRuntime 保持 URL-only（C 受益）。
2. **echo 接入**（吸收 #918）：echo 作为 `Entity.Agent` 的一个 flavor case，flavor=echo → 解析 echo behaviors（含 Behavior.Echo + Identity + ConfigEvolve）→ echo 自动获得 config。
3. **config 入口收拢到 domain.agent**：保持 `Ezagent.AgentConfig` facade 签名稳定（console 契约，见主文档），domain.agent 成为统一实现/注册器。

## DoD（四性质）
- [ ] **parity 4/4**：cc/codex/curl/echo 都经"从 flavor 统一解析"拿到 behaviors（无 spawn-thread 特例）—— 给出 4 flavor 的解析对照。
- [ ] **echo 有 config**：echo agent 能读/改 config（解 #958 echo 配不了）—— 测试证明。
- [ ] **console 契约不破**：`AgentConfig` facade 签名不变（或改了先通知 gaga）。
- [ ] **回归**：flavor→behaviors 解析的单测 + 全量 mix test 绿；CI 绿 + rebase。

## 关键文件
- `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex`（behaviors 解析）+ `entity/agent/template_spawn.ex`
- flavor 解析：`agent_flavor_registry` / UriQuery
- config facade（保持契约）：`apps/ezagent_domain_identity/lib/ezagent/agent_config.ex`
- echo：吸收 `#918`（`agent-contract-echo-soul` 分支）的 echo→Entity.Agent 逻辑

## 冲突点
- 与 C 已解耦（behaviors 不 spawn-thread）。
- 与 gaga console = facade 契约（主文档），不破签名。
- echo 逻辑来自 FatNine 的 #918（今日休息）—— 吸收其逻辑，无并发写。

## 必读
skill `ezagent-developer`；主文档；`#918` 的现有实现；dev-together（四性质 DoD / clarify / rebase）。
