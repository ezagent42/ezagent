# CsOrchestrator Kind vs Session + Behavior — 深度对比

> 分析时间: 2026-06-12
> 背景: PR #731 vs autoservice-dev 架构融合决策的前置分析

---

## 三种方案速览

| | A: CsOrchestrator Kind (PR #731) | B: Session + Behavior (中间方案) | C: Plain Session + RuleStore (autoservice-dev 当前) |
|---|---|---|---|
| **核心思路** | 新建独立 Lifecycle Kind 做编排中枢 | 在已有 Session Kind 上注册 CsOrchestrator Behavior | 复用 Session + MentionRouting，无编排层 |
| **进程数** | +1 进程 per customer session | 0 额外进程（复用 Session 进程） | 0 额外进程 |
| **状态位置** | CsOrchestrator 独立 snapshot | Session 的 slice 中 | 无集中编排状态 |

---

## 1. 方案 A: CsOrchestrator Kind (PR #731)

### 架构

```
entity://<ws>/agent/orch-cs-<customer>  (CsOrchestrator Kind, agent-flavor)
    ↓ 持有状态: open_turn_id, operator_active, customer_uri, fast_uri, slow_uri
    ↓ 3 actions: receive / operator_claim / operator_settle

session://<ws>/cs/<customer>  (SocialwareSession Kind)
    ↓ turn.open / turn.compose / turn.settle / turn.claim / turn.cancel
```

### 消息流

```
Customer → chat.send → Session (存储消息)
                    → MentionRouting → CsOrchestrator.receive
                        → TurnDriver.open(session, trigger)
                        → dispatch_after_commit fast_agent (curl.send)
                        → dispatch_after_commit slow_agent (cc.send)

Fast agent reply → bridge → system://chat-reply → CsOrchestrator.send
    → TurnDriver.compose(turn_id, agent_reply)
    → TurnDriver.settle(turn_id)
    → message: customer_visible

Slow agent reply → 同上

Operator takeover:
    OperatorLive → CsOrchestrator.operator_claim
        → TurnDriver.cancel(bot_turn)     # 丢弃 bot 的 in-flight turn
        → TurnDriver.open(fresh)          # 开新 turn
        → TurnDriver.compose(op_text)     # 写 operator 文本
        → TurnDriver.claim(by: op)        # 标记为 operator_only
    OperatorLive → CsOrchestrator.operator_settle
        → TurnDriver.settle → customer_visible
```

### 优势

**1. 进程隔离 — 编排 crash 不影响 Session**
CsOrchestrator 和 Session 是独立进程。编排逻辑崩溃（如 TurnDriver 超时、fan-out 失败）不会影响 Session 的 chat 功能。Session 继续存储消息、管理成员，operator 仍然可以聊天。

**2. 独立生命周期 — 可以单独重启**
CsOrchestrator 挂了，`Workspace.Loader` 或 `after_boot` 可以单独重 spawn，不影响 Session。Session 不需要知道编排逻辑的存在。

**3. 状态语义清晰**
`open_turn_id`、`operator_active`、`fast_uri`、`slow_uri` 这些编排状态在 CsOrchestrator 的 snapshot 中，和 Session 的 chat 状态（消息列表、成员）完全分开。一个 snapshot 只描述一件事。

**4. 符合 ezagent 的 Kind 哲学**
ezagent 的设计鼓励 "一个 Kind = 一个职责"。Session 负责 chat 消息的存储和排序，CsOrchestrator 负责 turn 编排和 agent 协调。各自有独立的 snapshot、ReadyGate、dispatch 入口。

**5. 扩展性 — 未来可以支持多种编排策略**
如果未来有不同类型的 customer service 场景（如纯 bot、bot+human 混合、多 agent 协作），可以创建不同的 orchestrator flavor，不需要改 Session Kind。

### 劣势

**1. 跨 VM 重启 — flavor cache 丢失 (已发现并修复，但方案脆弱)**
这是 PR #731 Live E2E 发现的 #1 bug。`AgentFlavorAttributes` 是 ETS 表（非持久），重启后 flavor tag 丢失 → cold-load resolver 返回 `:none` → dispatch 失败 `:no_such_actor`。修复方案是 `after_boot/0` 从 durable snapshot index 重 hydrated。

**为什么脆弱**: 这个修复依赖插件作者正确实现 `after_boot/0`。框架层面没有保证 "所有 agent-flavor Kind 的 flavor tag 在重启后自动恢复"。FatNine 团队在 PR 中已经 flag 给 Allen：*"generic AgentFlavorAttributes rehydration from the durable slice at boot likely belongs in core"*。

**2. Agent reply 路由需要双 action (已发现并修复)**
PR #731 的 #2 bug: cc bridge 用 `chat.send`（action `:send`）分发 agent reply，但 CsOrchestrator 只声明了 `:receive`。修复是添加 `:send` action。

**为什么容易出错**: 入站消息（customer → orchestrator）走 MentionRouting → `:receive`，agent reply（bridge → orchestrator）走 bridge 的 `dispatch_reply` → `:send`。这是两条不同的分发路径，Behavior 作者必须知道两条路径都存在。一旦遗漏，agent reply 静默丢弃（违反 "no silent failure" 原则）。

**3. 增加进程数 — per-customer 多一个进程**
每个 customer 需要 1 个 Session + 1 个 CsOrchestrator = 2 个进程（不算 fast/slow agents）。对于 1000 个并发 customer，多 1000 个进程。虽然 BEAM 可以承受，但增加了系统整体负载。

**4. 编排逻辑分散在两个 Kind 之间**
CsOrchestrator 持有 `open_turn_id`，但 Turn 本身在 SocialwareSession 上操作。`TurnDriver.open/3` 先 dispatch 到 Session 的 `turn.open`，Session 返回 turn_id，CsOrchestrator 再把它存到自己的状态里。这里有两个 Kind 的协调——如果中间某个 dispatch 失败，需要处理不一致状态。

**5. 引入了 agent-flavor Kind —— 这是 ezagent 框架的新模式**
PR #731 可能是第一个在 plugin 中创建 agent-flavor Kind 的案例。框架对 agent Kind 的支持（cold-load resolver、TemplateClass 实例化）是为 cc/curl agent 设计的，用在 orchestrator 上有些"滥用"的感觉（orchestrator 不是一个 agent，它是一个协调器）。

---

## 2. 方案 B: Session + Behavior (中间方案)

### 架构

```
session://<ws>/cs/<customer>  (SocialwareSession Kind)
    ↓ Chat Behavior: chat.send / chat.join / ...
    ↓ CsOrchestrator Behavior (新增): receive / operator_claim / operator_settle / handle_agent_reply
    ↓ Slice 扩展: open_turn_id, operator_active, fast_uri, slow_uri, customer_uri
```

### 消息流

```
Customer → chat.send → Session (Chat Behavior 存储消息, 发 event)
                    → MentionRouting → Session?action=cs_orchestrator.receive
                        → CsOrchestrator Behavior handler 在 Session 进程中执行
                        → Turn.open(session, trigger)      # 直接操作 Session 自己的 Turn
                        → dispatch_after_commit fast_agent
                        → dispatch_after_commit slow_agent

Fast agent reply → Session?action=cs_orchestrator.handle_agent_reply
    → Behavior handler in Session 进程
    → Turn.compose(turn_id, agent_reply)
    → Turn.settle(turn_id)
    → message: customer_visible

Operator takeover:
    OperatorLive → Session?action=cs_orchestrator.operator_claim
        → Turn.cancel(bot_turn)
        → Turn.open(fresh)
        → Turn.compose(op_text)
        → Turn.claim(by: op)
```

### 优势

**1. 无新 Kind — 零额外进程，零跨 VM 问题**
不需要 `CsOrchestrator` Kind → 不需要 `after_boot` rehydration hack → 不需要 flavor cache → flavor cache 丢失的整个问题域消失。Session Kind 的 snapshot 已经包含所有状态，重启后自动恢复。

**2. 编排和 Turn 在同一进程 — 无协调不一致**
`Turn.open`、`Turn.compose`、`Turn.settle` 都在 Session 进程中执行。CsOrchestrator Behavior handler 调用 Turn 时，不涉及跨 Kind dispatch。不存在 "CsOrchestrator 记录了 turn_id 但 Session 没有对应的 Turn" 这种不一致。

**3. 消息路由简单 — 不需要 :send action**
Agent reply 直接 dispatch 到 `Session?action=cs_orchestrator.handle_agent_reply`，一条路径。不需要区分 `:receive`（customer 入站）和 `:send`（bridge 分发），因为两者都是对同一个 Session Kind 的 dispatch，只是 action 不同。

**4. 符合 ezagent Behavior 设计哲学**
Behavior 就是为了给已有的 Kind 添加领域特定逻辑。`Chat` Behavior 给 Session 加了消息收发，`CsOrchestrator` Behavior 给 Session 加了编排。这和 `ContentAdmin` Behavior 给 Workspace 加内容管理是同一个模式。

**5. 更简单的 cold-load**
Session 的 snapshot 已经包含所有状态（消息、成员、open_turn_id）。Cold-load resolver 只需要解析会话类型为 `SocialwareSession`，不需要额外的 flavor 解析步骤。

**6. 减少一个 URI 命名约定**
不需要 `entity://<ws>/agent/orch-cs-<name>` 这种 URI 格式。OperatorLive 不需要 `derive_orch_and_turn/2` 这种推导函数。

### 劣势

**1. 编排 crash 影响 Session**
这是最大的风险。如果 CsOrchestrator Behavior handler 崩溃（如 TurnDriver 调用超时、fan-out dispatch 抛异常），Session 进程也崩溃 → chat 功能中断 → customer 和 operator 都受影响。

**缓解措施**:
- Behavior handler 内部 try/catch 所有 TurnDriver 调用，失败时 log + 返回 error effect
- fan-out 使用 `dispatch_after_commit`（PR #731 已经做对了：dead agent 不 abort turn commit）
- Session 的 Supervisor 策略设为 `:temporary` 或带有限重试

**2. Session slice 膨胀**
Session 的 slice 当前包含 chat 相关状态（消息 cursor、成员等）。加上编排状态（`open_turn_id`、`operator_active`、`fast_uri`、`slow_uri`）后，slice 变大，snapshot 频率增加。

**缓解措施**: 编排状态很小（几个 URI + turn_id + boolean），几乎不会显著增加 snapshot 大小。

**3. 编排逻辑和 Chat 逻辑耦合在同一模块的 slice 中**
从代码组织角度看，Session 的 slice 结构体需要包含 `cs_orchestrator` 字段。虽然 Behavior 代码是独立的（`Ezagent.Behavior.CsOrchestrator`），但运行时状态耦合在同一个 slice 里。

**缓解措施**: slice 用 nested map 组织：`%{chat: %{...}, cs_orchestrator: %{open_turn_id: ..., operator_active: ...}}`。不同 Behavior 读写自己 namespace 下的 key。

**4. 不如方案 A 的进程隔离干净**
如果未来需要支持 "一个 session 有多个并发的 turn 由不同 orchestrator 管理"（多 agent 并行处理同一 customer 消息），方案 A 可以 spawn 多个 CsOrchestrator，方案 B 需要在 Session 内管理并发（难）。

**评估**: 这个场景在当前 v2 scope 中不存在，且可以用其他方式解决（如一个 turn 多个 agent result_refs）。

---

## 3. 方案 C: Plain Session + RuleStore (autoservice-dev 当前)

### 消息流

```
Customer → chat.send → Session (Chat Behavior)
                    → MentionRouting → fast_agent (curl.send)
                                    → slow_agent (cc.send)

Agent reply → chat.send → Session → PubSub chat_message → CustomerLive 渲染

Operator takeover:
    OperatorLive → RuleStore.disable(session_routing_rule)  # 停止 AI fan-out
    OperatorLive → chat.send (operator 直接发消息)
    OperatorLive → RuleStore.enable(session_routing_rule)   # 恢复 AI fan-out
```

### 优势

- 最简单 — 无编排层，完全复用平台能力
- 无跨 VM 问题
- 无额外进程

### 劣势

- 无显式 Turn 生命周期 — agent reply 不走 compose/settle
- Operator 接管是粗糙的开关（整个规则 enable/disable）
- 无双相(biphasic)支持
- 无法区分 "bot 正在处理中" vs "bot 已完成回复"
- 无法实现 "operator 看了 bot draft 后决定发送/修改/丢弃"

---

## 4. 关键维度矩阵对比

| 维度 | A: CsOrchestrator Kind | B: Session + Behavior | C: Plain Session + RuleStore |
|---|---|---|---|
| **进程隔离** | ✅ 强隔离 | ❌ 共享进程 | N/A (无编排层) |
| **跨 VM 重启** | ❌ flavor cache hack | ✅ 天然支持 | ✅ 天然支持 |
| **Agent reply 路由** | ⚠️ 双路径 (:receive + :send) | ✅ 单路径 | ✅ PubSub (但无 turn) |
| **Turn 一致性** | ⚠️ 跨 Kind 协调 | ✅ 同进程 | ❌ 无 turn |
| **Operator 接管粒度** | ✅ cancel+reopen | ✅ cancel+reopen | ❌ RuleStore toggle |
| **双相支持** | ✅ 显式 | ✅ 显式 | ❌ 不支持 |
| **进程数 (per customer)** | 2 | 1 | 1 |
| **符合框架惯例** | ⚠️ agent-flavor 的"滥用" | ✅ Behavior 模式成熟 | ✅ 当前实践 |
| **扩展性 (多策略)** | ✅ 多 flavor | ⚠️ 需改 Behavior | ❌ 无编排抽象 |
| **代码量** | ~569 + 44 + 138 = ~751 行 | 估计 ~400 行 (少 TurnDriver 跨 Kind dispatch) | ~511 行 (CustomerSession) |
| **测试复杂度** | 高 (两个 Kind 的集成) | 中 (Behavior 单元 + Session 集成) | 低 |
| **P22 合规** | ✅ 独立 ReadyGate | ✅ 复用 Session ReadyGate | ✅ 复用 Session ReadyGate |
| **P14 合规** | ✅ dispatch 路径 | ✅ dispatch 路径 | ✅ dispatch 路径 |

---

## 5. 关键风险场景分析

### 场景 1: Fast agent 不存在 / 未 provision

| | A: CsOrchestrator Kind | B: Session + Behavior | C: Plain Session + RuleStore |
|---|---|---|---|
| **行为** | `dispatch_after_commit` 失败，log，不 abort | 同 A | MentionRouting 无匹配 receiver，消息进 DLQ |
| **影响** | 只有 fast ACK 缺失，slow reply 继续 | 同 A | 整个 fan-out 失败 |
| **恢复** | provision fast agent，下一次消息触发新的 fan-out | 同 A | 需要重新触发路由 |

### 场景 2: CsOrchestrator / Session 进程 crash

| | A: CsOrchestrator Kind | B: Session + Behavior |
|---|---|---|
| **Orchestrator crash** | Session 不受影响，customer/operator 仍可聊天。Orchestrator 被 Supervisor 重启，从 snapshot 恢复 `open_turn_id`（但 Turn 可能已过期） | Session crash → chat 中断，customer/operator 都受影响。Supervisor 重启 Session，从 snapshot 恢复所有状态 |
| **Session crash** | Chat 中断。Orchestrator 的 `open_turn_id` 指向一个可能已被 reset 的 Turn | N/A (同一个进程) |
| **恢复后不一致** | Orchestrator 的 `open_turn_id` 对应一个不存在的 Turn → 下次 compose/settle 失败 → log + self-heal | 状态在同一个 snapshot 中，原子恢复 |

### 场景 3: 慢速 cc agent 超时

| | A: CsOrchestrator Kind | B: Session + Behavior | C: Plain Session + RuleStore |
|---|---|---|---|
| **行为** | Orchestrator 的 fan-out 已经发出，cc 超时后 bridge 返回 error。Orchestrator 的 turn 停留在 `:open` 或 `:composing` | 同 A，但 handler 可以设 timer 做超时处理 | cc 超时，无 turn 状态可查 |
| **超时恢复** | 需要额外的超时检测机制（当前 PR 没有） | 可以利用 Session 进程的 timer | N/A |

---

## 6. 推荐

### 短期（v2 发布）: 方案 B — Session + Behavior

**理由**:

1. **解决 PR #731 最头疼的两个 bug 的根因**: flavor cache 丢失和 agent reply 双路径问题，在方案 B 中根本不存在。

2. **符合 ezagent 现有模式**: ContentAdmin 已经证明 "给已有 Kind 注 Behavior" 是成熟且被验证的模式。CsOrchestrator 是同一个模式应用在 Session Kind 上。

3. **代码量更少、更简单**: 不需要 TurnDriver 做跨 Kind dispatch（Turn 在 Session 进程内直接调用），不需要 CsOrchestrator entity 定义，不需要 after_boot rehydration。

4. **保留 PR #731 的核心价值**: cancel+reopen operator takeover、dispatch_after_commit fan-out、biphasic 双相模式都可以在 Behavior 中实现。

5. **运维更简单**: 少一个 Kind 类型、少一个 URI 命名约定、少一个 after_boot hook。

### 实施路径

1. 从 PR #731 提取 CsOrchestrator 的编排逻辑（handle_receive、handle_operator_claim、handle_operator_settle）
2. 改写为 `Ezagent.Behavior.CsOrchestrator`，注册在 SocialwareSession Kind
3. Turn 操作直接调用 Session 内部的 Turn 函数（不经过 dispatch）
4. Fan-out 使用 `{:dispatch_after_commit, cmd}` effect（保留 PR #731 的做法）
5. 状态存储在 Session slice 的 `cs_orchestrator` namespace 下
6. 保留 autoservice-dev 的 content plugin Behavior 层和深层分层结构

### 长期（框架演进）: 向 Allen 提两个 framework-level 改进

1. **AgentFlavorAttributes 持久化**: 当前 ETS 表在重启后丢失，任何 agent-flavor Kind（包括 cc/curl agent）都受影响。应该在 core 层面从 durable snapshot 自动恢复。

2. **Kind 间 Turn 协调**: 如果未来确实需要独立 Kind 做编排（方案 A），框架应该提供 "Turn 所有权" 概念，让 orchestrator 能安全地跨 Kind 管理 Turn 生命周期，避免不一致状态。
