# Kanban T6 — 操作 UI 变权限门控 tab + 分享链接接线 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐任务实施。步骤用 `- [ ]`。

**Goal:** 把 kanban 操作面从「插件页」搬进「权限门控的 session tab」(像 VSCode 编辑区),插件页缩成配置(external mirror token);分享=从 tab 发链接、点击把板加进对方 tab。

**Architecture:** 甲方案(勘察 adce7e4 结论)——tab 交互不走 SessionView(其 external_render 结构性只读),走现成前端 `Kanban.tsx` `onAction → world:dispatch → KanbanActions` 通路。SessionView 只声明 tab + cap 门控,behaviour 零改动。`Kanban.tsx`/dispatch/`forward_board` 全复用。

**Tech Stack:** Elixir/Phoenix(world plugin + domain_session) + React/TS(world assets)。

## Global Constraints
- 工具链:仓库 tracked `.tool-versions` = **elixir 1.19.x-otp-28 / erlang 28.x**(CI 同款);跑 mix 用它,不用过时的 mise OTP27 pin。
- TDD;改 manifest/baseline 用 Edit 精准 + 全套 arch 重测;不撞 gate(I12/p6 CapCheckOnlyAtChokepoint/no-wildcard/arch baseline)。
- 分支 `feat/kanban-progress-board`(栈在 #1376 上)。每任务独立可测,分别 commit。
- 不硬编码 slice;board 授权全复用 `BoardProvision`/`CompositionCaps.mint_cap`(#1376),不新写 cap 逻辑。
- **P14**:跨 Kind 只走 dispatch;分享接收走 `forward_board`(已含 fail-closed 授权),不旁路。

---

## Task 1: session tab 数据源 — kanban_board 归 native 模式 + session-scoped board 读入口

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:20,113`(`@native_react_ids` + `render_mode/2`)
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:77`(加 session-scoped board 读入口,复用 `visible?` CBAC)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_test.exs` + `kanban_data_test.exs`(找现有,无则建)

**Interfaces:**
- Produces: `render_mode(:kanban_board, _)` → `"kanban"`(非 `"external"`);`KanbanData.session_boards(session_uri, ctx)` → cap 过滤后的 board 列表(admin 全见 / 普通用户见 own+持 cap),Task 2 前端消费。

- [ ] Step 1: 写失败测试 —— `render_mode(:kanban_board, view)` 现返回 `"external"`,断言应为 `"kanban"`;`KanbanData.session_boards/2` 不存在。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: `@native_react_ids` 加 `kanban_board: "kanban"`;`render_mode/2` 让声明 external 的 kanban_board 走 native 分支。`KanbanData` 加 `session_boards/2`:session→workspace(`KanbanRender.boards_for` 同源解析)→ `list_by_recipe` → `Enum.filter(&visible?(&1, ctx))`(复用现成 CBAC,ctx 带 `:caller_uri`/`:caller_caps`)。
- [ ] Step 4: 跑测试确认通过。
- [ ] Step 5: p6+I12 探针 + world 套件全绿(`mix test apps/ezagent_plugin_world` + 两不变式测试)。
- [ ] Step 6: `mix format` + commit。

## Task 2: 前端 —— session tab 渲染富 Kanban 组件(操作面)

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:229,775`(加 `activeMode==="kanban"` 分支)
- Reuse: `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx` + `KanbanCanvas.tsx`(已全交互)
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`(session tab 的 kanban 数据/onAction 接线,复用 `world:dispatch`)

**Interfaces:**
- Consumes: Task 1 的 `"kanban"` 模式 + `session_boards` 数据。
- Produces: session tab 里可点的富看板,`onAction("kanban.*")` → `world:dispatch` → `KanbanActions`(现成写通路)。

- [ ] Step 1: `Conversation.tsx` 主区(`:775` 现只判 `pty`)加 `activeMode==="kanban"` 分支,渲 `<Kanban state={kanbanState} onAction={onWorkspacePluginAction}/>`。
- [ ] Step 2: `main.tsx` 把 session tab 的 kanban state(来自 Task 1 `session_boards`)喂给组件;onAction 复用 `world:dispatch`(session 无关,现成 `:365`)。
- [ ] Step 3: `tsc --noEmit`(每 assets 目录)+ `mix assets.build`(或等价)无错。
- [ ] Step 4: commit。(真浏览器渲染留待 disposable stack e2e —— 见收尾。)

## Task 3: 插件页缩成配置页(external mirror token)

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex:31-41`(收窄 action 白名单为 config 类)
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex:256-269`
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:172`(config_surface 语义收为「配置」)
- Modify: `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx`(拆:token 配置表单留插件页,操作 UI 归 tab)
- Reference: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/external_mirror/view.ex`(「tab 只读 + 独立配置页」先例)

**Interfaces:**
- Produces: `/plugins/kanban` 只剩 config(external mirror token / board config),操作 action 不再在此白名单。

- [ ] Step 1: 写失败测试 —— 断言 `PluginPageRegistry` 的 kanban 页 action 白名单不含操作类(如 `kanban.add_node`),只含 config 类(`kanban.save_miro_creds` 等)。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 收窄白名单 + `routes.ex`/`config_surface` 语义;前端 `Kanban.tsx` 拆出 config 表单组件(token 输入 `:70-92` 已是雏形),操作部分只在 session tab 挂。
- [ ] Step 4: 跑测试确认通过 + world 套件绿 + `tsc --noEmit`。
- [ ] Step 5: `mix format` + commit。

## Task 4: 分享链接生成 + 接收路由 → forward_board

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`(加 `kanban.share_board` handler,生成 `Phoenix.Token` 编码 board_uri,复用 `:148/:266` upload-grant token 模式)
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex`(白名单加 `kanban.share_board`)—— 注:此动作留在操作面(tab),非配置页
- Create: 接收 controller/route(照 `apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex` + `router.ex:158-162` 模式) → 验 token → `Ezagent.Socialware.BoardProvision.forward_board/5`(已含 fail-closed 授权,复用)
- Modify: `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx:60-62`(`onShare` 占位接线)+ `main.tsx`(pass onShare)
- Test: kanban plugin e2e(照现有 `board_forward_test.exs`)+ web controller test

**Interfaces:**
- Consumes: `BoardProvision.forward_board/5`(#1374,只读钥匙)。
- Produces: 分享按钮 → 生成链接;点链接 → 接收 route 验 token → forward_board 铸只读 cap → 板进接收方 tab(consent-on-receive)。

- [ ] Step 1: 写失败测试 —— `kanban.share_board` 动作对选中 board 产出可验 token;接收 handler 对有效 token 调 `forward_board` 成功、无效 token 拒。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 实现 `share_board` handler(生成 token)+ 接收 controller/route(验 token → forward_board)+ 前端 onShare 接线。
- [ ] Step 4: 跑测试确认通过(含 forward 授权两分支)+ p6/I12 探针绿。
- [ ] Step 5: `mix format` + commit。

## Task 5(可选): chat 助手 create/share skill

**Files:**
- Modify: `apps/ezagent_web/priv/skills_seed/kanban-assistant/scripts/kanban_dispatch.exs`(+ SKILL.md):暴露 create_board/share_board,现只做 node 级 `kanban.*`

- [ ] 让 kanban-assistant 能在 chat 里 dispatch 建板/分享(现只能 node 操作已存在的板)。视 T6.1-4 完成后按需做。

---

## 收尾(不在本计划的 TDD 门内 —— 需真栈)
- 真浏览器 e2e 每步截图:起 disposable docker 栈(端口 10044)+ 真 cc 助手凭证。Task 1-4 让流程**产品可达**;截图在灰度/真栈上跑。

## Self-Review
- Spec 覆盖:操作→tab(T1+T2)、plugin→配置(T3)、分享链接+接收(T4)、chat(T5 可选)—— 对齐用户 tab 设计四条。
- 类型一致:`session_boards/2`(T1 产)被 T2 消费;`share_board`token(T4 产)被接收 handler 消费。
- 无占位:各 task 有具体 file:line + TDD 步。
