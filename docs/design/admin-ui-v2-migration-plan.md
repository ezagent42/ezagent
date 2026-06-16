# AutoService Admin UI v2 — 改版实施方案

> 2026-06-17 | 基于 autoservice-dev 当前状态 → 新设计

## 当前状态 (autoservice-dev)

```
autoservice/admin/
├── init_wizard_live.ex          ← Keep (Init Wizard)
├── soul_editor_live.ex          ← Merge → Slow Agent
├── slot_editor_live.ex          ← Merge → Slow Agent
├── skill_manager_live.ex        ← Merge → Slow Agent
├── kb_manager_live.ex           ← Merge → Slow Agent
├── sandbox_preview_live.ex      ← Merge → Debug Agent
├── version_timeline_live.ex     ← Keep (History)
├── admin_session_live.ex        ← Keep (P2 Admin Session)
├── platform/
│   ├── platform_soul_live.ex    ← Keep (P2)
│   └── platform_skill_live.ex   ← Keep (P2)
└── components/
    ├── admin_sidebar.ex         ← REFACTOR
    ├── skill_card.ex            ← Keep
    └── soul_diff_view.ex        ← Keep

Routes (15 routes):
  Master      /admin/autoservice
  Tenant      /admin/autoservice/tenants/:tid
  CR          /admin/autoservice/tenants/:tid/cr
  Operators   /admin/autoservice/tenants/:tid/operators
  InitWizard  /admin/autoservice/tenants/:tid/init
  SoulEditor  /admin/autoservice/tenants/:tid/soul       ← MERGE
  SlotEditor  /admin/autoservice/tenants/:tid/soul/slots  ← MERGE
  SkillMgr    /admin/autoservice/tenants/:tid/skills      ← MERGE
  KbMgr       /admin/autoservice/tenants/:tid/kb           ← MERGE
  Versions    /admin/autoservice/tenants/:tid/versions
  Preview     /admin/autoservice/tenants/:tid/preview      ← MERGE
  AdminSess   /admin/autoservice/agent
  PlatformS   /admin/autoservice/platform/soul
  PlatformSk  /admin/autoservice/platform/skills
```

## 目标状态（新设计）

### Sidebar 结构

```
Master
  🏠 Dashboard        → MasterDashboard
  🏢 Tenants          → Tenant List
  ➕ New Tenant        → Onboard

Tenant: {tid}
  Config Agents
    ⚡ Fast Agent      → FastAgentLive (NEW)
    🧠 Slow Agent      → SlowAgentLive (NEW, merges Soul+Skill+KB+Slot)

  Orchestrate
    🔀 Routeset        → OrchestrateLive (NEW)

  Verify & Release
    🧪 Debug Agent     → DebugAgentLive (NEW, replaces SandboxPreview)
    🔄 CR Review       → CrDashboardLive (REFACTOR: group by agent)
    📋 History         → VersionTimelineLive

  Config
    📊 Overview        → TenantDashboardLive (REFACTOR: agent cards)
    🚀 Init Wizard     → InitWizardLive
    👥 Operators       → OperatorsLive
    🤖 Admin Session   → AdminSessionLive (P2)
```

### 路由映射

| 旧路由 | 新路由 | 页面 |
|--------|--------|------|
| — | `/admin/autoservice/tenants/:tid/agent/fast` | 🆕 Fast Agent config |
| `/tenants/:tid/soul` + `/soul/slots` + `/skills` + `/kb` | `/admin/autoservice/tenants/:tid/agent/slow` | 🆕 Slow Agent config (tabbed) |
| — | `/admin/autoservice/tenants/:tid/orchestrate` | 🆕 Routeset editor |
| `/tenants/:tid/preview` | `/admin/autoservice/tenants/:tid/debug` | 🆕 Debug Agent (replaces preview) |
| `/tenants/:tid/cr` | `/admin/autoservice/tenants/:tid/cr` | 🔄 CR Review (refactor) |
| `/tenants/:tid` | `/admin/autoservice/tenants/:tid` | 🔄 Overview (refactor) |
| `/tenants/:tid/init` | `/admin/autoservice/tenants/:tid/init` | ✅ Keep |
| `/tenants/:tid/versions` | `/admin/autoservice/tenants/:tid/versions` | ✅ Keep |
| `/tenants/:tid/operators` | `/admin/autoservice/tenants/:tid/operators` | ✅ Keep |

### 文件变更清单

