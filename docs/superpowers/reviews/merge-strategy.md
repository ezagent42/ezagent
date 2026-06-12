# 合并策略: URL 统一 + 基准分支选择

> 日期: 2026-06-12
> 共同祖先: `48d938cf` (autoservice = docs only, 无实现代码)

---

## 一、URL 结构对比

### dev 路由

```
Customer 侧:
  /autoservice                          → CustomerLive
  /autoservice/operator                 → OperatorLive

Admin 侧 (Operations — 平台管理):
  /sessions                             → AdminLive (通用会话活动)
  /admin                                → AdminDashboardLive
  /admin/autoservice                    → MasterDashboardLive
  /admin/autoservice/tenants/new        → TenantOnboardLive
  /admin/autoservice/tenants/:tid       → TenantDashboardLive
  /admin/autoservice/tenants/:tid/cr    → CrDashboardLive
  /admin/autoservice/tenants/:tid/operators → OperatorsLive
```

### PR #731 路由

```
Customer 侧:
  /autoservice                          → CustomerLive
  /autoservice/operator                 → OperatorLive

Admin 侧 (Content — 内容管理):
  /autoservice/admin                    → TenantAdminLive
```

### 冲突点

| URL | dev | PR | 冲突 |
|---|---|---|---|
| `/autoservice` | ✅ | ✅ | ⚠️ 同路由 |
| `/autoservice/operator` | ✅ | ✅ | ⚠️ 同路由 |
| `/autoservice/admin` | — | ✅ | ❌ 新路由 |
| `/admin/autoservice/*` | ✅ (5条) | — | ❌ dev 独有 |

---

## 二、URL 统一方案

### 设计原则

两个 URL 命名空间服务于**不同角色**:

| 命名空间 | 受众 | 门控 | 功能 |
|---|---|---|---|
| `/admin/*` | Master/Platform Admin | `:require_admin` live_session | 跨租户管理 (所有租户的仪表盘、CR、Operators) |
| `/autoservice/*` | Tenant Admin + Customer + Operator | 普通登录 | 单租户操作 (内容编辑、客服对话、接管) |

### 统一后的 URL 结构

```
Customer 侧 (不变):
  /autoservice                          → CustomerLive
  /autoservice/operator                 → OperatorLive

Tenant Admin — 内容管理 (新增):
  /autoservice/admin                    → TenantAdminLive  ← 从 PR 移植
  /autoservice/admin/soul               → Soul 编辑 (PR)
  /autoservice/admin/slots              → Slots 编辑 (PR)
  /autoservice/admin/skills             → Skills 管理 (PR)
  /autoservice/admin/preview            → Preview 渲染 (PR)

Master/Platform Admin — 运营管理 (保留 dev):
  /admin                                → AdminDashboardLive
  /admin/autoservice                    → MasterDashboardLive
  /admin/autoservice/tenants/new        → TenantOnboardLive
  /admin/autoservice/tenants/:tid       → TenantDashboardLive
  /admin/autoservice/tenants/:tid/cr    → CrDashboardLive
  /admin/autoservice/tenants/:tid/operators → OperatorsLive
  /admin/autoservice/tenants/:tid/content  → 重定向到 /autoservice/admin (可选)

通用 Admin (保留 dev):
  /sessions                             → AdminLive
  /admin/logs                           → ObservabilityLive
  /admin/registry                       → EntitiesLive
  /admin/snapshots                      → SnapshotsLive
  /admin/templates                      → AdminTemplatesLive
  /admin/caps                           → AdminCapsLive
  /admin/settings                       → SettingsLive
  /admin/routing                        → RoutingLive
```

### 导航链接集成

```
TenantDashboardLive (/admin/autoservice/tenants/:tid)
  Quick Links:
    [CR Dashboard]  → /admin/autoservice/tenants/:tid/cr
    [Operators]     → /admin/autoservice/tenants/:tid/operators
    [Content Edit]  → /autoservice/admin              ← 新增

TenantAdminLive (/autoservice/admin)
  [Back to Dashboard] → /admin/autoservice/tenants/:tid
```

