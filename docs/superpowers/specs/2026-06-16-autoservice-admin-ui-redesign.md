# ezagent AutoService Admin UI 完整设计方案

> **状态**: 设计提案，待 Review
> **参考**: `D:\Work\h2os.cloud\AutoService-dev-a` 完整功能
> **目标**: 全功能迁移至 ezagent，独立组件化，预留 AI 助手 + Admin Session

---

## 一、设计原则

### 1.1 核心原则

1. **每个管理模块是独立 LiveView 组件** — 可单独挂载在页面，也可作为卡片嵌入 Admin Session
2. **ezagent 风格统一** — 灰色系(`gray-800` headers)、圆角卡片(`rounded-xl`)、Tailwind CSS
3. **Tab 内聚** — 相关操作放在同一页面，减少页面跳转
4. **CapBAC 守卫** — 所有写操作走 dispatch，前端 gate 只做 UI 级别的启用/禁用
5. **实时反馈** — 保存、发布等操作即时 flash 提示，不跳转
6. **预留 Admin Session** — 每个组件设计为可独立渲染的 `Phoenix.LiveComponent`，支持 `live_isolated` 挂载

### 1.2 两层架构

```
┌─────────────────────────────────────────┐
│           Page View (全屏管理)            │
│  路由: /admin/autoservice/...            │
│  每个页面是一个 LiveView                   │
│  使用完整布局: 侧边栏 + 顶栏 + 内容区       │
└─────────────────────────────────────────┘
                    │
                    │ 相同的组件，不同的容器
                    ▼
┌─────────────────────────────────────────┐
│        Admin Session (对话式管理)          │
│  未来: Admin Agent 以卡片形式展示组件        │
│  每个组件作为 Phoenix.Component 独立渲染    │
│  管理员通过对话操作: "帮我发布一个CR"         │
└─────────────────────────────────────────┘
```

---

## 二、路由设计

### 2.1 Tenant Admin 路由 (租户管理)

```
/admin/autoservice                          → MasterDashboardLive
/admin/autoservice/tenants/new              → TenantOnboardLive
/admin/autoservice/tenants/:tid              → TenantDashboardLive
/admin/autoservice/tenants/:tid/soul         → SoulEditorLive        ← NEW
/admin/autoservice/tenants/:tid/skills       → SkillManagerLive      ← NEW
/admin/autoservice/tenants/:tid/kb           → KbManagerLive         ← NEW
/admin/autoservice/tenants/:tid/cr           → CrDashboardLive       ← 增强
/admin/autoservice/tenants/:tid/versions     → VersionTimelineLive   ← NEW
/admin/autoservice/tenants/:tid/operators    → OperatorsLive         ← 增强
/admin/autoservice/tenants/:tid/preview      → SandboxPreviewLive    ← NEW
/admin/autoservice/tenants/:tid/prompt       → FastPromptEditorLive  ← NEW

/autoservice                                  → CustomerLive
/autoservice/operator                        → OperatorLive
/autoservice/admin                           → TenantAdminLive (聚合视图，快速入口)
```

### 2.2 Master Admin 路由 (平台管理)

```
/admin/autoservice/platform/soul             → PlatformSoulLive      ← NEW
/admin/autoservice/platform/skills           → PlatformSkillLive     ← NEW
/admin/autoservice/platform/priority         → PlatformPriorityLive  ← NEW
```

### 2.3 Future: Admin Session 路由

```
/admin/autoservice/session                   → AdminSessionLive      ← 未来
/admin/autoservice/session/:session_id        → 具体会话
```

---

## 三、组件架构

### 3.1 组件树

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/
├── autoservice/
│   ├── customer_live.ex              ← 已有
│   ├── operator_live.ex              ← 已有
│   ├── chat_ui.ex                    ← 已有 (ChatUI components)
│   └── admin/                        ← NEW 独立组件目录
│       ├── soul_editor_live.ex        ← Soul 编辑
│       ├── skill_manager_live.ex      ← Skill 管理
│       ├── kb_manager_live.ex         ← KB 管理
│       ├── cr_dashboard_live.ex       ← CR Dashboard (增强)
│       ├── version_timeline_live.ex   ← 版本时间线
│       ├── sandbox_preview_live.ex    ← 沙箱预览
│       ├── fast_prompt_editor_live.ex ← Fast Agent 提示词
│       ├── tenant_onboard_live.ex     ← 租户创建向导
│       ├── operator_manager_live.ex   ← Operator 管理
│       └── platform/
│           ├── platform_soul_live.ex
│           ├── platform_skill_live.ex
│           └── platform_priority_live.ex
│
├── master/
│   └── master_dashboard_live.ex       ← 已有 (Master Dashboard)
│
└── tenant/
    ├── tenant_admin_live.ex           ← 已有 (聚合视图/快速入口)
    ├── tenant_dashboard_live.ex       ← 已有
    └── tenant_onboard_live.ex         ← 已有
