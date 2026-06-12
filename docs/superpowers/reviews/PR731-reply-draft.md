# PR #731 Review Reply (draft)

---

@FatNine 团队，PR #731 我们和本地 `autoservice-dev` 分支的 v2 实现做了全面对比分析（架构、代码、需求完成度、测试、core 问题影响），以下是结论和合并方案。

---

## TL;DR

- PR #731 是 v2 **全量实现**（非 docs-only），完成度 ~89%，经过 Live E2E 验证
- autoservice-dev 完成度 ~62%，架构更简洁但 operator 接管有 bug（synthetic turn_id）
- **采纳 autoservice-dev 为合并基准**，从 PR #731 移植 operator 接管修复、Content Admin UI、CR 崩溃恢复、热更新、测试
- 不引入 CsOrchestrator Kind（架构过重 + flavor cache 问题），保留 dev 的 Session + MentionRouting 架构
- 三个 core 问题: #1 仍需处理（改 spawn SocialwareSession），#2 自动消失（无 orchestrator Kind），#3 与架构无关

---

## 一、PR 描述 vs 实际内容

PR 描述写 "docs-only"、"本 PR 不含实现代码"、"单租户 cinnox、customer-only"，但 36 个 commits 实际包含:

- 3 个 plugin (content/cr/autoservice) 完整实现
- CustomerLive + OperatorLive + TenantAdminLive
- 多租户隔离验证 (cinnox + acme)
- CapBAC 4 角色 + operator 接管 cancel+reopen
- CR 发布 + agent 热更新 + Live E2E 6 bugs fixed

**PR 是全量 v2 端到端实现。** 描述需要更新。

---

## 二、核心架构分歧

两个分支最根本的差异在编排模型:

| | PR #731 | autoservice-dev |
|---|---|---|
| **编排模型** | CsOrchestrator Lifecycle Kind (4进程/customer) | Plain Session + MentionRouting (3进程/customer) |
| **customer → bot** | MentionRouting → orchestrator.receive → open turn → fan-out | MentionRouting → fast+slow agent 直接 |
| **bot reply** | bridge → orchestrator.send → Turn.compose → Turn.settle | agent → chat.send → PubSub |
| **operator 接管** | orchestrator.operator_claim → cancel bot turn → reopen → compose → claim | synthetic turn_id (`:erlang.unique_integer`) + RuleStore.disable |

**关键判断**: PR 的 Turn Orchestrator 模型功能完整但架构重；dev 的 Chat App 模型架构简洁但 operator 接管有 bug。我们选择保留 dev 的简洁架构，用**最小修正**（方案 A）修复 operator 接管，不引入 CsOrchestrator Kind。

详细决策: [CsOrchestrator-vs-Session-Behavior.md](CsOrchestrator-vs-Session-Behavior.md)

---

## 三、逐项对比摘要

| 领域 | dev | PR | 胜出 | 关键差距 |
|---|---|---|---|---|
| Customer 消息处理 | 100% | 100% | 持平 | — |
| Fast/Slow Agent | 95% | 100% | PR | dev: slow cc create_agent 不传 model/endpoint |
| **Operator 接管** | **20%** | **95%** | **PR** | dev: `:erlang.unique_integer` synthetic turn_id → Turn 门控不生效 |
| **Turn 生命周期** | **30%** | **100%** | **PR** | dev: bot reply 不走 Turn (chat.send → PubSub) |
| **CustomerFeed 门控** | **50%** | **100%** | **PR** | dev: bot reply 走 chat_message 无门控；双订阅防御 |
| **Content Plugin** | **90%** | **40%** | **dev** | dev: 18模块 + Behavior层 + Platform管理 |
| CR Plugin | 80% | 85% | 持平 | PR: 崩溃恢复；dev: lint 更全 |
| 多租户 | 80% | 100% | PR | PR: multitenant_test 已验证 |
| **Admin UI (Operations)** | **85%** | ? | **dev** | dev: 5文件1242行(Dashboard/CR/Operators/Onboard) + admin/子目录3262行 |
| **Admin UI (Content)** | **0%** | **85%** | **PR** | PR: TenantAdminLive 525行(soul/slots/skills/preview) |
| **内容热更新** | **30%** | **85%** | **PR** | dev: CrEngine.publish 只翻指针无通知；PR: Assembly.Refresh |
| 跨 VM 重启 | **100%** | **85%** | **dev** | dev: 无 orchestrator → 无 flavor cache 问题 |
| **测试覆盖** | **1462行** | **~3672行** | **PR** | dev autoservice 仅 131 行测试 |
| **加权总分** | **62%** | **89%** | — | — |