| 操作 | 文件 | 说明 |
|:--:|------|------|
| 🆕 CREATE | `autoservice/admin/fast_agent_live.ex` | Fast Agent config（仅 Soul tab） |
| 🆕 CREATE | `autoservice/admin/slow_agent_live.ex` | Slow Agent config（Soul/Skills/KB/Slots/Diff/Preview 6 tabs） |
| 🆕 CREATE | `autoservice/admin/orchestrate_live.ex` | Routeset 可视化编排器 |
| 🆕 CREATE | `autoservice/admin/debug_agent_live.ex` | Agent Debugger（chat test + side-by-side） |
| 🔄 REFACTOR | `autoservice/admin/components/admin_sidebar.ex` | 新分组 |
| 🔄 REFACTOR | `tenant/tenant_dashboard_live.ex` | Agent 卡片 + 简化 KPI |
| 🔄 REFACTOR | `tenant/cr_dashboard_live.ex` | 变更按 agent 分组 |
| 🔄 REFACTOR | `router.ex` | 新增 4 路由，旧路由保留兼容或 redirect |
| 📦 KEEP | `init_wizard_live.ex` | 不改 |
| 📦 KEEP | `version_timeline_live.ex` | 不改 |
| 📦 KEEP | `admin_session_live.ex` | 不改 (P2) |
| 📦 KEEP | `platform/*.ex` | 不改 (P2) |
| 📦 KEEP | `components/skill_card.ex` | 不改 |
| 📦 KEEP | `components/soul_diff_view.ex` | 不改 |
| 🗑️ ARCHIVE | `soul_editor_live.ex` | 内容合并到 Slow Agent Soul tab |
| 🗑️ ARCHIVE | `slot_editor_live.ex` | 内容合并到 Slow Agent Slots tab |
| 🗑️ ARCHIVE | `skill_manager_live.ex` | 内容合并到 Slow Agent Skills tab |
| 🗑️ ARCHIVE | `kb_manager_live.ex` | 内容合并到 Slow Agent KB tab |
| 🗑️ ARCHIVE | `sandbox_preview_live.ex` | 替换为 Debug Agent |

## 实施计划

### Batch 1: Fast + Slow Agent Config（核心重构）

| Task | 内容 | Effort |
|------|------|:--:|
| T1.1 | 创建 `fast_agent_live.ex` — 单 tab Soul 编辑器，读写 `sandbox/config/fast_ack_prompt.md` | M |
| T1.2 | 创建 `slow_agent_live.ex` — 将现有 SoulEditor/SlotEditor/SkillManager/KbManager 代码提取为 live_component tab，6 个 tab 共用同一个 assign | L |
| T1.3 | 注册新路由 `/agent/fast` + `/agent/slow`，旧路由 301 redirect | S |
| T1.4 | 更新 `admin_sidebar.ex` 为新分组 | S |
| T1.5 | 更新 `tenant_dashboard_live.ex` — Agent 卡片替代模块卡片 | M |

### Batch 2: Orchestrate + Debug

| Task | 内容 | Effort |
|------|------|:--:|
| T2.1 | 创建 `orchestrate_live.ex` — 可视化 Fast→Slow→Operator 路由链 | M |
| T2.2 | 创建 `debug_agent_live.ex` — 通用 Agent Debugger（chat test + side-by-side）| L |
| T2.3 | 注册新路由 `/orchestrate` + `/debug` | S |

### Batch 3: CR 重构 + 清理

| Task | 内容 | Effort |
|------|------|:--:|
| T3.1 | 重构 `cr_dashboard_live.ex` — 变更按 agent 分组展示 | M |
| T3.2 | Archive 旧文件 (`soul_editor_live.ex`, `slot_editor_live.ex`, `skill_manager_live.ex`, `kb_manager_live.ex`, `sandbox_preview_live.ex`) | S |
| T3.3 | E2E 测试 — 完整流程验证 | M |

## 不复用的旧代码（保留在 git 历史中）

```
保留作为参考（git history 可见）:
  soul_editor_live.ex       → Slow Agent Soul tab 参考
  slot_editor_live.ex       → Slow Agent Slots tab 参考
  skill_manager_live.ex     → Slow Agent Skills tab 参考
  kb_manager_live.ex        → Slow Agent KB tab 参考
  sandbox_preview_live.ex   → Debug Agent 参考
```

## 不变的部分

| 模块 | 说明 |
|------|------|
| `diff_engine.ex` (content) | 继续被 Slow Agent Diff tab 使用 |
| `source_tracker.ex` (content) | 继续被 Slow Agent KB tab 使用 |
| `cr_engine.ex` (cr) | `record_file_change` / `list_crs` / `publish` 不变 |
| `cr_lint.ex` (cr) | 不变 |
| `admin_session_live.ex` | 不变 (P2) |
| `platform/*.ex` | 不变 (P2) |
| `init_wizard_live.ex` | 不变 |
| `version_timeline_live.ex` | 不变 |
| `operators_live.ex` | 不变 |