```

### 3.2 组件设计模式

每个组件遵循统一模式：

```elixir
defmodule EzagentPluginLiveview.AutoService.Admin.SoulEditorLive do
  use EzagentPluginLiveview, :admin_component  # ← 统一宏

  @moduledoc """
  Soul Editor — standalone admin component.

  ## Mount contexts
  - Page view: mounted at /admin/autoservice/tenants/:tid/soul
  - Card view: mounted via live_isolated in Admin Session
  - Embed: can be embedded via <.live_component module={...} id="soul-editor" tid={@tid} />
  """

  # Mount params
  # - :tid (required) — tenant ID
  # - :role (default: "customer") — soul role
  # - :embedded (default: false) — if true, render as card (no full layout)

  @impl true
  def mount(%{"tid" => tid} = params, _session, socket) do
    role = Map.get(params, "role", "customer")
    embedded? = Map.get(params, "embedded", "false") == "true"
    ...
  end
end
```

---

## 四、各模块详细设计

### 4.1 SoulEditorLive — Soul 编辑器

**路由**: `/admin/autoservice/tenants/:tid/soul`
**状态**: NEW

```
┌─────────────────────────────────────────────────────┐
│  header: "Soul 编辑"                    [Role: customer ▾]  │
├─────────────────────────────────────────────────────┤
│  ┌─ Tabs ─────────────────────────────────────────┐ │
│  │ [Source] [Diff] [Preview] [AI Assist]          │ │
│  ├────────────────────────────────────────────────┤ │
│  │                                                │ │
│  │  Source Tab:                                    │ │
│  │  ┌─ Layer Info ────────────────────────────┐   │ │
│  │  │ L0: framework/customer.md (read-only)    │   │ │
│  │  │ L1: platform/customer.md (master-edit)   │   │ │
│  │  │ L2: industry/零售/customer.md            │   │ │
│  │  │ L3: tenant → sandbox/souls/customer.md ★ │   │ │
│  │  └──────────────────────────────────────────┘   │ │
│  │                                                │ │
│  │  {{slot}} 占位符列表:                            │ │
│  │  [brand_name] [industry] [hotline]             │ │
│  │                                                │ │
│  │  ┌─ Editor ───────────────────────────────┐    │ │
│  │  │ # {{brand_name}} 智能客服                │    │ │
│  │  │                                        │    │ │
│  │  │ 你是 {{brand_name}} 的客服助手...        │    │ │
│  │  └────────────────────────────────────────┘    │ │
│  │                              [保存] [重置]      │ │
│  │                                                │ │
│  │  Diff Tab:                                     │ │
│  │  Sandbox ←→ Release 对比视图                    │ │
│  │  + 新增行 / - 删除行                             │ │
│  │                                                │ │
│  │  Preview Tab:                                  │ │
│  │  L0+L1+L2+L3 合成后的完整 CLAUDE.md              │ │
│  │  byte count / line count 统计                  │ │
│  │                                                │ │
│  │  AI Assist Tab: (future)                       │ │
│  │  自然语言输入 → AI 提议变更 → Accept/Reject       │ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**组件接口**:
```elixir
attr :tid, :string, required: true
attr :role, :string, default: "customer"
attr :embedded, :boolean, default: false

def soul_editor(assigns) do ... end
```

**CR 追踪**: 每次保存调用 `CrEngine.ensure_active_cr(tid)` + `record_path_changed(cr_id, "souls/customer.md")`

---

### 4.2 SkillManagerLive — Skill 管理器

**路由**: `/admin/autoservice/tenants/:tid/skills`
**状态**: NEW

