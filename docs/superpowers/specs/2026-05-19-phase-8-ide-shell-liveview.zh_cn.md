# Phase 8 — IDE Shell LiveView Redesign (设计规范)

**作者**：Claude Opus 4.7 (1M)
**日期**：2026-05-19
**状态**：autonomous brainstorm + design + impl plan，分支 `feat/phase-8-ide-shell-liveview`，**不 merge 到 main**，待 Allen 审阅

---

## §0 目标 & 约束

### 目标

将 ezagent 的 LiveView 从"v1 顶部 5 链接 + 3 列布局"重做为完整可用的 **Agent IDE Shell**，与 CLI 使用方式保持高度一致，做到：

1. 多智能体 + 多 Session 工作负载下信息密度合理，不再噪声三列
2. 类型无关 (entity-agnostic) 一以贯之 —— 用户和 agent 都能用同一套界面操作
3. Activity Bar / Main Window / Right Sidebar / Status Bar 区域职责清晰，互不重复
4. 顶部 CmdK 命令面板可直达任何资源
5. PTY in browser、Chat、Routing 编辑、Workspace 编辑、Snapshots 观察等 v1 已有功能不丢

### 硬约束（来自 Allen 2026-05-19 directive）

- **只改交互体验 (UI/UX)，不动 runtime logic** —— 路由/dispatch/Behavior/Kind 模块 0 改动
- 完整保留 SPEC v2 后的 URI 形态（entity://、?action=）+ AgentTypeRegistry 已删的现状
- 入口为 `mix phx.server` 后浏览器 `/admin` (与今天相同)
- 不在 Phase 8 中 merge 进 main，待 Allen 审阅 + 确认后另行决定
- 中文 spec + 英文 docstring（与 SPEC v2 doc 一致）

### 不在 Phase 8 范围内

- 任何 runtime 行为变化（Routing 决策、dispatch 流程、Behavior 注册等）
- 新增任何 Kind 或 Behavior 模块
- 数据库 schema 变化
- API (`/api/v1`) 或 CLI (`mix ezagent`) surface 变化
- 移动端 / 触控适配（v1 仍是桌面浏览器优先）
- 主题切换（先固定浅色主题，per ide-shell prompt §0）

---

## §1 现状调研

### 当前 LiveView 模块清单

