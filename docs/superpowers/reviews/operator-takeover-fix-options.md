# Operator 接管修正: 最小修正 vs Behavior 方案

> 分析时间: 2026-06-12
> 背景: autoservice-dev 的 operator 接管用 synthetic turn_id (`:erlang.unique_integer`)，对应不到真实 Turn → Turn.claim/settle 的 visibility 门控实际失效。两个修正方向分析如下。

---

## 1. 问题定位

**当前 autoservice-dev `OperatorLive` 的 claim handler**:

```elixir
# apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/operator_live.ex:102
turn_id = :erlang.unique_integer([:positive])
_ = TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri: op_uri})
```

`turn_id` 是随机整数（如 12345），dispatch 到 `session?action=turn.claim` → Session 的 Turn Behavior 查找 `turn_id` → **找不到对应的 Turn** → 返回 error 或 no-op。Turn 的 `visibility: operator_only` 门控从未生效。

**连锁影响**: operator 的草稿消息和最终提交在 CustomerFeed 层面没有区别 → customer 总是立刻看到 operator 正在输入的内容。

---

## 2. 方案 A: 最小修正 (不引入 Behavior)

### 思路

保持 autoservice-dev 现有架构不变，**只修复 OperatorLive 的 Turn 使用方式**，让 operator 接管走真实的 Turn 生命周期。

### Operator 接管流程 (修正后)

```
1. Operator 点击 "接管"
   → 取 session 最近一条 customer 消息 (MessageStore.recent_in_session)
   → TurnAdapter.open_turn(session_uri, %{customer_uri, text: latest_msg})
   → 拿到真实 turn_id
   → TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri})  ← 生效!
   → visibility: operator_only
   → (可选) RuleStore.disable 暂停 AI 路由

2. Operator 输入回复
   → TurnAdapter.compose_turn(session_uri, turn_id, %{agent_uri: op, text: reply})

3. Operator 点击 "提交"
   → TurnAdapter.settle_turn(session_uri, turn_id)
   → visibility: customer_visible
   → (可选) RuleStore.enable 恢复 AI 路由
```

### 需要的代码改动

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/operator_live.ex:
  - handle_event("claim"): synthetic turn_id → 读最新 customer msg + TurnAdapter.open_turn
  - handle_event("settle"): synthetic turn_id → 使用真实 turn_id，compose 后再 settle
  - handle_event("send"): operator 消息走 TurnAdapter.compose_turn 而非 chat.send
  - 新增 tracking: @open_turn_id 记录当前 turn
  - 新增 handle_event("cancel"): operator 放弃接管 → TurnAdapter.cancel_turn (需新增)

apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_adapter.ex:
  + cancel_turn/2 (新增 action)
```

### 架构不变的部分

```
Customer 消息流 (不变):
  Customer → chat.send → MentionRouting → fast agent
                                        → slow agent
  
Agent 回复流 (不变):
  Agent reply → chat.send → PubSub → CustomerLive
  
Turn 使用范围: 仅 operator 接管时
  - customer-bot 交互不走 Turn (直接 chat.send)
  - 只有 operator 接管创建一个真实的 Turn
```

### 优势

1. **最小改动** — ~50 行代码，只改 OperatorLive + 一个 TurnAdapter 函数
2. **不引入新抽象** — 没有新模块、新 Behavior、新 Kind
3. **风险最低** — customer-bot 交互完全不碰，不会引入回归
4. **Turn visibility 门控真正生效** — operator 草稿在 settle 前 customer 不可见
5. **RuleStore.disable/enable 可选** — Turn.claim 已经提供 visibility gating，RuleStore.disable 可以作为额外保险（防止 AI 在 operator 编辑时插入新消息）
6. **与 PR #715 验证过的 TurnAdapter 模式一致** — Stage-1 已经证明 TurnAdapter + Invocation.dispatch 可行

### 劣势

1. **Turn 使用不一致** — bot 回复走 chat.send (无 Turn)，operator 回复走 Turn。两个路径的消息生命周期不同，未来调试可能有困惑
2. **operator 接管依赖"最近一条 customer 消息"** — 如果 session 刚创建还没有消息，`TurnAdapter.open_turn` 没有 trigger。需要 fallback: 用空消息或系统消息作为 trigger
3. **无 biphasic 显式建模** — fast/slow agent 仍是独立的 MentionRouting 分发，没有协调。但这不影响功能（fast 先到先显示）
4. **如果未来需要 operator 审核 bot 草稿** — 当前 bot 回复不创建 Turn，operator 无法在 Turn 中找到 bot 的部分内容并修改。需要升级到方案 B

### 边界场景

| 场景 | 处理 |
|---|---|
| Session 无 customer 消息时接管 | 用系统消息 `"operator 主动发起对话"` 作为 trigger |
| Operator 接管后 customer 发新消息 | 新消息触发新的 Turn（自动）或由 operator 手动创建 |
| Operator 中途取消接管 | TurnAdapter.cancel_turn → visibility 在原状态，不投递 customer |

---

## 3. 方案 B: CsOrchestrator Behavior

### 思路

引入 `CsOrchestrator` Behavior (注册在 SocialwareSession Kind)，统一所有消息的 Turn 管理。Customer 消息和 operator 消息都走同一个编排层。

### 架构

```
Customer 消息流 (改动):
  Customer → chat.send → MentionRouting → session?action=cs_orchestrator.receive
    → Behavior handler: Turn.open → dispatch_after_commit fast + slow
       