```
┌─────────────────────────────────────────────────────┐
│  header: "Skill 管理"     [Role: customer ▾] [+ 新建]  │
├─────────────────────────────────────────────────────┤
│  ┌─ Filters ───────────────────────────────────┐   │
│  │ [搜索...]  [Layer: 全部 ▾] [Safety: 全部 ▾] │   │
│  └─────────────────────────────────────────────┘   │
│                                                    │
│  ┌─ L0 Framework ─────────────────────────────┐    │
│  │ ┌─────────┐ ┌─────────┐ ┌─────────┐        │    │
│  │ │order    │ │refund   │ │greeting │  ...   │    │
│  │ │lookup   │ │policy   │ │         │        │    │
│  │ │L0 安全   │ │L0 安全   │ │L0 普通   │        │    │
│  │ │(shadow) │ │         │ │         │        │    │
│  │ └─────────┘ └─────────┘ └─────────┘        │    │
│  └─────────────────────────────────────────────┘    │
│  ┌─ L1 Platform ──────────────────────────────┐    │
│  │ (同上卡片布局)                               │    │
│  └─────────────────────────────────────────────┘    │
│  ┌─ L2 Industry ──────────────────────────────┐    │
│  │ (同上卡片布局)                               │    │
│  └─────────────────────────────────────────────┘    │
│  ┌─ L3 Tenant ★ ──────────────────────────────┐    │
│  │ ┌─────────┐ ┌─────────┐                    │    │
│  │ │e2e-test │ │custom   │   [+ 新建]         │    │
│  │ │skill    │ │skill    │                    │    │
│  │ │L3 草稿   │ │L3 草稿   │                    │    │
│  │ └─────────┘ └─────────┘                    │    │
│  └─────────────────────────────────────────────┘    │
│                                                    │
│  [点击 Skill 卡片 → 弹出 SkillEditor]                │
└─────────────────────────────────────────────────────┘
```

**SkillCard 组件** (独立组件，可复用):
```elixir
attr :name, :string, required: true
attr :layer, :atom, required: true  # :l0 | :l1 | :l2 | :l3
attr :description, :string
attr :safety_class, :string         # "safe" | "critical"
attr :shadowed, :boolean, default: false

def skill_card(assigns) do
  ~H"""
  <div class={["rounded-lg border p-3 cursor-pointer hover:shadow-md transition",
    @shadowed && "opacity-50 bg-gray-50"]}>
    <div class="flex items-center justify-between">
      <span class="font-mono text-sm font-medium"><%= @name %></span>
      <span class={["text-xs px-1.5 py-0.5 rounded",
        @safety_class == "critical" && "bg-red-100 text-red-700",
        @safety_class == "safe" && "bg-green-100 text-green-700"
      ]}><%= @safety_class %></span>
    </div>
    <div class="flex items-center gap-2 mt-1">
      <span class="text-xs text-gray-400">L<%= layer_number(@layer) %></span>
      <%= if @shadowed do %>
        <span class="text-xs text-amber-500">被覆盖</span>
      <% end %>
    </div>
    <p class="text-xs text-gray-500 mt-1 line-clamp-2"><%= @description %></p>
  </div>
  """
end
```

---

### 4.3 KbManagerLive — KB 管理器

**路由**: `/admin/autoservice/tenants/:tid/kb`
**状态**: NEW (已有部分功能在 TenantAdminLive KB tab)

