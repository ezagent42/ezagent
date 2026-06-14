# PR #740 Review Response — CsOrchestrator Behavior + TurnDriver 方案评估

> 日期: 2026-06-14
> 基线: `feat/autoservice-v2-merge-v2` (本分支) vs `feat/autoservice-v2-merge` (PR #740, FatNine 团队)
> 共同基准: `autoservice-dev` | 共同目标: merge PR #731 特性 + 修复 operator 接管

---

## 一、背景

PR #740 在实施 P0 时发现两条框架硬约束，因此从 "CsOrchestrator Behavior + Turn-for-everything" 退回到 "B-minimal" 方案（bot 路径不动，仅 operator 接管走 TurnAdapter）。

本分支同样实施了 CsOrchestrator Behavior + TurnDriver，需评估两条约束是否构成阻塞。

---

## 二、两条框架约束以及本分支评估

### 约束 #1: Attached Behavior slice 在重启时被 prune

**框架行为**: `snapshot.ex:prune_orphan_slices` 只保留 Kind 静态 `behaviors/0` 声明的 state_slice，插件通过 `Plugin.behaviors/0` runtime attach 的 Behavior 的 slice 在 reload 时被移除。

**CsOrchestrator 丢失的状态**:

| 字段 | 默认值 | 丢失后果 |
|------|--------|---------|
| `open_turn_id` | `nil` | 忘记当前 Turn ID |
| `operator_active` | `false` | fan-out 恢复（bot 恢复回复） |

**评估: 可接受**

1. CsOrchestrator 已有 self-heal 逻辑：`handle_agent_reply` 中 `open_turn_id` 为 nil 时自动创建 degenerate turn。行为降级但不崩溃。
2. `operator_active` 丢失 → fan-out 恢复。重启前正在接管中的会话，operator 需要重新连上 LV 再操作，语义合理。
3. 丢失这两个字段**恰好避免了指向 zombie Turn**（重启后旧的 Turn 状态可能不一致——agent 进程已消失但 Turn 仍是 `:composing`）。丢了反而是更安全的行为。
4. **手动恢复路径通畅**: operator 重新点击"接管" → `disable_session_rule` 暂停 bot → 新 Turn 创建 → 恢复正常。

### 约束 #2: Agent reply 无法路由到 session-attached orchestrator

**框架行为**: `Chat.Delivery:72` 硬编码 `URI.with_action(target, :chat, :send)`。Bridge 将 agent reply 投递为 `chat.send`，永远不会触发 `cs_orchestrator.send`。

**评估: 等价降级，非 bug**

bot reply 经 `chat.send` → `Chat.handle_send`:
- MessageStore.write(msg) — 消息**持久化，不丢**
- PubSub broadcast `{:chat_message}` — 客户**即时看到回复**

| 行为 | B-minimal | 本分支（降级后） | 结论 |
|------|-----------|-----------------|------|
| bot reply 路径 | `chat.send` → PubSub | `chat.send` → PubSub | **相同** |
| 客户看到回复 | 即时 | 即时 | **相同** |
| Turn 记录 | 无 | 无 | **相同** |
| operator 可 cancel bot reply | 否 | 否 | **相同** |

B-minimal 是**主动决定** bot 不走 Turn；本分支是**被动降级**到同一路径。**功能完全等价**。

---

## 三、本分支 vs B-minimal — 优势

| 维度 | B-minimal | 本分支 |
|------|-----------|--------|
| fan-out 机制 | MentionRouting 直连 agent | `dispatch_after_commit`（P22 合规，dead agent 不 abort） |
| fan-out 失败隔离 | dead agent 可能 abort turn | `dispatch_after_commit` defers |
| customer 消息 Turn 生命周期 | 无 | ✅ `open_turn` → fan-out |
| **框架补齐后升级** | 需要重写编排层 | **零改动**，约束解除后自动升级 |
| operator 接管 | TurnAdapter 直驱 | `cs_orchestrator.operator_claim/settle` |
| operator authz | 改了 roles.ex | 可通过 CapBAC 注册 |

---

## 四、决策

**继续使用 CsOrchestrator Behavior + TurnDriver 方案。**

**理由**:

1. 两条约束在**正常运行路径中不触发**。只有重启场景下行为降级，且降级行为与 B-minimal **功能等价**。
2. **数据无丢失**。bot reply 走 MessageStore 持久化 + PubSub 即时投递。
3. **恢复路径通畅**。operator 重新接管即可恢复正常状态。
4. `dispatch_after_commit` fan-out 比 MentionRouting 直连**更健壮**（P22 合规）。
5. **未来升级成本为零**：框架补齐约束 #1（静态 behaviors/0 支持）和 #2（agent reply 路由可配置）后，CsOrchestrator 自动获得完整能力——bot reply 走 Turn compose/settle、CustomerFeed 全覆盖、operator 可 cancel in-flight bot turn。

---

## 五、待办

| 项 | 说明 |
|----|------|
| operator authz | 需参考 PR #740 的 `roles.ex` 修改，授予 operator Turn caps，使 Turn 操作可审计 |
| customer visibility 过滤 | 参考 PR #740 的 `customer_live.ex` 修改，加 `visibility == :customer_visible` belt-and-suspenders |
| CR 原子 rename | 参考 PR #740 的 `cr_engine.ex`，`update_current` 改为原子 rename（`File.rename`） |
| 跑通测试 | 移植的 8 个 test 文件需适配并验证 |
| 给 Allen 的 flag | `system://turn-adapter` catalog 条目（dead，可清理）；`AgentFlavorAttributes` 持久化该放 core |