代码级验证: [PR731-vs-autoservice-dev-最终验证.md](PR731-vs-autoservice-dev-最终验证.md)

---

## 四、方案优劣

### PR #731 优势
- ✅ Turn 生命周期全覆盖 → CustomerFeed 门控统一
- ✅ Operator 接管 cancel+reopen 正确 (Turn visibility gating 生效)
- ✅ dispatch_after_commit (P22 合规，dead agent 不 abort)
- ✅ Content Admin UI (soul/slots/skills/preview)
- ✅ 内容热更新 (Assembly.Refresh)
- ✅ Live E2E 验证 (6 bugs fixed，真实 claude 2.1.169 测试)
- ✅ 测试覆盖完整 (~3672 行)

### PR #731 劣势
- ❌ CsOrchestrator Kind 过重 (新 Kind 类型，flavor cache hack)
- ❌ Content plugin 薄 (~6 模块，无 Behavior 层/CapBAC)
- ❌ Agent reply 双路径 (:receive + :send)
- ❌ 跨 VM 重启需要 after_boot 重 hydrated (Allen 建议放 core，PR 已 flag)

### autoservice-dev 优势
- ✅ 架构简洁 (Session + MentionRouting，无新 Kind)
- ✅ Content plugin 工程化 (18模块 + Behavior层 + CapBAC + Platform)
- ✅ Admin Operations UI 完整 (会话管理 + orchestrator 健康 + agent 管理 + 租户仪表盘)
- ✅ 跨 VM 重启无额外负担
- ✅ LiveView 分离 (ezagent_plugin_liveview)

### autoservice-dev 劣势
- ❌ Operator 接管核心 bug (synthetic turn_id → Turn 门控不生效)
- ❌ Bot reply 不走 Turn → 无 CustomerFeed gating
- ❌ 无 Content Admin UI (soul/slots 编辑)
- ❌ 无内容热更新
- ❌ 测试覆盖薄弱 (autoservice 仅 131 行)

---

## 五、合并基准选择

选择 **autoservice-dev 为合并基准**，理由:

| | dev 为基准 | PR 为基准 |
|---|---|---|
| 需移植代码量 | ~2800 行 | ~12000+ 行 |
| 需删除代码 | 0 | CsOrchestrator Kind (~750行) + 重连路由 |
| 冲突文件 | 2 个 (CustomerLive, OperatorLive) | 全部 autoservice 文件 |
| **工作量比** | **1x** | **4x** |

dev 有 ~8893 行 admin 基础设施 + 18 模块 content plugin。以 PR 为基准需要先拆 CsOrchestrator 再重建 dev 全部能力。以 dev 为基准是纯增量。

执行方式: 从 autoservice-dev 创建 `feat/autoservice-v2-merge` 分支，分三步移植:

- **P0 (修 bug)**: operator 接管取消 synthetic turn_id → 真实 Turn + Session spawn 改 SocialwareSession + api_key from env
- **P1 (移植特性)**: TenantAdminLive + Assembly.Refresh + CR 崩溃恢复 + 测试 (multitenant/operator_flow/publish_refresh) + dispatch_after_commit
- **P2 (增强)**: seed 参数化 + 导航链接 + URL 统一

详细方案: [merge-strategy.md](merge-strategy.md)

---

## 六、三个 Core 问题在新方案下的状态

> **合并后追踪**: [`docs/superpowers/retros/core-issues-tracker.md`](../retros/core-issues-tracker.md) — 逐项验证清单