```
┌─────────────────────────────────────────────────────┐
│  header: "Knowledge Base 管理"                       │
├─────────────────────────────────────────────────────┤
│  ┌─ Tabs ─────────────────────────────────────────┐ │
│  │ [Sources] [URL抓取] [文件上传] [搜索]            │ │
│  ├────────────────────────────────────────────────┤ │
│  │                                                │ │
│  │  Sources Tab:                                  │ │
│  │  ┌─ Source List ───────────────────────────┐   │ │
│  │  │ Type    │ Source       │ Chunks │ Action │   │ │
│  │  │ url     │ example.com  │  12    │ [删除] │   │ │
│  │  │ file    │ manual.pdf   │   5    │ [删除] │   │ │
│  │  │ manual  │ kb-001       │   1    │ [删除] │   │ │
│  │  └──────────────────────────────────────────┘   │ │
│  │                                                │ │
│  │  URL抓取 Tab:                                   │ │
│  │  ┌──────────────────────────────────────┐       │ │
│  │  │ https://example.com/page            │ [抓取]│ │ │
│  │  └──────────────────────────────────────┘       │ │
│  │  ┌─ Job Status ────────────────────────┐       │ │
│  │  │ ● 抓取中... 3/15 页面, 2 索引         │       │ │
│  │  │ ✓ 完成: example.com (12 chunks)      │       │ │
│  │  └──────────────────────────────────────┘       │ │
│  │                                                │ │
│  │  文件上传 Tab:                                  │ │
│  │  [拖拽文件到此处 或 点击选择]                      │ │
│  │  支持: .pdf .xlsx .txt .md (最大 50MB)           │ │
│  │  ┌─ progress ───────────────────────┐          │ │
│  │  │ manual.pdf  ████████░░  80%      │          │ │
│  │  └──────────────────────────────────┘          │ │
│  │                                                │ │
│  │  搜索 Tab:                                      │ │
│  │  [搜索...]                                     │ │
│  │  ┌─ Results ──────────────────────────┐        │ │
│  │  │ kb-001: 退换货流程...              │        │ │
│  │  │ url:abc: 产品介绍页面内容...        │        │ │
│  │  └────────────────────────────────────┘        │ │
│  └────────────────────────────────────────────────┘ │
│                                                    │
│  ┌─ Actions ──────────────────────────────────┐    │
│  │ [从 sources 重建 KB]          [发布 KB 变更]  │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

### 4.4 CrDashboardLive — CR 管理 (增强)

**路由**: `/admin/autoservice/tenants/:tid/cr`
**状态**: 增强已有

```
┌─────────────────────────────────────────────────────┐
│  header: "Change Request"                           │
├─────────────────────────────────────────────────────┤
│  ┌─ Status Card ───────────────────────────────┐   │
│  │ Active CR: cr-a1b2c3d4e5f6                   │   │
│  │ Status: [draft]  Created: 2026-06-16 10:30   │   │
│  │                                              │   │
│  │ Tracked Changes (sandbox_diff):               │   │
│  │ ┌──────────────────────────────────────┐      │   │
│  │ │ ☑ souls/customer.md     +12 lines    │ [↩]  │   │
│  │ │ ☑ slots/customer.yaml   +3 lines     │ [↩]  │   │
│  │ │ ☑ skills/order-lookup   new file     │ [↩]  │   │
│  │ │ ☑ kb/sources: kb-001    added chunk  │ [↩]  │   │
│  │ └──────────────────────────────────────┘      │   │
│  │                                              │   │
│  │ [Refresh Lint]  [Publish]  [Cancel CR]        │   │
│  └──────────────────────────────────────────────┘   │
│                                                    │
│  ┌─ CR History ────────────────────────────────┐   │
│  │ cr-xxx │ published │ v3 │ 2026-06-15 │ [查看] │   │
│  │ cr-yyy │ cancelled │ —  │ 2026-06-14 │ [查看] │   │
│  └──────────────────────────────────────────────┘   │
│                                                    │
│  ┌─ Lint Results ──────────────────────────────┐   │
│  │ ✓ R01: No broken symlinks                   │   │
│  │ ✓ R02: All required files present           │   │
│  │ ⚠ R04: Slot template syntax warning         │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

### 4.5 VersionTimelineLive — 版本时间线

**路由**: `/admin/autoservice/tenants/:tid/versions`
**状态**: NEW

```
┌─────────────────────────────────────────────────────┐
│  header: "版本历史"                                  │
├─────────────────────────────────────────────────────┤
│  ○ v4  2026-06-16 14:20  cr-xxx  ← current         │
│  │                                                  │
│  ○ v3  2026-06-15 10:30  cr-yyy    [回滚到 v3]      │
│  │                                                  │
│  ○ v2  2026-06-14 09:00  cr-zzz    [回滚到 v2]      │
│  │                                                  │
│  ○ v1  2026-06-13 08:00  init                       │
└─────────────────────────────────────────────────────┘
```

---

### 4.6 FastPromptEditorLive — Fast Agent 提示词

**路由**: `/admin/autoservice/tenants/:tid/prompt`
**状态**: NEW

