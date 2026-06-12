# dev Admin 体系在合并策略下的保留分析

> 日期: 2026-06-12
> 问题: dev admin 通过 orchestrator agent 对话管理租户的愿景，合并后能否完整保留？

---

## 一、dev Admin 体系代码规模

```
ezagent_plugin_liveview/lib/ezagent_plugin_liveview/
├── admin/                          (3262 行)  ← 核心管理基础设施
│   ├── session_editor.ex            (583)
│   ├── session_context.ex           (951)
│   ├── orchestrator_restart.ex       — orchestrator 重启
│   ├── routing_rules.ex              — 路由规则管理
│   ├── compose.ex                    — 消息编辑
│   ├── event_format.ex              — 事件格式
│   ├── invite.ex                    — 邀请
│   ├── member_panel.ex              — 成员面板
│   ├── rehydrate_flash.ex           — 重 hydrated 提示
│   └── session_external_mirror_live.ex
│
├── session/                         (146 行)
│   └── orchestrator_health_card.ex   — orchestrator 健康卡片
│
├── admin_live.ex                    (974 行) ← /sessions 核心 LV
├── admin_dashboard_live.ex          — /admin 仪表盘
├── admin_caps_live.ex               — Cap 管理
├── admin_templates_live.ex          — 模板管理
├── admin_authz_audit_live.ex        — 授权审计
│
├── agent_detail_live.ex             ┐
├── agent_new_live.ex                │ (1963 行) ← Agent 全生命周期管理
├── agent_extensions_live.ex         │
├── agent_api_keys_live.ex           ┘
│
├── master/master_dashboard_live.ex   ┐
├── tenant/tenant_dashboard_live.ex   │
├── tenant/cr_dashboard_live.ex       │ (1242 行) ← autoservice 管理
├── tenant/operators_live.ex          │
├── tenant/tenant_onboard_live.ex     ┘
│
├── app_shell.ex                     — 应用外壳 (Tier-3)
├── command_palette_component.ex      — 命令面板
└── ... (entities, routing, observability, workspaces 等)
```

**总计: ~8893 行 admin 代码** (不含 terminal、entities、routing 等通用模块)

---

## 二、dev Admin 核心设计: AI-Assisted Session Management

dev 的 admin 不是一个"表单填写系统"，而是一个 **AI 辅助的会话管理平台**:

### 2.1 核心概念

```
AdminLive (/sessions)
  ├─ SessionEditor: 会话选择器 + 视图切换器 + 设置
  ├─ SessionContext (951行):
  │   - 会话选择/授权/自加入
  │   - orchestrator 健康检查 (compute_orchestrator_health)
  │   - orchestrator 重启权限 (caller_can_restart_orchestrator?)
  │   - 会话绑定列表
  │   - 邀请选项
  ├─ OrchestratorHealthCard: orchestrator 运行状态
  ├─ OrchestratorRestart: 重启 orchestrator
  │   (dispatch template://agent/<ws>/cc-orchestrator?action=template.instantiate)
  ├─ RoutingRules: 路由规则可视化+管理
  └─ MemberPanel: 成员列表 + cc-agent PTY 终端入口
```

### 2.2 "通过 orchestrator agent 对话管理租户" 的愿景

这个愿景体现在:

1. **每个 Session 绑定一个 orchestrator (cc agent)**
   - `session_context.ex:219` — `compute_orchestrator_health/2`: 检查 orchestrator 是否存活
   - `session_context.ex:235` — `caller_can_restart_orchestrator?/2`: CapBAC 门控的重启权限
   - `session_editor.ex:465` — `generator_orchestrator/1`: 显示 orchestrator 模板 URI

2. **Admin 通过 conversation view 与 orchestrator 对话**
   - `admin_live.ex:66` — `alias EzagentPluginLiveview.Views.ConversationView`
   - SessionViewRegistry 动态注册可用视图 (conversation, pty, ...)
   - Admin 可以在 conversation 视图中与 orchestrator agent 对话，让它执行管理操作

3. **Orchestrator 健康监控 + 重启**
   - `orchestrator_health_card.ex` — 实时健康状态
   - `orchestrator_restart.ex` — 受控重启 (CapBAC 门控)
   - `admin_live.ex:509-519` — 重启逻辑: dispatch `template.instantiate`

4. **Agent 全生命周期管理** (1963 行)
   - 创建、详情、扩展、API key 管理

### 2.3 这是平台级能力，不是 autoservice 特有的

dev admin 管理的是 **任何类型的 Session + orchestrator**，不限于 autoservice。autoservice 的 customer service session 只是其中一种 Session 类型。这意味着:

- autoservice customer session → 在 `/sessions` 中可见
- autoservice orchestrator (如果有) → 健康监控可用
- autoservice agent → 在 agent 管理页面可见

---

## 三、PR #731 Admin: Content Editor

PR 的 TenantAdminLive (`/autoservice/admin`) 是一个 **内容编辑系统**:

```
TenantAdminLive (525行)
  ├─ Soul 编辑面板: textarea for sandbox/souls/customer.md
  ├─ Slots 编辑面板: textarea + YAML 校验 + 保存
  ├─ CR 面板: 版本 + lint 结果 + [发布] 按钮
  ├─ Skills 列表: 只读列表
  ├─ Preview: [预览渲染] → provision_context(sandbox) → <pre>
  └─ Cap 门控: can_write? → 只读模式
```