---

## 三、合并基准分支选择

### 选项对比

| | A: dev 为基准 + 移植 PR | B: PR 为基准 + 移植 dev | C: 新分支从头集成为 |
|---|---|---|---|
| **基准分支** | `autoservice-dev` | PR #731 (`feat/autoservice-phaseB-customer-path`) | `autoservice` (docs-only) |
| **保留的代码量** | ~8893 行 admin + 18 模块 content | CsOrchestrator Kind + ~6 模块 content | 0 |
| **需要移植的量** | ~2800 行 (PR 特性) | ~12000+ 行 (dev 全部) | ~15000+ 行 (双方全部) |
| **需要删除的量** | 0 | CsOrchestrator Kind (~750行) + 重连路由 | 无 |
| **冲突文件** | 2 (CustomerLive + OperatorLive) | 全部 autoservice plugin 文件 | 无 (全新) |
| **工作量** | ⭐ 低 | ⭐⭐⭐ 高 | ⭐⭐⭐⭐ 最高 |
| **风险** | 低 (dev 已验证基础架构) | 高 (需拆除 orchestrator + 重建) | 最高 (从零集成) |

### 推荐: 方案 A — autoservice-dev 为基准

**理由**:

1. **代码量差距**: dev 有 ~8893 行 admin 基础设施，PR 有 ~2800 行需要移植的特性。以 dev 为基准工作量是 PR 的 1/4。

2. **架构决策已定**: 不引入 CsOrchestrator Kind。以 PR 为基准需要先拆除 orchestrator Kind (删 ~750 行 + 重连所有路由和 dispatch)，再添加 dev 的架构。这是先拆后建，而 dev 为基准只需要增量添加。

3. **dev 的代码已经在当前分支上**: 不需要 fetch 远程 fork (网络不稳定)，不需要解决跨 fork 的 merge conflict。

4. **增量可验证**: 从 dev 出发，每移植一个 PR 特性就可以独立测试。从 PR 出发，需要把 dev 的 ~12000 行全部搬完才能验证。

5. **共同祖先无代码**: `48d938cf` 是纯文档，autoservice 分支没有实现代码。无论从哪个分支开始，都没有 "merge base 有冲突代码" 的问题。

### 移植清单 (PR → dev)

> **架构基准**: 设计文档 v3 选定 **Session + CsOrchestrator Behavior** 方案。
> CsOrchestrator 作为 Behavior 注册在 SocialwareSession Kind，Turn 操作通过 TurnDriver 在同进程内执行。
> Customer 消息和 agent reply 都走 Turn 生命周期 (open → compose → settle)，operator 接管走 cancel+reopen。
> 详见 `docs/superpowers/specs/2026-06-10-autoservice-v2-design.md` v3。

