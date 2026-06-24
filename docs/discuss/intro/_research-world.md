# 研究笔记：world（取代 liveview 的统一 React 前端）

> 调研时间：2026-06-22 · 调研基线：main `b6818123`（从 `e2abc02f` +59 提交）
> 目的：为 intro/ 文档更新提供实证依据。**结论：world 已落地、liveview 已退役、LV→world parity 迁移 100% 完成（零遗留）。**
> 引用全部带 file 路径，可复核。

---

## 1. 一句话：world 是什么

world = ezagent 的**下一代统一前端 app**，可见 UI **100% React + shadcn/ui**，挂在一个**纯做 SSR/通信壳的 LiveView 页面**上（服务端权威 + dispatch 透传，**生产链路里没有 Node 运行时**）。它复刻并**完整取代**了原来的 `ezagent_plugin_liveview`（25 个 HEEx LiveView 管理面）。

- OTP app：`apps/ezagent_plugin_world`（slug `world`，模块前缀 `EzagentPluginWorld`）
  - `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:18-24` — `plugin_info` 自述 "The React/shadcn ezagent app over a LiveView comms shell."
- 服务于子域 `world.ezagent.chat`（host-scoped 路由，见 §4）
- 权威 spec：`docs/superpowers/specs/2026-06-21-world-plugin-react-shadcn-spec.md`（拍板决策 D1–D11）

> 注意术语消歧：这里的 "LiveView" 仅是**通信壳（comms shell）**，不是渲染层；可见内容全是 React。不要跟"ezagent 是个 LiveView app"混淆——LV 只负责 cookie→cap 鉴权、路由、PubSub 入站桥、`Invocation.dispatch/1` 出站。

---

## 2. 怎么取代 liveview 的（迁移已完成）

- **app 已删**：`apps/ezagent_plugin_liveview` 不存在了（`ls apps/` 无此目录）。仍是 21 个 app（world 顶上了 liveview 的位置）。
- **router/mix 无残留**：`apps/ezagent_web/lib/ezagent_web/router.ex`、`apps/ezagent_web/mix.exs`、根 `mix.exs` 里**没有任何** `EzagentPluginLiveview` / `ezagent_plugin_liveview` 引用。
- **迁移路径**：spec `docs/superpowers/specs/2026-06-21-world-lv-parity-migration-spec.md` 定义了 PR-0..PR-7。完成判据**不是手列页面集，而是对 LV 的 parity 审计**（教训 `feedback_replacement_task_gate_is_parity_audit`）。
  - PR-0 把 LV 全量 surface 抽成权威清单：`docs/superpowers/specs/2026-06-21-world-lv-parity-INVENTORY.md`（25 LiveView · 1 LiveComponent · 63/70 handle_event · 15 handle_info 入站事件 · uploads · PubSub 订阅）
  - 落地为 ratchet 测试：`apps/ezagent_plugin_world/test/ezagent/world/lv_parity_test.exs` —— 每个迁移 PR 删掉它落地的 feature，`@pending_migration` 必须归零。
- **迁移已 100% 完成**：`lv_parity_test.exs:107` 处 **`@pending_migration []`**、`:109` 处 `@pending_baseline 0` —— **零遗留**。对应提交 `3b7072a0 Complete world LV parity migration`（ratchet 从 44 features pending → 0，提交 `c7031d8f`）。

---

## 3. world 现在覆盖了哪些面

world 是**单一 LiveView**（`WorldLive`）+ 服务端按路由算出 component-type，React 端按 type 渲染。`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:612-799` 的 `route_for/2` 是路由→component 映射的权威源。

覆盖面（既有运营/管理面，**也有客户/会话面**）：

| 面 | 路由 | component-type | 说明 |
|---|---|---|---|
| 会话列表 | `/sessions` | `sessions_table` | 落地页 |
| **会话对话页** | `/sessions?session=<encoded>` | `conversation` | 聊天流 + composer + @mention + 成员面板 + 邀请 + 文件上传 + 入站实时桥（迁移最高风险件，已落地） |
| 身份-用户 | `/identities`、`/identities/users` | `identities`/`users_table` | |
| 身份-Agent | `/identities/agents`、`.../:uri`(detail)、`/new`、`/caps`、`/api-keys`、`/extensions` | `agents_table`/`agent_detail`/`agent_new_form`/`entity_caps`/`agent_api_keys`/`agent_extensions` | |
| Agent 终端 | `/identities/agents/:uri/terminal` | `pty_terminal` | 定制 island，复用 xterm hook（D7） |
| 工作区 | `/workspaces`、`/workspaces/:name` | `workspaces_list`/`workspace_detail` | |
| 插件 | `/plugins`、`/plugins/feishu/bindings`、`/plugins/auto/:kind[/:uri]` | `plugins`/`feishu_bindings`/`auto_derive` | auto-derive detail 含 credential cascade |
| Profile | `/profile` | `profile` | |
| 管理后台 | `/admin`、`/logs`、`/registry`、`/snapshots`、`/templates`、`/caps`、`/audit/authz`、`/settings`、`/routing`、`/sessions/:id/external_mirror` | `dashboard`/`observability`/`entity_registry`/`snapshots`/`templates`/`caps_admin`/`authz_audit`/`settings`/`routing`/`external_mirror` | 真实数据 |

外加 **command palette**（cmdk）+ 13 个 shadcn primitive 原子（button/input/table/dialog/toast/uri_picker/command_palette 等，从 `ezagent_domain_ui` 的 HEEx 原子移植为真 React 组件）。