Agent 回复流 (改动):
  Agent reply → session?action=cs_orchestrator.receive
    → Behavior handler: Turn.compose → Turn.settle → customer_visible

Operator 接管流 (改动):
  Operator → session?action=cs_orchestrator.operator_claim
    → Behavior handler: Turn.cancel(bot_turn) → Turn.open → Turn.compose → Turn.claim
  Operator → session?action=cs_orchestrator.operator_settle
    → Behavior handler: Turn.settle → customer_visible
```

### 需要的代码改动

```
新增 (~400 lines):
  apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex  (~250 lines)
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_driver.ex (~100 lines)

改动:
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/application.ex (+ behaviors/0)
  apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/autoservice_assembly.ex (routing 规则)
  apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/operator_live.ex (dispatch 目标改为 orchestrator)
  apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/customer_live.ex (minor)

新增测试 (~500 lines):
  test/ezagent_plugin_autoservice/cs_orchestrator_test.exs (~300 lines)
  test/ezagent_plugin_autoservice/turn_driver_test.exs (~150 lines)
```

### 优势

1. **Turn 使用一致** — 所有消息 (customer/bot/operator) 都走 Turn 生命周期。状态模型统一
2. **biphasic 显式建模** — fast ACK 是独立 quick turn，slow reply 是独立 turn。orchestrator 持有 open_turn_id 协调
3. **cancel+reopen 接管模式** — operator 接管时 cancel bot 的 in-flight turn，operator 拿到全新的 clean turn。比 RuleStore.disable 更精细
4. **bot draft 可审核** (未来) — bot compose 后不自动 settle，operator 可以先看 draft 再决定发送/修改/丢弃
5. **CustomerFeed 门控覆盖全部消息** — 所有消息 settle 后才投递，visibility 由 Turn 状态决定
6. **状态可观测** — orchestrator slice 中有 `open_turn_id`、`operator_active`，OperatorLive 可以查询"bot 正在回复中?"

### 劣势

1. **代码量大** — ~400 行新代码 + ~500 行测试
2. **架构复杂度提升** — 新增 Behavior 模块 + TurnDriver 模块。团队需要理解编排层
3. **Agent reply 路由改变** — 从 `chat.send → PubSub` 改为 `session?action=cs_orchestrator.receive`。bridge 配置或路由规则需要调整
4. **Behavior crash 风险** — 编排逻辑在 Session 进程内执行，crash 会影响 Session 的 chat 功能（缓解: try/catch + `dispatch_after_commit` 不 abort turn）
5. **调试复杂度** — 消息流经过 Behavior handler，不再是简单的 `chat.send → PubSub → LV`
6. **可能过度设计** — 对于 "customer 问 → bot 答" 的简单场景，Turn 生命周期增加了不必要的步骤

---

## 4. 维度对比

| 维度 | A: 最小修正 | B: CsOrchestrator Behavior |
|---|---|---|
| **代码量** | ~50 行改动 | ~400 行新增 + ~200 行改动 |
| **新模块** | 0 | 2 (CsOrchestrator Behavior + TurnDriver) |
| **架构一致性** | ⚠️ Turn 仅用于 operator | ✅ Turn 用于所有消息 |
| **operator 接管质量** | ✅ Turn.open → claim → compose → settle | ✅ cancel+reopen → open → compose → claim → settle |
| **RuleStore 依赖** | 可选 (额外保险) | 不需要 (orchestrator_active 抑制 fan-out) |
| **biphasic 显式支持** | ❌ fast/slow 独立运行 | ✅ orchestrator 协调 |
| **bot draft 审核** | ❌ bot 回复不走 Turn | ✅ 可扩展 (compose 后不自动 settle) |
| **CustomerFeed 门控** | ⚠️ 仅 operator 消息 | ✅ 全部消息 |
| **回归风险** | 低 (不碰 customer-bot 流) | 中 (agent reply 路由改变) |
| **调试难度** | 低 (简单路径) | 中 (消息经过 Behavior handler) |
| **未来升级到方案 B** | 需要重写 operator 接管部分 | N/A |
| **适用场景** | v2 MVP：快速交付，operator 接管正确工作 | v2 完整版：审核流程、biphasic、全 Turn 生命周期 |

---

## 5. 推荐

### 短期 (v2 当前): 方案 A — 最小修正

**理由**:
- autoservice-dev 的 customer-bot 交互已经工作（chat.send + MentionRouting + PubSub），不需要为了 "架构一致性" 去重写
- 唯一需要修复的是 operator 接管的 Turn visibility 门控，方案 A 正好解决这个问题
- 不碰 customer-bot 路径 = 零回归风险
- 如果后续需要 bot draft 审核、biphasic 协调等高级功能，可以从方案 A 升级到方案 B。升级路径清晰: 引入 CsOrchestrator Behavior → 逐步将 customer 消息和 agent reply 迁移到 Behavior → 最终移除 RuleStore.disable

**具体改动**:
1. `OperatorLive`: synthetic turn_id → `TurnAdapter.open_turn` + 真实 turn_id
2. `TurnAdapter`: 新增 `cancel_turn/2`
3. Operator 消息走 `TurnAdapter.compose_turn` 而非 `chat.send`
4. RuleStore.disable/enable 保留作为额外保险（可选）

### 中期 (v2 迭代): 评估是否需要方案 B

触发条件（满足任一即考虑升级）:
- 需要 bot draft 审核（AI 生成回复 → operator 审核 → 发送/修改）
- biphasic 需要协调（fast ACK 和 slow reply 之间有依赖）
- 需要 Turn 超时管理（cc agent > 2min → 自动 fallback）
- 多 agent 并行处理同一 customer 消息

---

## 6. 方案 A 实施要点

```elixir
# OperatorLive 修改后的 claim handler (伪代码)
def handle_event("claim", _params, socket) do
  session_uri = socket.assigns.selected
  op_uri = socket.assigns.operator_uri

  # 1. 找到 trigger: 最近一条 customer 消息，或 fallback
  trigger = get_latest_customer_message(session_uri) || fallback_trigger(op_uri)

  # 2. 创建真实 Turn
  {:ok, turn_id} = TurnAdapter.open_turn(session_uri, trigger)

  # 3. Claim Turn (visibility → operator_only)
  :ok = TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri: op_uri})

  # 4. (可选) 暂停 AI fan-out
  disable_session_rule(session_uri)

  {:noreply, assign(socket, open_turn_id: turn_id, claimed: true)}
end

def handle_event("send", %{"text" => text}, socket) do
  # Operator 回复走 Turn.compose，不是 chat.send
  :ok = TurnAdapter.compose_turn(
    socket.assigns.selected,
    socket.assigns.open_turn_id,
    %{agent_uri: socket.assigns.operator_uri, text: text}
  )
  {:noreply, socket}
end

def handle_event("settle", _params, socket) do
  # Settle Turn (visibility → customer_visible)
  :ok = TurnAdapter.settle_turn(socket.assigns.selected, socket.assigns.open_turn_id)

  # (可选) 恢复 AI fan-out
  enable_session_rule(socket.assigns.selected)

  {:noreply, assign(socket, claimed: false, open_turn_id: nil)}
end
```

**关键**: `get_latest_customer_message/1` 从 `MessageStore.recent_in_session` 取最近一条 sender != operator 的消息作为 Turn trigger。无消息时用 fallback（系统触发消息）。