```
P0 (核心架构 — CsOrchestrator Behavior + TurnDriver):
  ☐ CsOrchestrator Behavior (use Ezagent.Lifecycle, ~250行新文件)
      - :receive action: open turn → dispatch_after_commit fast+slow
      - :operator_claim action: cancel bot turn → reopen → compose → claim
      - :operator_settle action: settle tracked turn → customer_visible
      - State: cs_orchestrator namespace in Session slice
  ☐ TurnDriver (同进程 Turn 驱动, ~100行新文件)
      - open/compose/settle/cancel/claim — 直接调用 Turn，不走 dispatch
  ☐ CustomerSession.ensure_session: Ezagent.Entity.Session → SocialwareSession
  ☐ Application.behaviors/0: 注册 CsOrchestrator 在 SocialwareSession Kind
  ☐ Routing: {:in_session, session} → [session] (customer msg → cs_orchestrator.receive)
  ☐ Agent reply 路由: agent reply → session?action=cs_orchestrator.receive (单路径)
  ☐ OperatorLive: 接管/提交 dispatch 到 cs_orchestrator.operator_claim/settle

P1 (移植已验证能力):
  ☐ 新增 TenantAdminLive (525行新文件, /autoservice/admin)
  ☐ 新增 Assembly.Refresh (195行新文件)
  ☐ CR: mark-before-flip + repair_current (改 cr_engine.ex)
  ☐ 新增 multitenant_test.exs (377行)
  ☐ 新增 operator_flow_test.exs (438行)
  ☐ 新增 publish_refresh_test.exs (117行)
  ☐ api_key from env (确认 dev 已有 maybe_put_deepseek_key 后决定是否冗余)

P2 (增强):
  ☐ Seed task: @workspace_name 硬编码 → --tenant 参数化
  ☐ AgentsConfig: @module_attr → {:ok, map}/{:error, reason} 合约
  ☐ Admin navigation: TenantDashboardLive 加 [Content Edit] 链接
```

### 执行步骤

> **架构**: 设计文档 v3 选定 Session + CsOrchestrator Behavior。P0 实现 Behavior + TurnDriver，不是最小修正。

```bash
# 1. 从 autoservice-dev 创建合并分支
git checkout autoservice-dev
git checkout -b feat/autoservice-v2-merge

# 2. P0: 实现 CsOrchestrator Behavior (~250行新文件)
#    新建: apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex
#      use Ezagent.Lifecycle, 3 actions: :receive, :operator_claim, :operator_settle
#      :receive → open turn → dispatch_after_commit fast+slow
#      :operator_claim → cancel bot turn → reopen → compose → claim
#      :operator_settle → settle tracked turn → customer_visible
#      State: cs_orchestrator namespace in Session slice
#    注册: application.ex behaviors/0 → SocialwareSession Kind

# 3. P0: 实现 TurnDriver (~100行新文件)
#    新建: apps/ezagent_plugin_autoservice/lib/.../turn_driver.ex
#      open/compose/settle/cancel/claim — 同进程调用，不走 dispatch

# 4. P0: Session spawn + 路由
#    改: customer_session.ex → Ezagent.Entity.Session → SocialwareSession
#    改: routing → {:in_session, session} → [session] (msg → cs_orchestrator.receive)
#    改: agent reply 路由 → session?action=cs_orchestrator.receive

# 5. P0: OperatorLive 对接 Behavior
#    改: operator_live.ex → 接管 dispatch cs_orchestrator.operator_claim/settle

# 6. P1: 移植 TenantAdminLive (新文件)
#    PR tenant_admin_live.ex → apps/ezagent_plugin_liveview/.../tenant/
#    加路由 /autoservice/admin

# 7. P1: 移植 Assembly.Refresh (新文件)
#    加 publish 后的 agent 更新逻辑

# 8. P1: CR 崩溃恢复
#    改 cr_engine.ex → mark-before-flip + repair_current

# 9. P1: 移植测试
#    加 multitenant_test, operator_flow_test, publish_refresh_test
#    加 cs_orchestrator_test

# 10. P2: seed 参数化 + URL 统一 + 导航链接

# 11. 验证全量测试通过

# 12. 合并回 autoservice-dev
```

---

## 四、为什么不用 PR 分支为基准

以 PR 为基准的移植清单对比:

