# Agent + Orchestrator UI 审计 — 2026-05-23

## §0 审计背景

- **诉求**: Allen 飞书 2026-05-23 — "审计现有 UI 中 agent + orchestrator 相关功能。已有哪些?缺什么?实现是否遵循 ezagent 最佳分层实践(三层规则、domain_ui 只放原语、dispatch 不变式)?"
- **范围**: 只读调查 `apps/ezagent_domain_ui/`、`apps/ezagent_plugin_liveview/`、`apps/ezagent_web/lib/ezagent_web/router.ex`、`apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/`,以及第 7 阶段 Kinds(`Ezagent.Entity.AgentTemplate`、`Ezagent.Entity.SessionTemplate`、`Ezagent.Behavior.Template`)。只输出文档 commit,不改代码。
- **标尺**: `ezagent-developer` SKILL.md "Design Principles" P1-P26(PR #252 合并的权威整合集)、**三层规则(P8/P9)**、**UI Contract** §"3-layer UI architecture" + §"Nested shell architecture" + DO/DON'T 清单、以及 dispatch/cap 不变式 P14/P15。

本文为 §1 清单、§2 缺口表、§3 逐元素分层裁定、§4 跨层违规清单、§5 最佳实践裁定、§6 V1 阻塞项 vs V2 待办建议。

## §1 清单 — 所有涉及 agent/orchestrator 的 LV / shell 组件

`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/` 下 24 个 LiveView 模块;其中 13 个涉及 agent / orchestrator / template。Tier-2(`ezagent_domain_ui`)原语组件:14 个原子 + 4 个 shell 组件 + 1 个 auto-derive + 3 个 SessionView。Tier-3 plugin-LV 组合:2 个(`MemberPanel`、`SessionEditor`)。

### 路由(交叉引用 `apps/ezagent_web/lib/ezagent_web/router.ex`)

| URL | LV 模块 | Shell perspective | 内容 |
|---|---|---|---|
| `/sessions` | `EzagentPluginLiveview.AdminLive` | `:workspace` | Session 活动(SessionEditor + MemberPanel + 视图切换) |
| `/admin` | `EzagentPluginLiveview.AdminDashboardLive` | `:admin` | KPI 仪表盘 |
| `/admin/logs` | `EzagentPluginLiveview.ObservabilityLive` | `:admin` | Audit 流、CC bridges、kind_snapshots SQL |
| `/admin/registry` | `EzagentPluginLiveview.EntitiesLive` | `:admin` | KindRegistry 浏览器(含 `template://`) |
| `/admin/snapshots` | `EzagentPluginLiveview.SnapshotsLive` | `:admin` | `kind_snapshots` 表 dump+删除 |
| `/admin/settings` | `EzagentPluginLiveview.SettingsLive` | `:admin` | 管理员 SMTP / 注册域配置 |
| `/workspaces` | `EzagentPluginLiveview.WorkspacesLive` | `:admin` | Workspace 列表 |
| `/workspaces/:name` | `EzagentPluginLiveview.WorkspaceDetailLive` | `:admin` | 成员、**遗留** workspace.session_templates、routing |
| `/routing` | `EzagentPluginLiveview.RoutingLive` | `:workspace` | 路由规则编辑(默认 global) |
| `/identities` | `EzagentPluginLiveview.IdentitiesLive` | `:workspace` | 通讯录 — users + agents |
| `/identities/agents/new` | `EzagentPluginLiveview.AgentNewLive` | `:workspace` | 创建 agent(flavor + 名 + caps + cwd + with-PTY) |
| `/identities/agents/:uri` | `EzagentPluginLiveview.AgentDetailLive` | `:workspace` | 单 agent 状态、生命周期、bridge、内联 PTY |
| `/identities/agents/:uri/caps` | `EzagentPluginLiveview.EntityCapsLive` | `:workspace` | 单实体 cap 授予/撤销 |
| `/identities/agents/:uri/api-keys` | `EzagentPluginLiveview.UserApiKeysLive` | `:workspace` | curl agent owner User 的 API keys |
| `/identities/agents/:uri/terminal` | `EzagentPluginLiveview.TerminalLive` | `:workspace` | 独立 xterm 窗口 |
| `/plugins` | `EzagentPluginLiveview.PluginsLive` | `:workspace` | Registry 驱动的插件卡片 |
| `/plugins/feishu/bindings` | `EzagentPluginLiveview.FeishuBindingsLive` | `:workspace` | 飞书 chat-id ↔ session 绑定 |
| `/plugins/auto/:kind` / `:kind/:uri` | `EzagentPluginLiveview.AutoDeriveLive` | `:workspace` | 通用 Kind 浏览器(slice inspect dump) |
| `/profile` | `EzagentPluginLiveview.ProfileLive` | `:workspace` | 个人资料 / 显示名 / 头像 |

### Tier-2 组件(`ezagent_domain_ui`)

| 模块 | Tier | 角色 |
|---|---|---|
| `EzagentDomainUi.Components`(button/card/badge/page_header/breadcrumb/stat/plugin_card) | 1(原子) | 页面级原子 |
| `EzagentDomainUi.Primitives`(status_dot/avatar/tabs/modal/toast/tree_list/empty_state/form_field/uri_chip/uri_picker/toolbar/tooltip/icon) | 1(原子) | 低级原子 |
| `EzagentDomainUi.IdeShell.ide_shell_outer` | 1(chrome) | 外壳 — header + CmdK slot + body slot |
| `EzagentDomainUi.WorkspaceShell.workspace_shell` | 1(chrome) | workspace 内层(活动栏/资源面板/主区/右侧栏/状态栏) |
| `EzagentDomainUi.AdminShell.admin_shell` | 1(chrome) | admin 内层 |
| `EzagentDomainUi.AutoDerive` | 2(工具) | 任意活 Kind 的列表/详情自省 |
| `EzagentDomainUi.SessionViewRegistry` + `SessionView` | 2(注册表) | 插件注册主区视图 |
| `EzagentDomainUi.Pty.Terminal` / `TerminalSeam` / `TerminalView` | 2(PTY) | xterm.js Phoenix hook + dispatch 接缝 + SessionView 实现 |
| `EzagentDomainUi.Routing.RoutingView` | 2(SessionView) | Routing 作为 SessionView |
| `EzagentDomainUi.UriOptions` | 2(数据) | caller 授权的 URI 选项查找 |
| `EzagentDomainUi.CommandSource` | 2(数据) | CmdK 纯排名函数 |
| `EzagentDomainUi.Gettext` | 2(i18n) | Tier-2 i18n 后端 |

### Tier-3 插件 LV 组合

| 模块 | 角色 |
|---|---|
| `EzagentPluginLiveview.AppShell.app_shell` | 唯一入口 — 一次性接线 CmdK,接受 `perspective` |
| `EzagentPluginLiveview.CommandPaletteComponent` | 有状态 CmdK LiveComponent |
| `EzagentPluginLiveview.Admin.SessionEditor` | session header + 主视图 slot + 输入 |
| `EzagentPluginLiveview.Admin.MemberPanel` | 统一成员列表 + 邀请 modal |
| `EzagentPluginLiveview.Views.ConversationView` | 聊天流的 SessionView 实现 |

## §2 缺口 — 缺什么、严重度

agent/orchestrator 相关 Phase-7 交付物,UI 覆盖**部分**:agents 完备(创建/列表/详情/caps/terminal/重启),但整套 **AgentTemplate / SessionTemplate / orchestrator working-copy / Generator** 完全不可见。Phase-7 引入了 8+ 个运维相关概念,UI 只暴露了 1 个(`/identities/agents/*`)。

| # | 缺失功能 | 现状 | 严重度 | 所有者 | 修复草图 |
|---|---|---|---|---|---|
| G-1 | **AgentTemplate CRUD LV** | 零 UI。`AgentTemplate` Kind 存在(type_name `:agent_template`,snapshot `:on_change`);运维只能通过 `mix ezagent.agent_template.create` 或重跑 `CcOrchestratorSeed.seed/0` 创建。`/admin/registry` 的过滤芯片甚至不区分 `template://` 的 type 轴。 | **V1 阻塞** | `ezagent_plugin_liveview` | 新增 `/agent-templates`(列表)+ `/agent-templates/new`(表单)+ `/agent-templates/:uri`(编辑)。通过 `Invocation.dispatch` 触发 `?action=template.write` on `template://agent/<ws>/<name>`。先用 `AutoDerive` 做只读;后续升级为表单。 |
| G-2 | **SessionTemplate CRUD + fork + 实例化 LV** | 零 UI。`SessionTemplate` 携带 `agent_slots`、`routing_rules`、`orchestrator_template_uri`、`parent_template_uri`、`version_hash` — 一个都没暴露。`Ezagent.Entity.SessionTemplate.fork/2` 和 `persist_version/2` 无 UI 触发。`Session.spawn_from_template/2`(**Generator**)只在 orchestrator MCP 路径中被调用。 | **V1 阻塞** | `ezagent_plugin_liveview` | 新增 `/session-templates`(列表 + 版本图 + fork 数)、`/session-templates/:uri`(slot 配置 + 路由规则 + 父谱系芯片)、`/session-templates/:uri@<hash>`(具体版本),`[Fork]` 按钮 → dispatch `template.write`(新 SessionTemplate URI 携带 `parent_template_uri = source@hash`),`[Spawn Session]` 按钮 → dispatch `Session.spawn_from_template`。 |
| G-3 | **Orchestrator + working-copy 视图** | 零 UI。Session `:chat` slice 上的 `template_working_copy` 字段(运维查"orchestrator 当前看到什么槽/AgentTemplate/挂起的编辑"的耐久记录)未被任何 LV 读取。无法在 `:sys.get_state`(经 `/admin/snapshots`)之外查看 session 的 orchestrator 现状。 | **V1 阻塞** | `ezagent_plugin_liveview` | 在 SessionEditor 中新增 `:orchestrator` SessionView(经 `SessionViewRegistry.register` 注册),读取 `Chat.template_working_copy/1` 并渲染 agent_slots + orchestrator_template_uri + routing_rules。显示与 `parent_template_uri@hash` 的差异,运维能看到"哪些待提交"。 |
| G-4 | **Orchestrator MCP 工具面(7 个工具)** | 零 UI。7 个工具(`add_agent_slot` / `remove_agent_slot` / `update_agent_template` / `write_matcher` / `update_template` / `save_template_as` / `list_templates`)只能通过 LLM-driven MCP 触发。运维无法从 UI 手动触发任何一个来调试"orchestrator 试过吗?"或"帮我强制设置这个槽"。 | **V2 可有可无** | `ezagent_plugin_liveview`(或新建 admin/运维面) | 新增按 session 的"Orchestrator 工具"面板(管理员可见,跨 workspace cap 受控),针对绑定的 session orchestrator 上下文 dispatch 每个工具。**不是** chat 替代品 — 是调试 + override 面。 |
| G-5 | **Generator 运行观察(部分状态报告)** | 零 UI。`Session.spawn_from_template/2` 多步(详见 `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:121-132`);失败留下半实例化的 session。最近 PR #248-#250(Generator 第 8-10 轮)补了清理,但没有 UI 展示"此 session 由 `template://session/.../v1@<hash>` 生成,槽 [A,B,C],B 失败,OS pid 4711 已泄漏"。 | **V1 阻塞** | `ezagent_plugin_liveview` | 在 `/sessions/:uri` 上添加 Generator-run 报告卡(session 有 `parent_template_uri` 时):源模板 + hash + 逐槽状态(alive / dead / orphan-reaped)。数据源:`Chat.template_working_copy/1` + 每槽 URI 的 `KindRegistry.lookup` + 各槽 `Behavior.Lifecycle` 事件审计日志。 |
| G-6 | **TemplateTags 列表/移动** | 零 UI。`Ezagent.TemplateTags`(workspace-scoped `name → tag → hash` 解析器)无运维面。orchestrator 的 `update_template` 写 `stable` 标签;运维不通过 `mix run` 或 SQL 看不到、移不动、回滚不了标签。 | **V2 可有可无** | `ezagent_plugin_liveview`(/session-templates 子页) | 按模板的 tag 表 + 移标签按钮(通过新 `template.move_tag` Behavior action,在同一 `template://session/...` URI 上 dispatch — 工具数保持 7;只是在现有 `Behavior.Template` 后面暴露 TemplateTags API)。 |
| G-7 | **AgentTemplate / SessionTemplate 在 `/admin/registry` 的芯片** | `EntitiesLive` 过滤芯片含 `template://`(第 121 行),但 LV 区分不出 `template://agent/*` vs `template://session/*` — 芯片只显示原始 URI。`AutoDeriveLive` `/plugins/auto/:kind` 接受 `agent_template` + `session_template` atom,但 `/admin/registry` 没有跳转链接。 | **V2 可有可无** | `ezagent_plugin_liveview` | 行点击 → `/plugins/auto/agent_template/<encoded-uri>`(或 `session_template/...`);把 `template://` 芯片拆为 `template://agent` + `template://session`。 |
| G-8 | **flavor 列表在 `agent_new_live` 中硬编码** | `AgentNewLive` 有 `@flavors ~w(cc echo curl)`(约第 62 行)— 加一个 Python flavor 必须改 `ezagent_plugin_liveview`。`Ezagent.AgentFlavorRegistry` 是规范 SoT — UI 必须从那里读。 | **V1 阻塞** | `ezagent_plugin_liveview` | 把 `@flavors` 替换为 `Ezagent.AgentFlavorRegistry.list_flavors/0`。按 P1 + P11:新 agent flavor 插件不应要求编辑 `ezagent_plugin_liveview`。 |
| G-9 | **cc-orchestrator 模板呈现** | seed 的 `template://agent/default/cc-orchestrator` AgentTemplate(`CcOrchestratorSeed`)不可见。无法经 UI 确认它种子化了、沙箱路径在哪、MCP 桥安装是否成功。 | **V1 阻塞** | `ezagent_plugin_liveview`(G-1 的子项) | 在 AgentTemplate 列表(G-1)中展示;若是 singleton 加 "boot-seed status" 徽章。`CcOrchestratorSeed.InstallError` 通过 flash + `/admin/logs` 暴露。 |
| G-10 | **agent 重启只支持 cc 且手写** | `AgentDetailLive.handle_event("restart", ...)` 直接调 `Ezagent.Domain.Pty.lookup/1` + `Process.exit/2` — 无 `Behavior.Lifecycle` dispatch、无审计、无 cap 检查。moduledoc 自己承认"Direct plugin reference here is the documented exception per invariant 8"。 | **V2 可有可无**(底层 Behavior 缺失 — P22 说 reliability primitives 属于 core;此为 UI 背后的缺口) | `ezagent_domain_instance_message`(Behavior)+ `ezagent_plugin_liveview`(UI) | 在 Agent Kind 上加 `Behavior.Lifecycle` `:restart` action,向下 dispatch 至 flavor 的 restart fn;UI `Process.exit` 替换为 `Invocation.dispatch`。 |
| G-11 | **从 UI 终止 agent** | `/identities/agents/:uri` 上无 Terminate 按钮。运维必须经 `mix` 任务或 BEAM shell 杀。`Behavior.Lifecycle` `:terminate` 可通过 dispatch + caps 调用。 | **V2 可有可无** | `ezagent_plugin_liveview` | AgentDetailLive 上加 danger 变体按钮,dispatch `?action=lifecycle.terminate`(modal 确认)。 |
| G-12 | **Workspace.session_templates 是遗留 + 与 Phase-7 Kinds 重复** | `WorkspaceDetailLive` 渲染 `@workspace.session_templates` — Phase-4d 的自由 map(`%{name => %{"class" => ..., ...}}`),位于 `Workspace.Store`。这是 OLD(早于 Phase-7)且与 AgentTemplate/SessionTemplate Kinds **正交**。运维今天看"模板"只能看到 Phase-4d 记录,**看不到**真正的 Kinds。违反 P3(单一真相源 — "模板"现在住在两处)。 | **V1 阻塞**(数据架构清理,这里以 UI 症状标记) | `ezagent_domain_instance_message`(决定谁是规范)+ `ezagent_plugin_liveview` | 要么淘汰遗留的 `workspace.session_templates` map 让 `WorkspaceDetailLive` 从 `KindSnapshot.list_in_workspace/1` 按 `template://` 过滤读取,要么重命名遗留字段明确为 "spawn-template registrations"(非 SessionTemplate Kinds)。推荐前者。 |

## §3 各 agent/orchestrator 元素的分层裁定

裁定缩写:✓ = 合规、⚠ = 部分合规(已退化但未实际损坏)、✗ = 违反。

| 元素 | 裁定 | 原则 | 备注 |
|---|---|---|---|
| `AgentDetailLive` 使用 `<.button>` / `<.icon>` / `<.card>`(Tier-2 原子) | ✓ | P8 / UI Contract DO | 文件 PR-H 注释:内联样式已迁移到原子。 |
| `AgentDetailLive` 直接调 `EzagentPluginCc.BridgeRegistry`(102-103 行) | ⚠ | P1 / P11 / P24 | `Code.ensure_loaded?` 软保护。契约是"UI 不直接 import 插件" — 这是两个被文档化的例外之一(moduledoc 自己点出)。应迁移到 `Ezagent.Domain.Agent.bridge_status/1` 门面(参照已存在的 `lifecycle_status/1`)。 |
| `AgentDetailLive.handle_event("restart")` 调 `Ezagent.Domain.Pty.lookup/1` + `Process.exit/2` | ✗ | P14(dispatch 是唯一路径) + P15(cap 检查) + P22(审计) | 绕过 dispatch、caps、audit。moduledoc 承认"documented exception",等 V2 Lifecycle Behavior;此为延迟修复标记,不是豁免。 |
| `AgentNewLive` 硬编码 `@flavors ~w(cc echo curl)` | ✗ | P1 / P11 — 插件隔离 | 新 flavor 插件 = 改 ezagent_plugin_liveview。必须读 `Ezagent.AgentFlavorRegistry`。 |
| `AgentNewLive` cc/echo flavor 调 `Ezagent.Workspace.add_template` | ⚠ | P3 / G-12 | 调入遗留 `workspace.session_templates` map — Phase-4d 数据模型,非 Phase-7 AgentTemplate Kind。今天工作,但把遗留 SoT 烧进去。 |
| `AgentNewLive` cap 授予用 `Invocation.dispatch`(第 331 行) | ✓ | P14 / P15 | 正确 — `identity.grant_cap`。 |
| `AdminLive` 直接调 `EzagentPluginCc.BridgeRegistry` + `EzagentPluginFeishu.SessionBinding`(4+ 处) | ⚠ | P1 / P11 | 同样的软保护模式。文档化为例外;同 V2 修复路径。 |
| `AdminLive` 邀请流用 `<.button>`、`<.modal>`、`<.uri_picker>` | ✓ | UI Contract DO | PR #178 + V1 spec §2C.3 已迁移。 |
| `MemberPanel` 是 Tier-3 插件组合用 Tier-1 原子 | ✓ | UI Contract §3-layer | moduledoc 明确"stateless — parent owns assigns + handlers." |
| `SessionEditor` 是 Tier-3 无状态组合,父持状态 | ✓ | UI Contract §3-layer | 同样模式。 |
| `IdentitiesLive` 直接读 `Ezagent.KindRegistry.list_all/0`(无门面) | ✓ | P9 | KindRegistry 是 Tier-1 原语;允许读。 |
| `EntitiesLive` 渲染 `<h1 style="font-size: 22px;">`、`<p style="...">`、`<section style="...">`、`<table style="...">` | ✗ | UI Contract DON'T | 16 处 `style="..."`,文件唯一承认的迁移是 "PR-F filter chips inlined"。header / paragraph / table **没**迁移。 |
| `SnapshotsLive` 渲染 `<h1 style="font-size: 22px;">` + `<p style="...color: #666;">`(共 24 处) | ✗ | UI Contract DON'T | 同 `<h1 style="font-size: 22px; font-weight: 600;">` 模式 — admin 视角各页复制粘贴反模式。 |
| `UserApiKeysLive`(30 处内联样式) | ✗ | UI Contract DON'T | 同问题。非直接 agent 面但从 `/identities/agents/:uri/api-keys` 可达。 |
| `WorkspaceDetailLive`(2 处内联样式;大部分按 PR-H 迁移完毕) | ⚠ | UI Contract DON'T | 大体 OK — 只剩 2 个落漏。 |
| `RoutingLive`(30 处内联样式) | ✗ | UI Contract DON'T | Routing 是 orchestrator-邻接面(orchestrator `write_matcher` 工具写 routing 规则);运维巡查 routing 的页面有 30 处 `style=` 违规。 |
| `AutoDeriveLive` for `template://*` Kinds | ⚠ | UI Contract — 工作但只读 inspect-dump | `inspect(state, pretty: true)` 是运维级,非用户级。够 V0 可见性,不够 V1。 |
| 所有 Tier-3 LV 在 render 包 `<AppShell.app_shell>` 套 `<WorkspaceShell.workspace_shell>` 或 `<AdminShell.admin_shell>` | ✓ | Nested shell architecture | `admin_live`、`agent_detail_live`、`agent_new_live`、`entities_live`、`snapshots_live`、`terminal_live`、`routing_live`、`identities_live` 均验证。 |
| 所有 `require_entity` LV 经 `router.ex` `live_session :require_entity` 受益于 `:put_locale` on_mount | ✓ | i18n PR #224 | router.ex 第 67 行 + live_auth.ex 第 101 行确认。 |
| `terminal_live`、`agent_detail_live` 用 `Ezagent.Domain.Agent.lifecycle_status/1` 门面(非直接插件 import) | ✓ | P1 / P24 | 门面存在;两个 LV 都使用。Bridge status 没有对等门面 — 见上 ⚠。 |
| Workspace plumbing(P12)在 agent-related 路由 | ✓ | P12 — workspace_uri 穿透 | `current_workspace_uri` 经 on_mount 流入;所有 LV 正确呈现。 |
| `agent_new_live` workspace 分配:模板注册硬编码 `@default_workspace_name` | ⚠ | P12 — workspace plumbing | 任何 workspace UI session 创建的 agent 都经遗留模板注册路径落入 `workspace://default`。多 workspace 时可能错;应用 caller 的 session workspace。 |

## §4 跨层违规(file:line)

### V-1: domain-邻接 UI 中硬编码插件 flavor 列表
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex:62` — `@flavors ~w(cc echo curl)`
- **违反**: P1(插件隔离)、P11(插件扩展,不要求 core 改动)、P24(插件不写 core)。
- **修复**: 读 `Ezagent.AgentFlavorRegistry.list_flavors/0`(规范 SoT 已存在,见 `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`)。

### V-2: "重启 agent" 的 LV 绕过 dispatch + caps + audit
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex:138-160` — 直接 `Ezagent.Domain.Pty.lookup/1` 得到 PtyServer pid 后 `Process.exit(pid, :shutdown)`。
- **违反**: P14(dispatch 是唯一路径)、P15(cap 检查)、P22(audit telemetry)。
- **修复**: Agent Kind 加 `Behavior.Lifecycle` `:restart` action,向下 dispatch 至 flavor 重启 fn;UI 用 `Invocation.dispatch/1`。moduledoc 已标延迟到 V2 Lifecycle Behavior — 延迟可以,但请进 tracker。

### V-3: LV 直接 import 插件模块(多处)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex:102-103` — `EzagentPluginCc.BridgeRegistry.list_connected()`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/observability_live.ex:35-36` — 同
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:477-478, 1281-1282, 1319-1320, 1418` — `EzagentPluginCc.BridgeRegistry`、`EzagentPluginFeishu.SessionBinding`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/feishu_bindings_live.ex:52` — `alias EzagentPluginFeishu.{BindingPolicy, SessionBinding, UserBinding}`(无软保护)
- **违反**: P1(插件隔离北极星)、P11 / P24(插件扩展,不被其他层要求)。
- **今日缓解**: `Code.ensure_loaded?` 软保护 6 处中的 5 处。`feishu_bindings_live.ex` 是硬耦合(模块顶部 alias,无软保护)— 此 LV 字面上没有 Feishu 插件就不能存在,边界上可以接受为"插件自己的 LV 放错了 app",但仍是分层异味。
- **修复**: 提升插件公共 API 为门面(`Ezagent.Domain.Agent.bridge_status/1`、`Ezagent.Domain.Channel.bindings_for_session/1`)。Feishu admin LV 应迁到 `apps/ezagent_plugin_feishu/lib/`,从插件 `Application.start/2` 注册路由。

### V-4: 在 UI Contract DON'T 清单上的内联 `style=""` 违规
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entities_live.ex` — 16 处(`<h1 style="font-size: 22px; font-weight: 600;">`、`<p style="font-size: 13px; color: #666;">`、`<section style="margin-top: 16px;">`、`<table style="width: 100%; ...">` 等)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/snapshots_live.ex` — 24 处
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/user_api_keys_live.ex` — 30 处
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/routing_live.ex` — 30 处
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspace_detail_live.ex` — 2 处(大部分已迁移)
- **违反**: UI Contract §DON'T("DON'T write `<h1 style="font-size: 22px; font-weight: 600;">` — use `<.page_header>` or Tailwind tokens")。也破坏暗模式切换基础设施(硬编码 hex 无 `dark:` 对)。
- **修复**: PR-H 模式应用于 `agent_detail_live` + `workspace_detail_live`;对这 4 个文件重做。约 100 行机械迁移。

### V-5: 两套并行 "templates" 存储
- 遗留 `Workspace.Store.session_templates`(Phase-4d 自由 map)在 `WorkspaceDetailLive` 渲染
- Phase-7 `Ezagent.Entity.SessionTemplate` Kind — 任何地方都没有渲染
- **违反**: P3(任何数据单一真相源)。
- **修复**: §2 中 G-12。决定谁是规范并迁移。

### V-6: cc/echo 创建路径中硬编码 workspace
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex:231, 257` — `Ezagent.Workspace.add_template(@default_workspace_name, ...)`
- **违反**: P12 / P17(workspace plumbing — 多 workspace 运维不能在非默认 workspace 中创建 agent)。
- **修复**: 从 caller 的 session workspace 派生(已经在 socket 上为 `@current_workspace_uri`)。

## §5 最佳实践裁定 + 具体可操作项

UI 实质上遵循 3-layer / Nested-shell 模式。Tier-2 原语库丰富。PR-O / PR-N 新增的 LV 一致使用原子 + `<AppShell.app_shell>` 包裹。但有清晰的漂移口袋:

1. **插件隔离北极星(P1)被削弱** — LV 代码中 6 处直接 import 插件。`Code.ensure_loaded?` 模式是把契约违规藏过 CI 的 hack。其中 3 处违规(`EzagentPluginCc.BridgeRegistry` 读)应成为 `Ezagent.Domain.Agent.bridge_status/1` 门面 — 先例(`lifecycle_status/1`)已就位。**行动**: 写门面、替换 4 处调用、删 `Code.ensure_loaded?` 软保护。

2. **硬编码插件枚举(V-1)** 是最干净的违规可修 — `agent_new_live.ex` 一行改为读已存在的 `Ezagent.AgentFlavorRegistry`。**行动**: 立做。

3. **内联 `style=""` 债务(V-4)** 机械但真实 — 4 个 LV 文件 100+ 违规。SKILL DO/DON'T 清单显式。**行动**: 一个机械 PR 把 4 个文件用 `<.page_header>`、`<.card>`、`<.button>`、`<.badge>` 模式迁移,加按替换表的 `dark:` 对。

4. **Phase-7 不可见(G-1 / G-2 / G-3 / G-5 / G-9 / G-12)** 是最大发现。Phase-7 5 月发布了 7 个 PR 的 orchestrator + AgentTemplate + SessionTemplate + Generator 基础设施,0 个 PR 的运维 UI。运维看不到 orchestrator 在做什么、不能审计 working-copy、不能浏览 orchestrator 选择的模板、看不到 Generator 运行结果。系统功能完备但运维不透明。**行动**: V1 阻塞 UI 范围为 G-1 + G-2 + G-3 + G-5 + G-8 + G-9 + G-12;即 5-6 个新 LV + 1 个 SessionView + 1 个小重构。

5. **AutoDerive(`/plugins/auto/:kind`)是已有的逃生口** — 今天就为 `agent_template` 和 `session_template` 工作(Kinds 正确暴露 `type_name/0`,详见 `agent_template.ex:102` 和 `session_template.ex:120`)。V0 妥协方案只需从 `/admin/registry` 加 `/plugins/auto/agent_template` + `/plugins/auto/session_template` 链接,把 Phase-7 UI 称为"运维级 shipped"。比建专用 LV 快,符合 Allen 的 production-usability P4 — 运维立刻得到可见性,精修后续。

6. **Orchestrator tools 面(G-4)和 TemplateTags(G-6)** 是 V2 — 调试 + override 面,非正常运行阻塞。

## §6 建议 — V1 阻塞范围 vs V2 待办

### V1 阻塞项(声明 orchestrator UI "shipped" 前必须解决)

| 优先 | 项 | 理由 | 大致工作量 |
|---|---|---|---|
| **1** | **G-8 / V-1** — `AgentFlavorRegistry`-驱动的 flavor 列表 in `AgentNewLive` | 最小改动,最大插件隔离收益。解锁 Python flavor PR。 | 30 分钟 |
| **2** | **G-1 + G-2 的 V0 妥协方案** — `/admin/registry` → `/plugins/auto/agent_template` + `/plugins/auto/session_template` 链接;在 `EntitiesLive` 把 `template://` 过滤芯片拆为 agent/session | 本周给运维**一些** Phase-7 可见性,无需 2 周 LV 建设。 | 2 小时 |
| **3** | **G-9** — 在 V0 妥协方案或 `/admin/dashboard` 中暴露 cc-orchestrator seed 状态(boot 成功/失败徽章) | orchestrator **是**系统 Phase-7 的招牌特性;静默安装失败是最坏 bug。 | 2 小时 |
| **4** | **G-12 / V-5** — 决定 templates 规范存储;迁 `WorkspaceDetailLive` 读 `KindSnapshot.list_in_workspace/1` | 两套并行 "templates" 是会无声扩散的 P3 违规。 | 1 天(决策 + 迁移) |
| **5** | **V-4** — 迁移 4 个 LV 中 100 处内联 `style=""` | 一个机械 PR 按 SKILL DO/DON'T 清单。 | 4 小时 |
| **6** | **G-3(精简)** — 有 working copy 的 session 的 `:orchestrator` SessionView,只读 `template_working_copy` | 运维要回答"orchestrator 现在看到什么?" — 只读视图够 V1。 | 1 天 |
| **7** | **G-5(精简)** — 有 `parent_template_uri` 的 Sessions 上的 Generator-run 横幅 — 源模板芯片 + 槽状态列表 | Phase-7 round-8/9/10(PR #248-#250)关了清理漏洞;UI 应端到端确认这些工作。 | 1 天 |

### V2 待办(V1 后)

| 项 | 延迟原因 |
|---|---|
| G-1 / G-2 从 AutoDerive 提升到专用 LV(表单驱动 create/edit;fork 按钮;版本图) | V0 妥协方案在 Phase-7 生产使用最初几周够用;运维反馈会告诉我们他们实际编辑哪些字段。 |
| G-4 — Orchestrator tools admin 面 | 调试 + override 面。真运维会经 orchestrator chat 工作;只有 ezagent 开发组需要 override 面。 |
| G-6 — TemplateTags 列表/移动 UI | tag-bumping 当前是 orchestrator 的工作。运维 override 是 future-when-we-need-it。 |
| G-7 — `template://agent` vs `template://session` 芯片拆分 | G-1 + G-2 落地后即装饰性。 |
| G-10 / G-11 — restart + terminate 的 Lifecycle Behavior | Behavior 本身缺失(P22 reliability primitive 缺口)。core 加后,UI 跟一个小 PR。 |
| V-3 — `Ezagent.Domain.Agent.bridge_status/1` 门面 + 移除 LV 中的插件 import | 清理 PR。V1 落地后跑。 |
| V-6 — agent 创建从 caller workspace 派生 workspace | 多 workspace 运维路径未被加压。文档化为已知限制。 |

### 跨切建议:不变式测试

按 P6 — "完成声明必须有不变式测试。" V1 工作落地时,至少添加:

- `agent_new_live_flavor_registry_test.exs` — 断言 flavor 下拉选项匹配 `AgentFlavorRegistry.list_flavors/0`(新 flavor 插件让测试拒绝硬编码列表)。
- `ui_no_inline_styles_test.exs` — `grep -rn 'style="' apps/ezagent_plugin_liveview/lib/` 返回零匹配(必要时记录例外)。阻止回归。
- `phase_7_kinds_have_ui_test.exs` — 对每个 `type_name in [:agent_template, :session_template]` 的 `kind_module`,断言路由表里有渲染路径。阻止"后端发布无 UI"模式。

---

审计结束。