```
┌─────────────────────────────────────────────────────┐
│  header: "Fast Agent Prompt 编辑"                    │
├─────────────────────────────────────────────────────┤
│  ┌─ Current Value ─────────────────────────────┐   │
│  │ sandbox/config/fast_ack_prompt.md             │   │
│  └──────────────────────────────────────────────┘   │
│                                                    │
│  ┌─ Editor ───────────────────────────────────┐    │
│  │ You are the front-line acknowledgement      │    │
│  │ agent for {{brand_name}}.                   │    │
│  │                                            │    │
│  │ A heavier knowledge-base agent answers...   │    │
│  └────────────────────────────────────────────┘    │
│                              [保存] [重置为默认]     │
│                                                    │
│  ┌─ Slot 参考 ────────────────────────────────┐    │
│  │ {{brand_name}} = Acme Corp                  │    │
│  │ {{industry}} = 零售电商                      │    │
│  └──────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

### 4.7 SandboxPreviewLive — 沙箱预览

**路由**: `/admin/autoservice/tenants/:tid/preview`
**状态**: NEW

```
┌─────────────────────────────────────────────────────┐
│  header: "沙箱预览"                                  │
├─────────────────────────────────────────────────────┤
│  ┌─ Preview ───────────────────────────────────┐    │
│  │ (渲染后的完整 CLAUDE.md)                      │    │
│  │ 包含 L0+L1+L2+L3 合成 + skill index         │    │
│  │                                            │    │
│  │ [复制] [下载]                                │    │
│  └──────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

### 4.8 OperatorManagerLive — Operator 管理 (增强)

**路由**: `/admin/autoservice/tenants/:tid/operators`
**状态**: 增强已有 (disable 功能)

---

### 4.9 平台管理 (Platform)

**PlatformSoulLive**: `/admin/autoservice/platform/soul`
- L1 平台 Soul 编辑 (per-role)
- L2 行业 Soul 编辑 (per-industry+role)
- L3 模板编辑

**PlatformSkillLive**: `/admin/autoservice/platform/skills`
- L0/L1/L2 Skill 管理

**PlatformPriorityLive**: `/admin/autoservice/platform/priority`
- 4层优先级配置表
- Override 规则管理

---

## 五、设计风格预览

### 5.1 色彩系统

```
Header:     bg-gray-800 text-white          (深灰头)
Card:       bg-white border-gray-200        (白底灰边框)
Primary:    bg-blue-600 text-white          (蓝色主按钮)
Success:    bg-emerald-600 text-white       (绿色确认)
Danger:     bg-red-50 text-red-600          (红色删除)
Warning:    bg-amber-50 text-amber-800      (琥珀色警告)
Tab active: bg-white border-blue-700        (蓝色激活标签)
Tab inactive: text-gray-500                (灰色未激活)
Muted:      text-gray-400                  (弱化文字)
Code:       font-mono text-xs              (等宽代码)
```

### 5.2 页面布局预览

```
┌──────────────────────────────────────────────────────────┐
│  [ezagent]  Master Admin Dashboard        workspace://system │
├──────────────────────────────────────────────────────────┤
│  ┌─ KPI Cards ──────────────────────────────────────────┐ │
│  │ ┌──────────┐ ┌──────────┐ ┌──────────┐              │ │
│  │ │ Tenants  │ │Active CRs│ │Published │              │ │
│  │ │    5     │ │    3     │ │   12     │              │ │
│  │ └──────────┘ └──────────┘ └──────────┘              │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Tenants ───────────────────────────────────────┐     │
│  │ Tenant ID  │ Brand     │ CR      │ Status │ Action│     │
│  │ cinnox     │ Cinnox    │ [open]  │ 已发布  │ 管理 →│     │
│  │ demo-acme  │ Acme Corp │ [open]  │ 草稿    │ 管理 →│     │
│  │ ...                                              │     │
│  └─────────────────────────────────────────────────┘     │
│                                              [+ 新建租户] │
└──────────────────────────────────────────────────────────┘
```

### 5.3 侧边栏导航预览

```
┌──────────────────────┐
│  Tenant Admin        │
│                      │
│  📊 Overview         │
│  📝 Soul Editor      │
│  📚 Skills           │
│  🗄️ KB Manager       │
│  🔄 CR Dashboard     │
│  📋 Version History  │
│  👤 Operators        │
│  👁️ Sandbox Preview   │
│  ⚡ Fast Prompt      │
│                      │
│  ─────────────       │
│  Platform (Master)   │
│  🏗️ Platform Soul    │
│  🛠️ Platform Skills  │
│  ⚖️ Priority Config   │
│                      │
│  ─────────────       │
│  💬 Admin Session    │ ← 未来
└──────────────────────┘
```

### 5.4 组件卡片模式（Admin Session 预览）