| 文件 | 行数 | 当前职责 |
|---|---|---|
| `admin_live.ex` | ~640 | Session 工作区（核心页面）：sessions sidebar + chat + members + debug |
| `admin/sessions_sidebar.ex` | small | 左侧 sessions 列表 + floating agents |
| `admin/chat_window.ex` | small | 中央 chat 流 + composer |
| `admin/member_panel.ex` | small | 右侧成员表 |
| `admin/debug_panel.ex` | small | 底部 debug + 手动 dispatch |
| `workspaces_live.ex` | 134 | Workspaces 列表 + 创建 |
| `workspace_detail_live.ex` | 451 | 单 workspace 编辑：members + templates + routing |
| `routing_live.ex` | ~400 | Routing 规则编辑 |
| `users_live.ex` | 210 | 用户列表 + 创建 + 改密码 |
| `user_caps_live.ex` | 223 | 用户 cap 列表 + 授权/撤销 |
| `user_api_keys_live.ex` | small | 用户 API key 管理 |
| `snapshots_live.ex` | small | KindSnapshot 行观察 |
| `entities_live.ex` | small | (PR #149 新加) KindRegistry 实时列表 |
| `agent_detail_live.ex` | small | Agent 状态详情 |
| `pty_terminal_live.ex` | small | xterm.js 终端 |
| `auto_derive_live.ex` | small | 自动派生的列表/详情（任意 Kind） |
| `feishu_bindings_live.ex` | small | Feishu open_id ↔ user 绑定管理 |
| **合计** | **3456** | 14 个顶级 LV + 4 个 admin 子组件 |

### 当前 admin_live 渲染结构 (render/1, 约 410-440 行)

```
<header>            ← 5 个文本链接 (Workspaces / Routing / Users / Snapshots / Entities)
<section style="3 列 flex">
  <sessions_sidebar>      (左)
  <chat_window>           (中)
  <member_panel>          (右)
</section>
<debug_panel>             (页面底部展开)
```

整张页面没有 Activity Bar / Status Bar / Right Sidebar 收起 / CmdK 命令面板。

### Prototype 目标 IA (来自 ide-shell prompt §2)

```
┌─────────────────────────────────────────────────────────────────────┐
│  Top Command Bar  [CmdK 输入] [窗口/通知/help/Entity]                │
├──┬──────────────────┬────────────────────────────────┬───────────┤
│A │ Resource Panel   │ Main Window                    │ Right     │
│c │                  │  ┌──── Editor Tabs ────┐       │ Sidebar   │
│t │ (Activity 上下文) │  │ Session | Terminal │       │           │
│i │                  │  └─────────────────────┘       │ (Context  │
│v │                  │  ┌────── Split Pane ───┐       │ /Members  │
│i │                  │  │ left tab │ right tab│       │ /Inspector│
│t │                  │  │          │          │       │)         │
│y │                  │  └─────────────────────┘       │           │
│B │                  │                                │ 默认收起  │
│a │                  │                                │           │
│r │                  │                                │           │
├──┴──────────────────┴────────────────────────────────┴───────────┤
│  Status Bar  [Entity] [workspace] [session] [agent状态] [Debug...]│
└─────────────────────────────────────────────────────────────────────┘
```

### Gap 分析（current LV → target IA）

| Gap 类别 | 数量 | 描述 |
|---|---|---|
| **缺失 shell 区域** | 6 | Activity Bar、Resource Panel、Top Command Bar、Right Sidebar (默认收起)、Status Bar、Editor Tabs |
| **缺失 page** | 2-3 | Settings（独立 LV）、Observability 聚合页、CommandPalette（modal） |
| **多 page 结构错位** | ~12 | 现有 admin_live 是 3 列；其它 LV 自己一套 header + 主体；都需要包裹在新 IDE Shell 里 |
| **缺失 primitives** | ~12 | StatusDot, Avatar, Tabs, Modal, Toast, TreeList, EmptyState, FormField, UriChip, Toolbar, Tooltip, SplitPane（`ezagent_domain_ui` 当前只有 button/card/badge/page_header/stat 5 个） |
| **命名错位** | ~5 | 顶级导航 "Chat" → "Sessions"，"Channels" → "Group Sessions"，"Integrations" → "Plugins"，"Floating agents" → "Unassigned Agents"，"@ agent" 已改为 "@ member" (PR #149 §C) |
| **Mode 切换** | 1 | `cc.agent[local-pty]` 的 Chat / PTY 切换 + split view 当前不存在（PTY 是独立 page）；需要在 Main Window 内 toggle |

---

## §2 设计决策

### 决策 D1 — Shell 是 stateless Phoenix.Component，不是 LiveView

**选择**：`Ezagent.UI.IdeShell` 等 IDE Shell 区域用 `Phoenix.Component` 实现（stateless functional component），状态完全由父 LiveView 持有 + 通过 attrs 传入。

**理由**：
- 每个 LV 页面有自己的 sessions/streams/state，shell 区域要适配不同的 page 上下文
- LiveComponent 有自己的 PID + 生命周期，对静态布局壳来说过重
- 与 v1 admin_live 已采用的 `admin/sessions_sidebar.ex` etc 一致

**替代方案**：LiveView 直接渲染所有 shell —— 拒绝，因为每个 LV 都要重复实现 shell 布局，不复用

### 决策 D2 — Activity Bar 由 router 决定，不在 socket state 里

**选择**：Activity Bar 哪个 item 高亮、Resource Panel 展示什么，由当前 URL 决定（`@socket.view` / `@current_path`）。Activity 切换 = 浏览器导航。

**理由**：
- 每个 Activity 对应一个或一组路由（Sessions → `/admin`, Workspaces → `/admin/workspaces`, ...）
- 路由是 web 平台的自然导航单元，Phoenix LiveView 的 `live_session` + `live_redirect` 天生支持
- 避免在多个 LV 之间同步 "当前 Activity" 状态

**替代方案**：单一 mega-LV 持有所有 Activity 内部状态 —— 拒绝，违反 v1 已分 14 个 LV 的现状 + 增加内存/复杂度

### 决策 D3 — Editor Tabs 范围限于 Main Window 内

**选择**：`<EditorTabs>` 是 Main Window 内的 tab strip（多 session、多 terminal、多 workspace tab 可同开）。每个 tab 在当前 LV socket assign 里。不跨 LV 持久化。

**理由**：
- 跨 LV tabs 需要 cross-route 状态同步（cookie/ETS/PubSub），复杂度高
- 用户期望"打开 admin 页 → 看到我之前的 session tabs" 可以通过 URL state 表达（`?tabs=session://X,session://Y`）
- 简单实现：Sessions LV 内部 stream of opened tabs；其它 LV 暂不实现 tabs（一个 main pane）

**替代方案**：浏览器 localStorage 同步 tabs —— 拒绝，前端状态多源真实

### 决策 D4 — Settings & Observability 是新 LV，不复用 admin 已有 page

**选择**：
- `SettingsLive` 新建 (`/admin/settings`)：用户偏好 + 快捷键 + 当前 Entity + Access & Identity 入口（链接到 `/admin/users`）+ 系统显示设置
- `ObservabilityLive` 新建 (`/admin/observability`)：聚合 Debug Events、Audit Log、CC Bridges、Snapshots、Health Overview 五个 tab

**理由**：
- ide-shell prompt §2 明确列了这两个 page 的 placeholder
- 把 admin_live 的 debug_panel 内容外提到 Observability 后，admin 主页更聚焦聊天工作流
- Settings + Observability 都是 v1 完全缺失的页面 —— 必须新建

**替代方案**：把 Debug 留在 admin_live 底部 —— 拒绝，违反 Activity Bar 命名约定 + 信息密度差

### 决策 D5 — Command Palette 是 Modal，不是独立 page

**选择**：`<CommandPalette>` 是浮层 modal，由 `<TopCommandBar>` 的 CmdK 输入框触发。键盘 `⌘K / Ctrl+K` 全局快捷键打开。

**理由**：
- VS Code/Slack/Linear 全是 modal 模式 —— 用户已习惯
- 不消耗一个 Activity Bar 槽位（Activity Bar 已 7 个）
- Phoenix LiveView 通过 `phx-window-keydown` 监听快捷键 + `Phoenix.LiveView.JS.show/hide` 切换 modal 显示

**替代方案**：Activity Bar 加 Search/Command 项 —— 拒绝，命令面板是动作 + 搜索两用，不是导航 surface

### 决策 D6 — CmdK 后端实现：纯客户端 fuzzy match，结果走 LV event

**选择**：CommandPalette 输入触发 `phx-keyup` event，LV server-side 跑 fuzzy match over `[sessions, entities, actions, workspaces, plugins, routes]` 然后 push 结果回客户端。

**理由**：
- 这些列表都很短（数十 ~ 数百），server-side fuzzy match 简单
- LV stream 天然支持流式更新结果
- 不引入 client-side JS 索引依赖

**替代方案**：client-side Fuse.js —— 拒绝，前端 JS 复杂度增加 + 数据要序列化到客户端

### 决策 D7 — IDE Shell 不强制每个 page 都用

**选择**：admin_live (Sessions) 首先全面接入 IDE Shell（最高价值）。其它 LV 渐进迁移：
- 强制接入：admin_live (Sessions)、entities_live (Entities，从 /admin/agents 升级而来)、workspaces_live + workspace_detail_live、routing_live、SettingsLive (新)、ObservabilityLive (新)
- 包裹 shell header + 保持原主体：users_live、user_caps_live、user_api_keys_live、snapshots_live、agent_detail_live、pty_terminal_live、auto_derive_live、feishu_bindings_live
- 最低工作量：所有 LV 共用一个 `IdeShellLayout` HEEx 模板，定义 Activity Bar + Top Command Bar + Status Bar，子 LV 的 render/1 输出主体 + Resource Panel + Right Sidebar 内容

**理由**：
- 接入工作量正比于页面价值
- Phase 8 不是完美重写，是"主流程改造好，长尾页面统一外壳"
- 后续可根据使用频率把更多页面提升为"完整 IDE Shell 接入"

**替代方案**：14 个 LV 全部重写为 IDE Shell —— 拒绝，工作量 3-4x，价值边际递减

### 决策 D8 — 现有 ezagent_domain_ui 是扩展目标，不另起炉灶

**选择**：所有新的 primitives + 领域组件都加到 `apps/ezagent_domain_ui/lib/ezagent_domain_ui/components.ex`（或拆分为多个文件如 `primitives.ex`, `ide_shell.ex`, `domain.ex`）。当前已有 `button/card/badge/page_header/stat`，继续扩展。

**理由**：
- ezagent_domain_ui 是已有的"shadcn-inspired"小库
- Allen 已在 ide-shell prompt §3 明确写"请在原型中**扩展这套词汇**；不要另起炉灶"
- 单一组件库 = 一致性

**替代方案**：用 LiveView 内置的 `core_components.ex` —— 拒绝，那是 Phoenix 生成的样板，不是设计系统

### 决策 D9 — Tests 只覆盖 shell + 关键页面

**选择**：
- 单元测试：`IdeShell`, `ActivityBar`, `ResourcePanel`, `MainWindow`, `EditorTabs`, `StatusBar`, `CommandPalette` 各一个 component test
- LV 集成测试：admin_live, entities_live, SettingsLive, ObservabilityLive 4 个 LV 各 1-2 test 覆盖 mount + 主交互
- 其它 LV：维持现有 test 不破

**理由**：
- Phase 8 不动 runtime logic，runtime tests 都应 pass
- shell 组件是 UI 骨架，单元测试快 + 高 ROI
- 复杂交互测试（CmdK fuzzy 搜索、split pane）放到 Phase 9 优化

**替代方案**：完整 visual regression test (Playwright snapshots) —— 拒绝，phase 8 内 ROI 太低，留给 Phase 9 polish

---

## §3 信息架构

### Activity Bar 顶级项（左→右图标顺序）

| 顺序 | Activity | 图标 (lucide-style 文字提示) | 路由（默认 + 子路由） | Resource Panel 内容 |
|---|---|---|---|---|
| 1 | **Sessions** | `message-square` | `/admin` | Direct Sessions / Group Sessions / Unassigned Agents |
| 2 | **Workspaces** | `folder` | `/admin/workspaces`, `/admin/workspaces/:name` | Workspace 列表 + tenant 分组 |
| 3 | **Identities** | `users` *(per grill-fix R-2: Users + Agents 同级 entity sub-types)* | `/admin/entities` (PR #149) | Filter chips: All / entity://user / entity://agent / session / workspace / template / resource / system |
| 4 | **Routing** | `route` | `/admin/routing` | Rules / Targets / Transforms / Registry |
| 5 | **Plugins** | `puzzle` | (no top-level LV; placeholder + 链接到 `/admin/feishu/bindings` + `/admin/auto/:kind`) | Installed Plugins / Bindings / Generated UI |
| 6 | **Observability** | `activity` | `/admin/observability` (新) | Overview / Events / Audit Log / Bridges / Snapshots |
| 7 | **Settings** | `settings` | `/admin/settings` (新) | Account / Preferences / Keyboard / Access & Identity / System |

**注**：
- 不再有 "Floating Agents" 单独 Activity；它现在是 Sessions Activity 的 Resource Panel 内的 section "Unassigned Agents"
- "Users" 不占独立 Activity；它通过 Identities Activity 的 user filter chip 或 Settings → Access & Identity → "Manage Users" 链接打开
- 旧的 5 个顶部水平链接（Workspaces / Routing / Users / Snapshots / Entities）全部废弃；改由 Activity Bar 表达

### Top Command Bar 元素（左→右）

| 元素 | 行为 |
|---|---|
| `<.uri_chip uri={@current_entity_uri} />` | 当前登录 Entity；点击打开 Account modal（Settings 子集） |
| Workspace selector | 当前 Workspace 名 + dropdown 切换（v1 单 workspace 时静态显示 "default"） |
| **CmdK input** (中央，宽 240px) | placeholder "搜索 sessions / entities / actions ... (⌘K)"；点击或快捷键打开 CommandPalette |
| Notifications bell | 显示 unread debug events 数；点击展开 Observability/Events 的 quick list |
| Help icon | 链接到 `/admin/docs` (后续 phase 实现) |

### Status Bar 段（左→右）

| 段 | 数据来源 |
|---|---|
| Entity icon + `current_entity_uri` | session cookie |
| Workspace icon + workspace name | v1 静态 "default" |
| Session icon + active session URI | admin_live 当前 session_uri |
| Agents alive count | `Ezagent.KindRegistry.list_all() \|> filter(entity://agent/*) \|> count` |
| Bridges connected count | `EzagentPluginCc.BridgeRegistry.list_all()` 长度 |
| Debug events count + 🐞 button | 点击切到 Observability/Events |
| Version | 编译时常量 `Application.spec(:ezagent_core, :vsn)` |

Status Bar 内容是**只读的 derive**；点击段触发跳转或弹窗，不持有自己的状态。

### Main Window editor tab 模型

Main Window 顶部是 `<.editor_tabs>`：

- 每个 tab 有 type: `:session` | `:terminal` | `:workspace` | `:routing` | `:agent_detail` | `:auto_derive`
- 每个 tab 持有自己的 socket assign（tab 级状态）
- 关闭 tab 把它从 assign 列表移除
- 切换 tab = `phx-click="select_tab"` 改 `@active_tab_index`
- v1 admin_live 只支持 Session tabs；其它 LV 在 Phase 8 暂不支持多 tab（一个 page = 一个 tab）

### Right Sidebar 上下文模型

Right Sidebar 默认 **折叠为窄栏**（只显示一个展开按钮 + 当前 context 的小图标）。点击展开。内容根据 Main Window 当前 tab 类型动态：

- Tab = `:session` → `<.member_roster>` + `<.context_panel>` (session URI + room info)
- Tab = `:terminal` → `<.pty_meta>` (cwd + os_pid + 重启按钮)
- Tab = `:workspace` → `<.workspace_inspector>` (member count + template count + routing rules)
- Tab = `:routing` → `<.rule_inspector>` (selected rule 的详情)
- Tab = `:agent_detail` → `<.context_panel>` (agent type + caps)

---

## §4 组件清单

### 4.1 新的 IDE Shell 组件 (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/ide_shell.ex`)

```elixir
defmodule Ezagent.UI.IdeShell do
  use Phoenix.Component

  attr :current_entity_uri, :string, required: true
  attr :current_path, :string, required: true       # 用于 Activity Bar 高亮
  attr :workspace_name, :string, default: "default"
  attr :status, :map, required: true                # %{agents_alive: N, bridges: N, debug_events: N, version: "..."}
  slot :resource_panel, required: true              # 当前 Activity 的 Resource 树
  slot :main_window, required: true                 # editor tabs + content
  slot :right_sidebar                               # 可选 context panel
  slot :command_palette                             # CommandPalette modal (隐藏；CmdK 触发)

  def ide_shell(assigns)  # 渲染 6 区域骨架
end
```

子组件 (同文件或拆分):
- `activity_bar/1` — 7 个图标 + tooltip + 高亮
- `top_command_bar/1` — entity chip + workspace selector + CmdK input + notifications + help
- `status_bar/1` — 6 段 + 点击行为
- `editor_tabs/1` — tab 列表 + close X + click 切换
- `split_pane/1` — 可选垂直/水平 split，默认禁用，用户主动开启
- `command_palette/1` — modal，phx-window-keydown trigger，fuzzy 搜索

### 4.2 新的 primitives (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/primitives.ex`)

| Component | Props | 说明 |
|---|---|---|
| `status_dot/1` | `color: :green \| :gray \| :amber \| :red`, `pulse: bool` | 8x8px 圆点 |
| `avatar/1` | `uri: %URI{}`, `size: :xs \| :sm \| :md` | URI 首字母组合或 Kind 图标 |
| `tabs/1` | `items: [{label, key}]`, `selected: key`, `on_select: event` | 水平标签条 |
| `modal/1` | `id`, `open: bool`, slots: header/body/footer | LiveView.JS 控制显示 |
| `toast/1` | `kind: :info \| :success \| :error`, `text` | 右下角浮现，5s 自动消失 |
| `tree_list/1` | slot: items（嵌套） | Resource Panel 树形列表 |
| `empty_state/1` | `title`, `description`, slot: action | 空表/空 Activity 的 placeholder |
| `form_field/1` | `name`, `type`, `label`, `error`, `placeholder` | label + input + help + error 一组 |
| `uri_chip/1` | `uri: %URI{} \| String.t()`, `copyable: bool` | 等宽胶囊渲染 URI |
| `toolbar/1` | slot: buttons | editor tab 内的小工具栏 |
| `tooltip/1` | `text`, slot: target | hover 提示 |
| `icon/1` | `name: String.t()`, `size: :xs \| :sm \| :md \| :lg` | lucide-icons style；先用纯 SVG sprite 或简单 emoji fallback |

### 4.3 现有 components.ex 扩展

`<.button>` 加 `loading: bool`, `size: :xs`, `:sm`；`<.badge>` 加 `:info` 变体；`<.card>` 加 `density: :compact`；其它已有的保留。

### 4.4 领域专用可复用组件 (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/components/`)

新建以下子目录文件：

- `session_resource_panel.ex` (`<.session_resource_panel>`) — Direct Sessions + Group Sessions + Unassigned Agents 三个 collapsible section
- `chat_stream.ex` (`<.chat_stream>`) — 从现有 `admin/chat_window.ex` 的消息流部分提取
- `message_composer.ex` (`<.message_composer>`) — 从现有 chat_window 的 form 部分提取，包含 @-mention dropdown + 文件上传
- `member_roster.ex` — 已存在为 `admin/member_panel.ex`，迁移路径
- `context_panel.ex` (`<.context_panel>`) — 新组件，根据 Main Window tab 类型动态渲染
- `template_class_picker.ex` (`<.template_class_picker>`) — 从 workspace_detail_live 提取
- `auto_form.ex` (`<.auto_form>`) — 从 workspace_detail_live + user_caps_live 提取
- `rule_table.ex` (`<.rule_table>`) — 从 routing_live 提取
- `rule_inspector.ex` — 新
- `key_vault.ex` — 从 user_api_keys_live 提取
- `pty_viewer.ex` — 从 pty_terminal_live 提取
- `bridge_table.ex` — 已存在为 admin_live 内的 CC Bridges 表，迁移
- `event_table.ex` — 已存在为 admin/debug_panel.ex 的 CC Events 区，迁移
- `audit_log_stream.ex` — 已存在为 admin/debug_panel.ex 的 Audit Log，迁移
- `health_overview.ex` — 新组件
- `snapshot_table.ex` — 从 snapshots_live 提取（其内容基本就是这个）
- `kind_instance_table.ex` + `kind_detail_card.ex` — 从 auto_derive_live 提取

### 4.5 新的 LV pages

| 文件 | 路由 | 行数估计 |
|---|---|---|
| `settings_live.ex` (新) | `/admin/settings` | ~120 |
| `observability_live.ex` (新) | `/admin/observability` | ~150 |

Settings 内容：Account 表单（display name 等 placeholder）、Preferences (theme 选择 placeholder)、Keyboard (`<.shortcut_list>`)、Access & Identity (链接到 Users/Caps/API keys)、System (display options placeholder)。

Observability 内容：5 个 tab — Overview (`<.health_overview>`)、Events (`<.event_table>`)、Audit Log (`<.audit_log_stream>`)、Bridges (`<.bridge_table>`)、Snapshots (`<.snapshot_table>`)。

### 4.6 router 改动

新加：
```elixir
live "/admin/settings", SettingsLive
live "/admin/observability", ObservabilityLive
```

移除：旧的 top-level 链接（admin_live header 不再有这些）。

---

## §5 实施路径

### 阶段 A — 基础设施 (commit 1)

1. 加 primitives 到 `ezagent_domain_ui/primitives.ex`（12 个）
2. 加 IDE Shell 组件到 `ezagent_domain_ui/ide_shell.ex`（IdeShell + ActivityBar + TopCommandBar + StatusBar + EditorTabs + SplitPane + CommandPalette）
3. 写 unit tests 给 primitives + shell（用 `Phoenix.LiveViewTest.render_component/3`）
4. 简单的 lucide-icons 风格 SVG sprite 或 emoji icon fallback —— 避免引入新 JS 依赖（Phase 9 可以换 heroicons 或类似）

### 阶段 B — Sessions Activity (commit 2)

1. 创建 `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/components/` 目录
2. 把 admin/chat_window.ex 拆出 `<.chat_stream>` + `<.message_composer>`
3. 把 admin/sessions_sidebar.ex 升级为 `<.session_resource_panel>`（加 Direct/Group 分组 + Unassigned section）
4. 把 admin/member_panel.ex 升级为 `<.member_roster>`
5. Rewrite admin_live.ex render/1 → 用 IdeShell 包裹，Resource Panel = SessionResourcePanel，Main Window = EditorTabs + 当前 session 的 chat（先单 tab，后续支持多 session tab）
6. admin_live 集成 test：mount, switch session, send message, audit row appears

### 阶段 C — 其它高优先级 Activity (commit 3)

1. workspaces_live + workspace_detail_live：包裹 IdeShell，Resource Panel = workspace 列表，Main Window = workspace 编辑
2. entities_live (PR #149 已存在)：包裹 IdeShell，Resource Panel = filter chips
3. routing_live：包裹 IdeShell，Resource Panel = MentionRouting/SessionRouting 表选择，Main Window = RuleTable，Right Sidebar = RuleInspector

### 阶段 D — 新页面 (commit 4)

1. settings_live.ex 新建（含 ShortcutList placeholder）
2. observability_live.ex 新建（5 个 tab 聚合）
3. router 加新路由
4. Activity Bar 高亮逻辑覆盖这两个 page

### 阶段 E — 其它 LV 浅迁移 (commit 5)

1. users_live, user_caps_live, user_api_keys_live, snapshots_live, agent_detail_live, pty_terminal_live, auto_derive_live, feishu_bindings_live → 全部包裹 IdeShell（保持 Main Window 内主体不变；Resource Panel 留空或简单 breadcrumb；Right Sidebar 不强制）
2. 这一步是"全站统一外壳"，不重写每个页面的业务逻辑

### 阶段 F — CmdK Command Palette (commit 6)

1. CommandPalette modal 接 LiveView event
2. 后端 fuzzy 搜索：扫 `Ezagent.KindRegistry.list_all/0` + 路由表 + 注册的 actions
3. 结果按 group 渲染（Sessions / Entities / Actions / Workspaces / Routes）
4. 键盘 ↑↓ Enter 选择
5. 把 modal 注入到 IdeShell 的 command_palette slot

### 阶段 G — 验证 + 截图 (commit 7)

1. `mix ezagent.db.reset` 后启动 phx，agent-browser 走一遍：
	- 登录 → admin (Sessions Activity)
	- 切到 Identities Activity → 看到 entity:// 列表
	- 切到 Workspaces Activity → 创建一个新 workspace
	- 切到 Routing Activity → 加一条规则
	- 切到 Observability Activity → 看到 Audit Log
	- 切到 Settings Activity → 看到 shortcut list
	- ⌘K 打开 Command Palette
2. 截图每个 Activity；mp4 demo
3. 全 12 app `mix test` 0 failures

### 阶段 H — 文档 + push (commit 8)

1. 更新 `docs/notes/prototype-design-prompt.md` 的 §3 组件清单段，标注哪些 prototype 组件已落地 vs 待实现
2. 写 `docs/notes/phase-8-deploy-notes.md`：操作员如何在分支上验证
3. push 分支 `feat/phase-8-ide-shell-liveview` 到 remote（不 PR、不 merge）
4. 发 Allen：spec 中文版 + 分支名 + how-to-verify + 截图/视频

---

## §6 验收标准 (Allen 回来时手动验证)

在 `feat/phase-8-ide-shell-liveview` 分支上：

```bash
cd /Users/h2oslabs/Workspace/esr-ng
git checkout feat/phase-8-ide-shell-liveview
mix ezagent.db.reset && mix ecto.migrate
EZAGENT_HOME=... mix phx.server
```

浏览器打开 http://127.0.0.1:10042/admin → 应当看到：

1. ✓ 最左侧有 Activity Bar (7 个图标)
2. ✓ Activity Bar 右侧是 Resource Panel (当前 Activity 的上下文)
3. ✓ 顶部有 Top Command Bar (含 CmdK 搜索框)
4. ✓ 中央 Main Window 显示 chat (默认 Sessions Activity)
5. ✓ Right Sidebar 默认窄栏 + 展开按钮，展开后显示成员
6. ✓ 底部 Status Bar 显示 Entity / Workspace / Agents 计数 / Bridges 计数 / version
7. ✓ ⌘K 打开 Command Palette modal
8. ✓ 切换 Activity 触发浏览器导航；URL 改变；高亮跟随
9. ✓ Settings, Observability 两个新 page 可用
10. ✓ 不再有顶部水平 5 链接条
11. ✓ 12 个 app 全 `mix test` 0 failures
12. ✓ Sessions, chat send, agent 反应 等 v1 行为完整保留

---

## §7 不变性测试 (invariant tests)

按 memory `feedback_completion_requires_invariant_test` —— Phase 8 的 "done" 标准是写一个会 fail when goal unmet 的测试：

- `test/ide_shell_invariant_test.exs`: 访问 `/admin`，render 输出包含 `<ide-shell>` 根元素 + 7 个 activity bar items + `<status-bar>` + `<top-command-bar>`，且**不**包含 "Workspaces →" 等旧顶部链接文字
- 这个测试不验证视觉细节（CSS），只验证 IA 结构

---

## §8 风险 & mitigation

| 风险 | mitigation |
|---|---|
| Phase 8 改动量大，可能 break 某些现有页面交互 | 阶段 E (浅迁移) 优先保持现有页面主体不变；只外加 shell 框架 |
| CmdK fuzzy 搜索性能 | KindRegistry 当前只有数十条；fuzzy match O(n) 完全可接受 |
| Activity Bar 图标依赖 | 用 emoji 或简单 SVG fallback；不引入 lucide-icons npm 依赖 |
| 测试覆盖断裂 | 阶段 A 写 shell 单元测试；阶段 B/C/D 写 LV 集成测试；阶段 E 旧 LV 测试不动 |
| 多 tab 状态管理复杂 | Phase 8 admin_live 内部支持多 session tab；其它 LV 单 tab；不跨 LV 同步 tabs |

---

## §9 后续 (Phase 9+)

不在 Phase 8 内：

- 暗色主题切换
- 移动端响应式
- 真实 lucide-icons 集成（取代 emoji fallback）
- 多 tab 跨 LV 同步（cookie 或 ETS 持久化）
- 拖拽改 split pane 比例
- visual regression test (Playwright snapshot)
- CmdK 加更多动作（agent.spawn / session.create 等 in-app dispatch）
- agent-browser scenario test 替代 manual verify
