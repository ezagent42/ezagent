# PR #731 vs autoservice-dev — 完整比对结果

> 日期: 2026-06-12 | 状态: 最终版
>
> 配套文档:
> - [架构对比](PR731-vs-autoservice-dev-comparison.md) — 顶层架构差异
> - [编排模型决策](CsOrchestrator-vs-Session-Behavior.md) — Kind vs Behavior
> - [需求完成度](PR731-vs-autoservice-dev-需求完成度.md) — 逐项打分
> - [取舍分析](PR731-vs-autoservice-dev-取舍分析.md) — 保留/采纳/不采纳
> - [Operator 接管修正](operator-takeover-fix-options.md) — 最小修正 vs Behavior 方案
> - [Core 问题影响](PR731-core-issues-impact.md) — 三个 core 问题在新方案下状态

---

## 一、一句话总结

**PR #731 功能完整但架构偏重 (90% 完成度)，autoservice-dev 架构简洁但细节粗糙 (69% 完成度)。取 dev 的架构骨架和 content plugin，取 PR 的 operator 接管、Admin UI、CR 恢复、热更新、测试。**

---

## 二、核心差异

### 2.1 编排模型

| | PR #731 | autoservice-dev |
|---|---|---|
| **方案** | CsOrchestrator Lifecycle Kind | Plain Session + MentionRouting |
| **customer→bot** | MentionRouting → orchestrator.receive → fan-out | MentionRouting → fast+slow agent 直接 |
| **bot reply** | bridge → orchestrator.send → compose → settle | agent → chat.send → PubSub |
| **operator 接管** | orchestrator.operator_claim → cancel bot turn → reopen → compose → claim | synthetic turn_id → TurnAdapter.claim (不生效) + RuleStore.disable |
| **进程数** | 4 per customer | 3 per customer |

### 2.2 完成度

| 领域 | PR #731 | autoservice-dev | 差距原因 |
|---|---|---|---|
| Customer 消息处理 | 100% | 100% | 持平 |
| Fast/Slow Agent | 100% | 95% | dev model config 不流入 create_agent |
| **Operator 接管** | **95%** | **40%** | dev synthetic turn_id → Turn 门控不生效 |
| **Turn 生命周期** | **100%** | **30%** | dev 只在 operator 路径用 Turn 且是错的 |
| **CustomerFeed 门控** | **100%** | **50%** | dev bot 回复无门控，operator 门控不生效 |
| **Content Plugin** | 40% | **90%** | dev 有 Behavior 层 + CRUD + Platform |
| CR Plugin | 85% | 80% | PR 有崩溃恢复，dev lint 更全 |
| 多租户 | 100% | 80% | PR 已验证 (multitenant_test) |
| **内容热更新** | **85%** | **0%** | dev 无 CR publish → refresh |
| 跨 VM 重启 | 85% | **100%** | PR 需要 after_boot hack |
| **Admin UI** | **85%** | **0%** | dev 完全没有管理界面 |
| Operator UI | 95% | 60% | dev 接管 bug + rehydrate 风险 |
| **总分** | **90%** | **69%** | — |

### 2.3 Core 问题状态

| PR #731 问题 | 新方案下 | 处理 |
|---|---|---|
| #1 Session kind_type 共用 | ⚠️ 仍存在 | 短期: spawn SocialwareSession；长期: Allen 修 |
| #2 Flavor cache 丢失 | ✅ **消失** | 不引入 orchestrator Kind 自动避开 |
| #3 Producer gap | ⚠️ 仍存在 | 与架构无关，等 framework 修 |

---

## 三、取舍决策

### ✅ 从 autoservice-dev 保留

```
架构: Session + MentionRouting (简单，无 flavor cache 问题)
Content plugin: 18 模块 + Behavior 层 (CapBAC/审计)
CR plugin: Engine/Lint/Snapshot/Rollback 结构
FillerLoop: 用户体验 (完善实现)
LiveView 分离: ezagent_plugin_liveview
Uris 模块: 集中化 URI 推导
TenantRuntime: 完整 sandbox/release path 管理
```

### ✅ 从 PR #731 采纳

```
operator 接管: cancel+reopen (最小修正 — 修复 Turn 用法)
dispatch_after_commit: agent fan-out P22 合规
CR 发布: mark-before-flip + repair_current (崩溃恢复)
CR 初始化: init_tenant 幂等 + half-init 恢复
api_key from env: 安全最佳实践
Admin LiveView: TenantAdminLive (移植)
测试: multitenant / operator_flow / publish_refresh
连续消息 cancel 旧 turn
AgentsConfig 非异常合约 ({:ok, map} | {:error, reason})
```

### ❌ 不采纳

```
CsOrchestrator Kind: 架构过重，flavor cache hack
CsOrchestrator Behavior: 当前不需要 (bot reply 不需要 Turn)
after_boot flavor rehydration: 无 orchestrator Kind 则不需要
Agent reply :send action: 保持 chat.send → PubSub 单路径
```

### ⏸️ 待定

```
CsOrchestrator Behavior → bot draft 审核 / biphasic 协调 / Turn 超时需要时
Seed task 参数化 → 非 cinnox 租户需要时
Biphasic 显式建模 → fast/slow 有依赖关系时
```

---

## 四、实施优先级

```
P0 (立刻 — 修复 bug):
  1. Operator 接管最小修正 (修复 TurnAdapter 使用)
  2. Session spawn 改为 SocialwareSession (支持 Turn)
  3. api_key from env (替换参数传入)

P1 (本周 — 移植 PR #731 已验证能力):
  4. CR 发布: mark-before-flip + repair_current
  5. 多租户测试移植
  6. Operator 接管测试移植
  7. dispatch_after_commit for agent fan-out

P2 (下次迭代):
  8. Admin LiveView 移植 (TenantAdminLive)
  9. Publish+refresh 测试移植
  10. Seed task 参数化

P3 (按需):
  11. CsOrchestrator Behavior (bot draft 审核等触发)
```

---

## 五、关键风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| Operator 接管修复引入回归 | 低 | 只改 OperatorLive + TurnAdapter，不动 customer-bot 路径 |
| SocialwareSession spawn 不可用 | 中 | 确认 framework 已提供；如无则用 PR #731 的 ensure 方法 |
| Content plugin Behavior 层与 PR 的 provision 模式冲突 | 低 | Behavior 是加法，provision 调用 Store → 不冲突 |
| Agent reply 不经过 Turn → 无 CustomerFeed 门控 | 低 | bot 回复不需要 draft 审核，直接可见是正确的 |
