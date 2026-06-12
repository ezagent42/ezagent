# 合并方向修正:B-minimal(取代 "CsOrchestrator Behavior + Turn-for-everything")

> 日期:2026-06-12 · 作者:FatNine 团队(实施中发现的硬约束驱动)
> 状态:**取代** `merge-strategy.md` / `CsOrchestrator-vs-Session-Behavior.md` 里选定的"方案 B(CsOrchestrator Behavior + Turn-for-everything)"。原文档保留作为推理过程;实际落地按本文。

## TL;DR

合并按 **B-minimal** 落地:**bot 路径沿用 dev 现状(直连 fast/slow + `chat.send`);只有 operator 接管走 Turn(`operator_only` → settle → `customer_visible`),用 `TurnAdapter` 直接驱动,不引入 orchestrator。** 这是实施中撞到三条框架硬约束后,对"Turn-for-everything"的回退。

## 为什么不是 "CsOrchestrator Behavior + Turn-for-everything"

P0 实施时做了 spike + 读核心代码,发现三条原决策文档没料到的硬约束:

1. **投递层无法把消息送到"挂在 session 上的 orchestrator"。**
   - 插件 `attach_behavior(CsOrchestrator, to: SocialwareSession)` 只做 dispatch 注册;**attach 的 behavior 不能拥有持久 slice**(`snapshot.ex` `prune_orphan_slices` 在 reload 时把不属于 Kind 静态 `behaviors/0` 的 slice 当孤儿剪掉)。所以 orchestrator 只能无状态(从 `:turns` slice 派生)。
   - `:dispatch_after_commit` 自投递 `turn.open` 不死锁(`deferred_dispatch.ex` 明确支持自投递),所以 **customer→turn.open 这半能跑**(P0 spike 验证过,test 绿)。
   - **但 agent-reply 这半送不到**:`Chat.Delivery` 按 recipient scheme 硬定动作(session→`chat.send`,其它→`chat.receive`),`URI.with_action` 会抹掉 query,`Resolver` 还会拒绝"recipient == 当前 session"。bridge 也硬投 `chat.send`。所以 bot 回复经 bridge 到 session 只会落进 Chat,**接不到 session 上的 orchestrator**。
   - 对比:**独立 orchestrator 实体(PR #731 的 Option A)反而贴合**——bridge 回投 caller(orchestrator 实体)→ 它的 `:send` handler → 驱动 Turn。这就是 #731 live 能跑通的原因。

2. **CustomerFeed 是 settlement 门控,不是看 `customer_visible` flag。**
   - `CustomerFeed.snapshot` 读 `MessageStore.committed_customer_visible` + committed outbox。bot 回复经 `chat.send` 不 settle → **不进 gated feed**。dev 因此额外订了 `Chat.session_events_topic` raw 流来显示 bot 回复(佳哥标的"门控 50% / 双订阅防御")。
   - 要让 bot 也走干净 gated feed 就必须 settle 经 Turn —— 又撞回约束 1。

3. **dev 现状的 operator 接管漏草稿。**
   - dev operator `send` 把 `operator_only` 消息经 `chat.send` 发,`Chat.handle_send` **无条件** broadcast `{:chat_message}`,客户 raw 订阅**不过滤 visibility** → 草稿即时漏给客户。门控形同虚设。

## B-minimal 的设计

| | 做法 |
|---|---|
| **bot 路径** | dev 现状不动:customer → MentionRouting → fast/slow 直连;bot 回复 `chat.send` → 客户经 raw `{:chat_message}` 即时看到(bot 本就该即时) |
| **operator 接管** | `TurnAdapter` 直接驱动 Turn:打字回复 → 接管(`open_turn`→`compose_turn(真回复)`→`claim`,持 `operator_only`)→ 提交(`settle`→`customer_visible`→CustomerFeed)。**不经 `chat.send`,不 broadcast,不漏。** |
| **authz** | operator 角色授予 Turn caps(`kind: :session, behavior: Behavior.Turn, action: open/compose/claim/settle`);`TurnAdapter` 用 operator 自己的 caps 驱动(可审计,不滥用 system principal,不改 catalog) |
| **客户侧防御** | `customer_live` `{:chat_message}` handler 加 `visibility == :customer_visible` 过滤(belt-and-suspenders) |
| **bot 暂停** | 接管时 `RuleStore.disable` 暂停 customer→agents 路由,提交后 enable |

## 已知 trade-off(明确推迟)

- **门控非统一**:bot 即时(raw sub,本就正确)、operator 走 Turn 门控。"让 bot 也先审后发/统一门控"= Option A(独立 orchestrator 实体,#731 已验证),作为**单独可评估的后续升级**;真需要时再上,届时 flavor-cache 大概率已被 core 修掉,A 的最大软肋也就没了。
- `system://turn-adapter` catalog 条目现在无 caller(dead),留给 Allen 顺手清理。

## P0 状态(已完成)

operator 接管:Turn 驱动 + 门控正确(草稿 settle 前隐藏、settle 后可见,test 证明)+ 真 operator authz(test 用 operator 实际 caps 驱动通过)。`apps/ezagent_plugin_autoservice` 10 test 绿,lifecycle gate 绿。commit `d1041ef7` + `002bc31b`。