| 问题 | 状态 | 处理 |
|---|---|---|
| **#1 Session kind_type** (SocialwareSession vs chat Session 共用 "session") | ⚠️ 仍存在 | 短期: `CustomerSession.ensure_session` 改为 spawn `SocialwareSession`；长期: 建议 Allen 修 substrate (distinct kind_type 或 snapshot-aware spawn handler) |
| **#2 Flavor cache** (AgentFlavorAttributes 非持久 ETS) | ✅ **消失** | 不引入 CsOrchestrator Kind → 无 agent-flavor Kind → 不需要 flavor cache → 不需要 after_boot hack。PR 的 flag ("应放 core") 仍然有效但新方案不再触发 |
| **#3 Producer gap** (#730 spawn_plan 读 model/endpoint 缺 producer) | ⚠️ 仍存在 | 与架构无关，等 framework 修。effort default "low" 可用 |

---

## 七、URL 统一

```
/platform/admin/*           — Master/Platform Admin (跨租户运营)
  /admin/autoservice                    → MasterDashboardLive (dev)
  /admin/autoservice/tenants/new        → TenantOnboardLive (dev)
  /admin/autoservice/tenants/:tid       → TenantDashboardLive (dev)
  /admin/autoservice/tenants/:tid/cr    → CrDashboardLive (dev)
  /admin/autoservice/tenants/:tid/operators → OperatorsLive (dev)

/autoservice/*              — Tenant + Customer + Operator
  /autoservice                          → CustomerLive (dev + PR 改进)
  /autoservice/operator                 → OperatorLive (dev + PR cancel+reopen)
  /autoservice/admin                    → TenantAdminLive (从 PR 移植)
```

两个命名空间服务不同角色 (`/admin/*` = :require_admin gate, `/autoservice/*` = 普通登录)，互补不冲突。

---

## 八、合并后的保留/移植清单

### 从 dev 完整保留 (不改)
- Content plugin: 18 模块 + Behavior 层 (ContentAdmin + TenantAdmin)
- CR plugin: Engine/Lint/Snapshot/Rollback 结构
- Admin 基础设施: admin/ (3262行) + admin_live.ex (974行) + agent 管理 (1963行)
- Autoservice tenant admin: 5 个 LiveView (1242行)
- FillerLoop + Uris + ChatUI
- LiveView 分离 + app_shell

### 从 PR #731 移植
- Operator 接管: cancel+reopen (最小修正方案 A，~50 行改动)
- TenantAdminLive: soul/slots/skills/preview (525 行新文件)
- Assembly.Refresh: publish 后 agent 更新 (195 行新文件)
- CR 崩溃恢复: mark-before-flip + repair_current (改 CrEngine)
- 测试: multitenant_test + operator_flow_test + publish_refresh_test (~930 行)
- dispatch_after_commit: agent fan-out P22 合规
- api_key from env: 安全最佳实践
- AgentsConfig 非异常合约: `{:ok, map}` / `{:error, reason}`

### 不引入
- CsOrchestrator Kind / Behavior
- after_boot flavor rehydration
- Agent reply :send action (保持 chat.send → PubSub 单路径)

---

## 九、参考文档

全部对比分析文档在 `docs/superpowers/reviews/`:

| 文档 | 内容 |
|---|---|
| [FINAL-对比结论.md](FINAL-对比结论.md) | 需求 vs 实现矩阵 + 加权评分 |
| [PR731-vs-autoservice-dev-最终验证.md](PR731-vs-autoservice-dev-最终验证.md) | 逐项代码证据 + 行号 |
| [PR731-vs-autoservice-dev-取舍分析.md](PR731-vs-autoservice-dev-取舍分析.md) | 保留/采纳/不采纳清单 + P0-P3 优先级 |
| [CsOrchestrator-vs-Session-Behavior.md](CsOrchestrator-vs-Session-Behavior.md) | 编排模型决策 |
| [operator-takeover-fix-options.md](operator-takeover-fix-options.md) | operator 接管修正方案 A vs B |
| [PR731-core-issues-impact.md](PR731-core-issues-impact.md) | 三个 core 问题在新方案下影响 |
| [dev-admin-保留分析.md](dev-admin-保留分析.md) | dev Admin 体系保留确认 |
| [merge-strategy.md](merge-strategy.md) | URL 统一 + 合并基准 + 执行步骤 |

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