```
需要从 dev 移植到 PR:
  ☐ 删除 CsOrchestrator Kind (~750行) + 拆除所有引用
  ☐ 重写 CsOrchestrator 为 Behavior (Kind→Behavior, 保留编排逻辑)
  ☐ 重连 agent reply 路由 (bridge → orchestrator.send → cs_orchestrator.receive)
  ☐ 添加 content plugin Behavior 层 (~2300行, 18模块)
  ☐ 添加 admin/ 子目录 (~3262行)
  ☐ 添加 admin_live.ex (974行)
  ☐ 添加 agent 管理 (1963行)
  ☐ 添加 autoservice tenant admin (1242行)
  ☐ 添加 master/tenant LiveViews (5文件)
  ☐ 添加 FillerLoop
  ☐ 添加 Uris 模块
  ☐ 移动 LiveView 文件到 ezagent_plugin_liveview
  ☐ 添加 dev 路由 (/admin/*, /sessions)
  ☐ 添加 dev 测试 (914行 content + 417行 cr)
  ☐ 删除 after_boot hack (不需要)
  ─────────────────────────────
  总计: ~12000+ 行新增 + ~750 行删除 + 大量重连
```

以 dev 为基准的 4x 更少工作量。

---

## 五、合并后的 plugin 结构

```
ezagent_plugin_autoservice/          ← 保留 dev 结构 + Behavior + TurnDriver
  lib/
    ezagent/behavior/
      cs_orchestrator.ex              ← 新: CsOrchestrator Behavior (use Ezagent.Lifecycle)
    ezagent_plugin_autoservice/
      application.ex                 ← dev (加 behaviors/0 注册 CsOrchestrator)
      autoservice_assembly.ex        ← dev + PR 的 8-step provision
      customer_session.ex            ← dev + SocialwareSession spawn
      turn_driver.ex                 ← 新: Turn 驱动 (同进程, 不走 dispatch)
      turn_adapter.ex                ← dev (保留作为外部 dispatch 入口)
      filler_loop.ex                 ← dev (保留，后续完善)
      roles.ex                       ← dev (保留)
      uris.ex                        ← dev (保留)
      chat_ui.ex                     ← dev (保留)
      assembly/
        refresh.ex                   ← 从 PR 移植 (新文件)

ezagent_plugin_content/              ← dev 完整保留
  lib/... (18模块 + Behavior层)

ezagent_plugin_cr/                   ← dev 保留 + PR 恢复逻辑
  lib/...
    cr_engine.ex                     ← dev + PR mark-before-flip + repair_current

ezagent_plugin_liveview/             ← dev 完整保留 + PR Content Admin
  lib/.../
    admin/                           ← dev 完整保留 (3262行)
    admin_live.ex                    ← dev 完整保留 (974行)
    agent_*_live.ex                  ← dev 完整保留 (1963行)
    autoservice/
      customer_live.ex               ← dev (保留)
      operator_live.ex               ← dev + PR cancel+reopen 修复
    tenant/
      tenant_admin_live.ex           ← 从 PR 移植 (新文件, 525行)
      tenant_dashboard_live.ex       ← dev (保留, 加导航链接)
      ... (cr/operators/onboard)     ← dev (保留)
    master/                          ← dev (保留)
```

---

## 六、Core Issues 追踪

合并后必须回顾的三个 core 问题 → [`docs/superpowers/retros/core-issues-tracker.md`](../retros/core-issues-tracker.md)

| # | 问题 | 合并后状态 | Owner |
|---|---|---|---|
| #1 | Session kind_type 共用 | ⚠️ 短期改 spawn SocialwareSession；长期 Allen 修 | 合并时修复 + Allen |
| #2 | Flavor cache 非持久 | ✅ 消失 | Allen (框架改进) |
| #3 | Producer gap | ⚠️ 等 framework 修 | Allen |

---

## 七、结论

| 决策 | 选择 | 原因 |
|---|---|---|
| **URL 统一** | dev `/admin/autoservice/*` + PR `/autoservice/admin` | 不同角色，不同门控，互补不冲突 |
| **合并基准** | `autoservice-dev` | 代码量大 4x，架构更简洁，不需要拆 CsOrchestrator |
| **合并方式** | 新分支 `feat/autoservice-v2-merge` | 增量可验证，autoservice-dev 保持干净 |
| **移植量** | ~2800 行新增/修改 | P0(修bug) → P1(移植特性) → P2(增强) |