React 组件源：`apps/ezagent_plugin_world/assets/src/components/`（`Conversation.tsx`、`Admin.tsx`、`Identities.tsx`、`WorkspacePlugin.tsx`、`SessionsTable.tsx`、`PtyTerminal.tsx`、`LayoutEditor.tsx`、`ui/` 原子）。

---

## 4. 技术形态（React + 什么）

- **前端栈**：React 18.3 + shadcn/ui（new-york 风格，slate base）+ Tailwind（shadcn tokens）+ Vite 构建/HMR + TypeScript。
  - `apps/ezagent_plugin_world/assets/package.json`（react 18.3.1 / vite / class-variance-authority / lucide-react / tailwind-merge）
  - `apps/ezagent_plugin_world/assets/components.json`（shadcn 配置）
- **桥接模式（D7）**：LV ↔ React 走 `phx-hook="WorldRenderer"` + `phx-update="ignore"`（Bussey/PTY 同款，零 Node）。
  - `world_live.ex:253-279` `render/1` 只吐一个 `<div id="world-root" phx-hook="WorldRenderer" data-layout=... data-world-state=... data-world-component=...>`
  - hook：`apps/ezagent_plugin_world/assets/js/world_renderer.js` —— `mounted()` 里 `import(moduleUrl)` → `mod.mountWorld(el, {layout, state, caller, pushEvent, onServerEvent})`
  - 入口：`apps/ezagent_plugin_world/assets/src/main.tsx`（`createRoot` + 按 `state.component` 选组件）
- **数据流（spec §5）**：
  - 服务端→React：`push_event(socket, "world:state", payload)`，v1 整屏推全量数据（增量 diff 是后续 phase，spec §11.5）
  - React→服务端：`pushEventTo("#world-root", "world:dispatch", %{action, args})` → `world_live.ex` 的 `handle_event("world:dispatch", ...)` 构 `%Ezagent.Invocation{}`（`ctx: %{caller, caps, reply}`）→ `Invocation.dispatch/1`（CapBAC 在 dispatch chokepoint step 5.5 卡 `ctx.caps`，D10 沿用既有 LV 约定）
  - 入站实时桥：`WorldLive` 服务端订阅同样的 PubSub topics（chat/presence/notification/audit/cc/pty/slice-change），`handle_info` 再 `push_event` 给 React island（`world_live.ex:98-170`、`subscribe_global_inbound/1` 在 `:551`）
- **生产无 Node（D3）**：prod 出预编译静态资产到 `priv/static`；"SSR" 仅指 LV 渲染壳 + 初始数据，React 客户端 hydrate。dev 期 Vite(Node) 做 HMR 是要求项（gate #4）。
- **布局层（D5/D11，runtime data）**：组件是 build-time 代码，布局是 runtime 数据。
  - 布局存 `$EZAGENT_HOME/<profile>/world/layouts/<scope>.json`，由 `Ezagent.World.LayoutManager`（`apps/ezagent_plugin_world/lib/ezagent/world/layout_manager.ex`）读写、按已注册 component-type 校验（fail-closed）
  - 改布局走 cap：Behavior `Ezagent.World.Behavior.Layout`（`action :manage`），挂在 Workspace Kind 上；默认把 `:manage` cap 授给工作区 admin 实体（`application.ex:34-36` after_boot → `LayoutBootstrap.ensure_system_admin_manage_cap`）
  - v1 **没有**泛化 socialware 的 `SessionView`/`Surface`（D11/spec §8 显式 descoped）；"ezagent app 即一个注册的 socialware View"是 north-star，但留给后续 phase。

---

## 5. 还剩什么没迁

- **核心迁移：零遗留**。`lv_parity_test.exs` 的 `@pending_migration []` 已空，对 LV 全 surface（会话对话页全套 + cmdk + auto-derive cascade + external-mirror + settings/SMTP + display-name 编辑 + uploads + 全部 15 个入站 handler）均已覆盖。
- **文件上传走了新形态**：React island 在 `phx-update="ignore"` 下用不了 LiveView uploader，改为 **cap 鉴权的 HTTP POST** `/world/uploads`（`router.ex:147` → `WorldUploadsController`，内部 dispatch `:session :attach`，跟 `:session :send` 同一 chokepoint 鉴权）。spec：`docs/superpowers/specs/2026-06-21-world-upload-endpoint-spec.md`。
- **后续 phase（非遗留，是刻意 descope）**：
  - push 增量 diff（v1 整屏推全量，spec §11.5）
  - 协同编辑 Yjs（spec §12 non-goal，架构不排斥）
  - 把 world 注册成 socialware View / 泛化 `SessionView`/`Surface`（D11 north-star）
  - 生产 DNS：`world.ezagent.chat` 的 Cloudflare ingress + 子域 cookie domain `.ezagent.chat` + `check_origin` 是部署配置项（spec §6/§8.1），改动生产 DNS 需先确认。
- **文档状态提示**：上述两份 spec 头部 status 仍写 SPEC/DRAFT（是 PR 期设计文档的时点状态），但**代码已全部落地**——别被 status 字段误导。

---

## 6. 对 intro/ 文档的影响（要改的点）

intro/ 里凡把 world / 统一 React 前端写成"在建/future/未进 main"的，**全部过时**，应改为"已落地、liveview 已退役"：
- world = 取代 liveview 的统一 React+shadcn 前端，已在 main（`b6818123`）。
- liveview app 已删除，21 app 数不变（world 顶替）。
- world 同时覆盖运营/管理面**和**客户会话面，不是只有管理面。
- socialware skill 已同步到 world+agent-contract（提交 `b6818123 #882`）。

> 配套变化（本研究未深入，另有 _research）：agent-contract/agent-schema 也已落地（`apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex` + `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex`）。
