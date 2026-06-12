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

```
P0 (修复 bug):
  ☐ OperatorLive: synthetic turn_id → cancel+reopen (~50行改动)
  ☐ CustomerSession: Ezagent.Entity.Session → SocialwareSession (~1行)
  ☐ api_key: 参数传入 → $PROVIDER_API_KEY env (~10行)

P1 (移植已验证能力):
  ☐ 新增 TenantAdminLive (525行新文件, /autoservice/admin)
  ☐ 新增 Assembly.Refresh (195行新文件)
  ☐ CR: mark-before-flip + repair_current (改 cr_engine.ex)
  ☐ 新增 multitenant_test.exs (377行)
  ☐ 新增 operator_flow_test.exs (438行)
  ☐ 新增 publish_refresh_test.exs (117行)
  ☐ dispatch_after_commit for fan-out (改 customer_session.ex)

P2 (增强):
  ☐ Seed task: @workspace_name 硬编码 → --tenant 参数化
  ☐ AgentsConfig: @module_attr → {:ok, map}/{:error, reason} 合约
  ☐ 连续消息 cancel 旧 turn (改 CustomerSession/orchestrator)
  ☐ Admin navigation: TenantDashboardLive 加 [Content Edit] 链接
```

### 执行步骤

```bash
# 1. 从 autoservice-dev 创建合并分支
git checkout autoservice-dev
git checkout -b feat/autoservice-v2-merge

# 2. P0: 修复 operator 接管 (最小修正方案 A)
#    改: operator_live.ex + turn_adapter.ex → Turn 正确使用
#    改: customer_session.ex → spawn SocialwareSession
#    测试: 验证 Turn.claim visibility gating 生效

# 3. P0: api_key from env
#    改: customer_session.ex → 读 $DEEPSEEK_API_KEY env

# 4. P1: 移植 TenantAdminLive (新文件)
#    cp PR 的 tenant_admin_live.ex → apps/ezagent_plugin_liveview/.../tenant/
#    加路由 /autoservice/admin

# 5. P1: 移植 Assembly.Refresh (新文件)
#    加 publish 后的 agent 更新逻辑

# 6. P1: CR 崩溃恢复
#    改 cr_engine.ex → mark-before-flip + repair_current

# 7. P1: 移植测试
#    加 multitenant_test, operator_flow_test, publish_refresh_test

# 8. P1: dispatch_after_commit
#    改 customer_session.ex → agent fan-out effect

# 9. 验证全量测试通过

# 10. 合并回 autoservice-dev
```

---

## 四、为什么不用 PR 分支为基准

以 PR 为基准的移植清单对比:

```
需要从 dev 移植到 PR:
  ☐ 删除 CsOrchestrator Kind (~750行) + 拆除所有引用
  ☐ 删除 TurnDriver (被 TurnAdapter 替代)
  ☐ 重连 agent reply 路由 (bridge → orchestrator.send → chat.send → PubSub)
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
ezagent_plugin_autoservice/          ← 保留 dev 结构 + 增量
  lib/
    ezagent_plugin_autoservice/
      application.ex                 ← dev (加 behavior 注册)
      autoservice_assembly.ex        ← dev + PR 的 8-step provision
      customer_session.ex            ← dev + PR 的 SocialwareSession + api_key
      turn_adapter.ex                ← dev (保留，operator takeover 修复后使用)
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

## 六、结论

| 决策 | 选择 | 原因 |
|---|---|---|
| **URL 统一** | dev `/admin/autoservice/*` + PR `/autoservice/admin` | 不同角色，不同门控，互补不冲突 |
| **合并基准** | `autoservice-dev` | 代码量大 4x，架构更简洁，不需要拆 CsOrchestrator |
| **合并方式** | 新分支 `feat/autoservice-v2-merge` | 增量可验证，autoservice-dev 保持干净 |
| **移植量** | ~2800 行新增/修改 | P0(修bug) → P1(移植特性) → P2(增强) |
