# AutoService Phase B — Customer 路径(loom-defer)设计

> 从 `2026-06-10-autoservice-v2-design.md` 切出的**可执行 slice**:把 Stage-1(PR #715)已证明的 customer→bot→reply E2E **重构到 v2 结构**(content plugin + orchestrator Behavior),并加 **biphasic(fast 即时 ACK + slow 主回复)**。单租户 cinnox、customer-only、loom-defer(编排在 autoservice,不在 loom)。

## 0. Scope / Non-goals

**In scope**
- 在 `autoservice` 基上,跑通**单租户 cinnox 的 biphasic customer E2E**:fast curl 即时安抚 ACK + slow cc soul 驱动主回复,经 socialware `Behavior.Turn` + `CustomerFeed` 门控。
- 新建 `ezagent_plugin_content`(soul 渲染 template+slot + skill indexer + agent 配置供给)。
- 新建 autoservice **orchestrator Behavior**(dispatch + effects 驱动 Turn,取代 Stage-1 的 observe-GenServer)。
- 复用 Stage-1 已证明逻辑(relocate),复用已存在的 `ezagent_plugin_curl_agent`(fast)+ cc(slow)+ `ezagent_plugin_liveview`(CustomerLive)。

**Non-goals(明确推迟)**
operator 接管(Turn.claim/settle + `RuleStore.disable` + operator 控制台)/ 多租户 / CR 发布(`ezagent_plugin_cr`)/ KB-management(KB 用现有 MCP)/ soul self-evolve(#17 cascade)/ 真 loom 前端 / G1-a proper fix(creation-unification;本 slice 用 ambient-token workaround on Linux)。

## 1. Context + 与 Stage-1(#715)的关系

- **基座**:`origin/autoservice`(含 v2 设计 + `curl_agent`/`liveview` 插件;**无** `content`/`cr` 插件;**无** Stage-1 代码)。
- **#715 = 复用逻辑、不合代码、留作参考**:Stage-1 的 `SocialwareCSTurnAdapter` / `cinnox_assets` / `customer_live` / `SocialwareCS` provision 的**逻辑被 relocate** 到 v2 结构;#715 本身留作 Stage-1 proof + demo + findings(`docs/notes/2026-06-10-stage1-live-findings.md`),不按原样 merge。cinnox 的 soul/skill 资产从 #715 搬进 content plugin。
- **cc-runtime 依赖**:**#723**(claude 2.1.170 MCP-trust + bypass auto-prompt → bot 才 JOIN)+ **#730**(per-template model/effort/endpoint from `template_data`)。本 slice 的 live E2E 依赖这两个合入(或本地带上)。

## 2. 组件地图 + plugin 边界

```
ezagent_plugin_content (新)          ← 无 domain/core 内部依赖(只读 FS + ConfigStore)
   ↑
ezagent_plugin_autoservice (建 orchestrator Behavior + assembly)
   ├─ content(provision_context)、socialware(Behavior.Turn / CustomerFeed)
   ├─ curl_agent(fast)、cc(slow)
ezagent_plugin_liveview (扩展)        ← CustomerLive on CustomerFeed
```

| plugin | 模块 | 职责 | 来源 |
|---|---|---|---|
| **content**(新) | `TenantContent.provision_context/2` | 给 `(tid, role)` 返回:渲染 CLAUDE.md(slow)/ system_prompt(fast)/ agent 配置(model/effort/endpoint)/ work_dir / mcp 配置 | 新建 |
| | `SoulRenderer` | L0–L3 soul 模板(`{{key}}`)+ slot_values → 渲染;缺 key 保留 `{{key}}`(未配置信号) | 新建(逻辑参考 #715 `render_soul`) |
| | `SkillIndexer` | 扫 `skills/` → Skill Index markdown(soul 引用) | 新建 |
| | `priv/skeleton/`(soul 模板 / slots / skills / `agents.yaml`) | cinnox 资产;`agents.yaml` master-only、不进 sandbox | **从 #715 `cinnox_assets` + `priv/cinnox` 搬** |
| **autoservice** | **orchestrator Behavior**(per-session Kind) | dispatch 收客户消息 + agent 回复 → effects 驱动 Turn(见 §4.B) | **新建(逻辑取自 #715 adapter)** |
| | `autoservice_assembly` | `provision_session` = content.provision_context + create_agents + install_routing | relocate #715 `SocialwareCS` provision |
| | seed task(cinnox) | 起 cinnox 租户 + customer alice | relocate #715 seed |
| **curl_agent**(已有) | — | fast deepseek ACK | 仅配置 + 编排 |
| **cc**(已有 +#723/#730) | — | slow 主回复(model/effort/endpoint 经 template_data) | 仅配置 |
| **liveview**(扩展) | `CustomerLive` | 客户聊天面,源 = `CustomerFeed`(含乐观回显 + "AI 客服" label) | relocate #715 `customer_live` |

**三层纪律**:content 不读 domain/core 内部;autoservice 不直接读 `agents.yaml`(由 content 映射进 `template_data` → cc 的 #730 读)。

## 3. 数据流 A — Provision(seed / assembly)

```
assembly.provision_session(cinnox, alice):
 1. content.provision_context(cinnox, "slow")
      SoulRenderer(L0–L3 + slot_values) → soul;SkillIndexer(skills/) → index
      → CLAUDE.md = preamble + soul + index;agent 配置 = agents.yaml.slow(model/effort/endpoint)
 2. content.provision_context(cinnox, "fast")
      → system_prompt;agent 配置 = agents.yaml.fast(deepseek model/endpoint/no-thinking/max_tokens)
 3. create_agents:slow = cc(写 CLAUDE.md;model/effort/endpoint 进 template_data → #730 读)
                   fast = curl_agent(system_prompt + deepseek 配置)
 4. install_routing:rule(in_session)→ 投递 orchestrator(见 §4.B 的路由模型)
 5. ensure SocialwareSession + join alice
```

## 4. 数据流 B — 运行时编排(核心,原生 dispatch + effects)

### 4.0 原则(为什么不是 observe-GenServer)
`Behavior.Turn` 是 dispatched(action + `handle_*` 返回 effects),substrate **不自动开 turn**。Stage-1 用 GenServer + `PubSub.subscribe(Chat.session_events_topic)` 观察消息驱动 turn —— **fire-and-forget,进程重启时事件丢失(违 P22 no-silent-drop)**。本 slice 改为**原生 dispatch**:编排者是一个 **Lifecycle Kind**,**消息经 routing dispatch 给它**,它用 **effects** 驱动 Turn。P14 合规、P22 可靠(走 ReadyGate/PendingDelivery)。

> **开发层契约(2026-05-29 起)= `use Ezagent.Lifecycle`,不是 `use Ezagent.Behavior`**(后者已 supersede,`mix ezagent.check_invariants.lifecycle` CI 硬门控禁开发层直接用)。形状:`create/1`(首次建持久 `state`)+ `activate/2`(每次进程起——fresh/restart/cold-load——重建 `transients`,`{:ok, transients}`)+ `handle_<action>(args, ctx) → {:ok, result, [effect]}` + `handle_signal/2`(非 action 消息)。effects:`:set`(持久)/`:set_transient`(易失,永不快照)/`:dispatch`(`%Ezagent.Cmd{}` 跨 Kind)/`:emit`。orchestrator 的 current turn_id 放 `state`(durable),无 transients。

### 4.1 路由模型(B1,已定)
**routing 把 session 内所有消息(客户 + agent 回复)dispatch 给 orchestrator Kind**;orchestrator **显式 dispatch** fast/slow(effects),agent 回复再路由回 orchestrator。orchestrator 是唯一 hub。后续 operator 接管时,**暂停 fast/slow = orchestrator 不再派发**(具体机制——orchestrator 内门控 vs 禁用"→orchestrator"输入路由——留 operator phase 定;注意:v2 §7.2 的 `RuleStore.disable` 假设"路由直达 agent",与本 slice 的"路由到 orchestrator"模型不同,operator phase 需重新对齐)。本 slice 不实现 operator。

### 4.2 编排序列
```
1. 客户发 → CustomerLive dispatch chat.send → SocialwareSession 存 → routing → orchestrator(chat.receive)
2. orchestrator.handle_receive(客户消息) → effects:
     [ {:dispatch, Turn.open(trigger=客户消息)},      ← H2:先开 turn(agent 失败 operator 也见)
       {:dispatch, fast 收客户消息},
       {:dispatch, slow 收客户消息} ]
3. fast curl 即时 deepseek ACK → 回复路由回 orchestrator
     orchestrator.handle_receive(fast 回复) → effects:
       [ 独立快速 Turn:open→compose(ACK)→settle ]  ← B2:ACK 自成快速 turn,立即 customer_visible
4. slow cc 读 soul/skill/KB → 主回复(经 esr-bridge)→ 路由回 orchestrator
     orchestrator.handle_receive(slow 回复) → effects:
       [ {:dispatch, Turn.compose(主回复)}, {:dispatch, Turn.settle} ] ← committed customer_visible
5. CustomerFeed {:customer_delivery} → CustomerLive snapshot → 渲染 客户消息 + ACK + 主回复
```

### 4.3 待钉细节
- **orchestrator 打包(已定)**:**独立 autoservice orchestrator Kind(per session)**,routing → 它(层干净、可靠 dispatch)。实现细节待验证:per-session Kind 的生命周期(随 SocialwareSession 起落 + 重水化)。
- **sender 分类**:orchestrator 用 sender(customer `…/user/…` vs agent `…/agent/…`)区分"客户消息 / fast 回复 / slow 回复"。
- **coalesce**:先假设 slow cc 经 reply 工具是**一条回复**(无需 coalesce);若实测多段,再在 Behavior 内加。

## 5. Done 条件(验收)

单租户 cinnox 的 **biphasic customer E2E** 跑在 v2 结构上:alice 登录 `/autoservice` 发消息 → orchestrator Behavior(routing 收到)→ Turn.open → 派 fast+slow → **fast 即时 ACK 立刻 customer_visible** → **slow cc 读 content 供的 soul/skill/KB → 主回复 → compose/settle → customer_visible** → CustomerLive 显示 客户消息 + ACK + 主回复。

结构证明:① content plugin 渲染 soul(template+slot)+ skill index + agent 配置;② 编排是 Behavior(dispatch+effects),非 observe;③ model/effort/endpoint 经 `template_data`(#730);④ 无跨 Kind PubSub 广播(P14)。

## 6. 测试

- **单元**:`SoulRenderer`(template+slot;缺 key→`{{key}}`)、`SkillIndexer`、orchestrator Behavior `handle_*`(给客户消息/agent 回复 → 正确 effects)、`agents.yaml → template_data` 映射。
- **集成**:`provision_context` 产物正确;orchestrator Behavior 用 mock agent 回复驱动一条完整 Turn(compose/settle → customer_visible);复用 substrate 的 Turn/CustomerFeed 测试范式。
- **Live E2E(demo 级)**:真 stack 完整 biphasic(即时 ACK + soul 驱动主回复),录像(扩展 `recording-demo-videos` skill)。**依赖 #723 + #730。**

## 7. 依赖 + 风险

- **依赖**:#723(bot JOIN)、#730(model/effort/endpoint)、`curl_agent`/`liveview`(已存在)、autoservice 基。
- **风险**:① orchestrator-as-Kind 的 per-session 生命周期(随 session 起落 + 重水化)需验证;② fast/slow 并发到达 + ACK 快速 turn 与主 turn 不互相阻塞;③ Linux-only 凭证(macOS 本地仍需 ambient-token workaround)。