---

## 四、合并分析: 零冲突，完全互补

### 4.1 文件层面: 零冲突

| 组件 | dev 位置 | PR 位置 | 冲突? |
|---|---|---|---|
| Session 管理 + orchestrator 健康 | `ezagent_plugin_liveview/admin/` | — | ❌ 无 |
| Agent 管理 | `ezagent_plugin_liveview/agent_*_live.ex` | — | ❌ 无 |
| Admin 仪表盘 | `ezagent_plugin_liveview/{admin_,master/,tenant/}` | — | ❌ 无 |
| Content 编辑 (soul/slots/skills) | — | `ezagent_plugin_autoservice/.../admin/tenant_admin_live.ex` | ❌ 无 |
| **不同 plugin，不同目录，零 merge conflict** | | | |

### 4.2 路由层面: 零冲突

| 路由 | dev | PR | 冲突? |
|---|---|---|---|
| `/sessions` | ✅ AdminLive (会话管理) | — | ❌ |
| `/admin` | ✅ AdminDashboardLive | — | ❌ |
| `/admin/autoservice` | ✅ MasterDashboardLive | — | ❌ |
| `/admin/autoservice/tenants/:tid` | ✅ TenantDashboardLive | — | ❌ |
| `/admin/autoservice/tenants/:tid/cr` | ✅ CrDashboardLive | — | ❌ |
| `/autoservice` | ✅ CustomerLive | ✅ CustomerLive | ⚠️ 同路由，但功能相同(取 dev) |
| `/autoservice/operator` | ✅ OperatorLive | ✅ OperatorLive | ⚠️ 同路由，需合并修复(取 PR cancel+reopen) |
| `/autoservice/admin` | — | ✅ TenantAdminLive | ❌ 新路由，直接加 |

### 4.3 功能层面: 互补

```
dev Admin (AI-Assisted Operations):
  ✅ Session 管理 (选择/创建/视图切换)
  ✅ orchestrator 健康监控 + 重启
  ✅ Agent 生命周期管理
  ✅ 路由规则管理
  ✅ 成员/邀请管理
  ✅ Conversation view (与 orchestrator 对话)
  ✅ PTY 终端入口
  ✅ 租户仪表盘 + CR 状态
  ❌ Soul/slots 编辑 (design doc 列的 soul_slot_editor_live 未实现)
  ❌ Skills 内容编辑
  ❌ Preview 渲染

PR Admin (Content Management):
  ❌ 无 Session 管理
  ❌ 无 orchestrator 健康监控
  ❌ 无 Agent 管理
  ✅ Soul 编辑
  ✅ Slots 编辑 (YAML 校验)
  ✅ Skills 列表
  ✅ CR 发布
  ✅ Preview 渲染
  ✅ Cap 门控
```

### 4.4 集成方式

两者通过导航链接集成，不需要代码合并:

```
TenantDashboardLive (dev, /admin/autoservice/tenants/:tid)
  Quick Links:
    [CR Dashboard] → /admin/autoservice/tenants/:tid/cr
    [Operators]    → /admin/autoservice/tenants/:tid/operators
    [Content Edit] → /autoservice/admin              ← 新增链接到 PR 的 Content Admin
                          ↑
          TenantAdminLive (PR, /autoservice/admin)
            [Back to Dashboard] → /admin/autoservice/tenants/:tid
```

---

## 五、结论

### ✅ dev Admin 体系 100% 可以完整保留

| 保留项 | 代码量 | 状态 |
|---|---|---|
| admin/ 子目录 (session管理+orchestrator) | 3262 行 | 不冲突，完整保留 |
| admin_live.ex (会话活动协调器) | 974 行 | 不冲突，完整保留 |
| agent 管理 | 1963 行 | 不冲突，完整保留 |
| autoservice tenant admin | 1242 行 | 不冲突，完整保留 |
| 路由 `/admin/*` `/sessions` | 全部保留 | 不冲突 |

### ✅ PR Content Admin 可以无冲突添加

| 添加项 | 方式 |
|---|---|
| TenantAdminLive | 加到 `ezagent_plugin_autoservice` (或移植到 `ezagent_plugin_liveview/tenant/`) |
| 路由 `/autoservice/admin` | 新增路由，不冲突 |
| 导航链接 | 在 TenantDashboardLive Quick Links 加一条 |

### ⚠️ 唯一需要合并的文件

| 文件 | 处理 |
|---|---|
| `CustomerLive` | 两个分支都有，功能相似 → 保留 dev，加 PR 的改进 |
| `OperatorLive` | 两个分支都有 → 保留 dev 结构 + 移植 PR 的 cancel+reopen 接管修复 |

### 总结

**dev admin 的 "orchestrator agent 对话管理租户" 愿景不会受任何影响。** 合并策略是加法: dev 提供 Operations Admin (会话管理 + orchestrator 健康 + agent 管理)，PR 提供 Content Admin (soul/slots/skills 编辑 + CR 发布 + preview)。两者在不同 plugin、不同路由、不同目录，通过导航链接集成。