```
┌──────────────────────────────────────────────────────────┐
│  Admin Session                               [agent: on] │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  [User] 帮我检查 cinnox 的当前 CR 状态                     │
│                                                          │
│  [Agent] cinnox 当前有一个 active CR:                      │
│  ┌─ CR Card ────────────────────────────────────────┐    │
│  │ CR: cr-a1b2c3d4                                  │    │
│  │ Status: draft  Files Changed: 3                   │    │
│  │ ┌──────────────────────────────────────┐          │    │
│  │ │ souls/customer.md   +12 lines        │          │    │
│  │ │ skills/order-lookup new file         │          │    │
│  │ │ kb: added 2 entries                  │          │    │
│  │ └──────────────────────────────────────┘          │    │
│  │ [Publish] [View Diff] [Cancel]                    │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  [User] 发布这个 CR                                       │
│                                                          │
│  [Agent] 正在发布... Lint 检查通过 ✓                        │
│  ┌─ Publish Result ────────────────────────────────┐     │
│  │ ✅ Published v5 at 2026-06-16 14:30               │     │
│  │ Release directory: release/v5                     │     │
│  │ Agent refresh triggered for demo-acme             │     │
│  └──────────────────────────────────────────────────┘     │
│                                                          │
│  ┌──────────────────────────────────────────────┐        │
│  │ [输入命令...]                          [发送] │        │
│  └──────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────┘
```

---

## 六、Admin Session 设计（未来）

### 6.1 概念

Admin Session = 一个特殊的 ezagent Session，其中：
- **Admin** 作为 user 加入
- **Admin Agent** 是一个有 admin 权限的 Agent
- 对话形式执行管理操作

### 6.2 交互模型

```
Admin 发送消息 "帮我发布 cinnox 的 CR"
  → Admin Agent 解析意图
  → 调用 CR publish dispatch
  → 返回结果卡片（含 lint 结果、发布版本等）
  → Admin 可以继续对话 "再检查一下 demo-acme"
```

### 6.3 技术实现

```elixir
# Admin Agent Behavior
defmodule Ezagent.Behavior.AdminAgent do
  use Ezagent.Behavior

  action :process_command,
    args: %{text: :string},
    returns: %{result: :map},
    caps: [:admin_session],
    description: "处理管理员的自然语言命令"

  def handle_process_command(%{text: text}, ctx) do
    # Intent parsing → dispatch to admin operations
    case parse_intent(text) do
      {:publish_cr, tid} ->
        CrEngine.publish(tid)
      {:check_cr, tid} ->
        {:ok, TenantConfig.read_cr(tid, "active")}
      {:edit_soul, tid, content} ->
        SoulStore.write(...)
      ...
    end
  end
end
```

### 6.4 卡片渲染

Admin Agent 的回复以**组件卡片**形式渲染：

```elixir
# 在 ChatUI.message_list 中识别 admin 消息类型
def render_admin_card(%{type: :cr_status, data: cr}) do
  ~H"""
  <div class="admin-card cr-card rounded-xl border border-gray-200 p-4 bg-white shadow-sm">
    <.cr_status_card cr={cr} />
  </div>
  """
end

def render_admin_card(%{type: :publish_result, data: result}) do
  ~H"""
  <div class="admin-card publish-card rounded-xl border border-emerald-200 p-4 bg-emerald-50">
    <h3>✅ Published {result.version}</h3>
    <p>{result.summary}</p>
  </div>
  """
end
```

---

## 七、实施计划

### Phase 1 — 核心组件独立化 (P0)
1. `SoulEditorLive` — Soul 编辑独立页面
2. `SkillManagerLive` — Skill 管理独立页面
3. `KbManagerLive` — KB 管理独立页面
4. `CrDashboardLive` 增强 — 变更追踪 + lint + CR history
5. `FastPromptEditorLive` — Fast Agent Prompt 编辑
6. 侧边栏导航更新

### Phase 2 — 管理增强 (P1)
7. `VersionTimelineLive` — 版本历史
8. `SandboxPreviewLive` — 沙箱预览
9. `OperatorManagerLive` 增强 — 完整 CRUD
10. CR sandbox_diff 追踪机制（后端）

### Phase 3 — 平台管理 (P2)
11. `PlatformSoulLive`
12. `PlatformSkillLive`
13. `PlatformPriorityLive`

### Phase 4 — AI 增强 (P3, 未来)
14. AI Assist 侧边栏
15. Admin Session + Admin Agent
16. 组件卡片渲染引擎

---

> **下一步**: Review 此设计方案，确认后开始 Phase 1 实施。
