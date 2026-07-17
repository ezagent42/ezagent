# Handoff: world（非 kanban）前端 —— 推送订阅基建 + 会话面状态 + 管理面

> **Date:** 2026-07-16 · **From:** jjkysy（PR #1374 kanban 线）· **To:** zyli（world / ezagent 界面负责人）
> **Tracking:** docs/notes/2026-07-16-kanban-fix-plan.md（v3 归属重切版）· **Base:** `origin/main` @ 6bfe3d1b3
> **Status:** confirmed —— 诊断全部现读代码核实；范围已按新归属原则重切（v2 那份把 kanban 面板整包给你，作废）

## 0. 来龙去脉（给完全没跟这条线的你）

kanban 是我们的一块**自包含协作白板 plugin + socialware**：板是一个 passive 的 data-host agent（kanban-manager），任何界面操作都是一次 dispatch 到板 agent，能不能操作只看操作者手里有没有它的 operate cap（钥匙）；配套 socialware 再给会话装一个 kanban-assistant（cc-headless"脑"）代人操作。协作模型 2026-07-15 用户定稿，一句话：**带认领机制的 excalidraw 式协作**——成员加节点即自动认领、认领人编辑自己节点、删除需整子树同主（版主兜底）、分享链接恒只读、编辑权只来自会话成员身份或版主批准。

我们围绕它做了两轮真 UI 测试（两账号手动 + agent-browser e2e），挖出 ㉞ 项问题，按根因归并成 6 组（X1-X6，见必读 4）。**为什么这份落到你头上**：你是 world（ezagent 界面）负责人——归属原则是 **kanban 自己的界面我们自己修**（kanban 是自包含 plugin，声明式插入 world，Kanban.tsx/KanbanCanvas/kanban 面板全归我们），**但这批问题里有一半根本不是 kanban 的**：world 本体的实时推送基建缺失、会话面状态（tab 深链/深色主题/向导）、几个"机制在、面没有"的管理面、chat 消息渲染。这些是 world 的，归你。

## 1. 必读（动手前）

1. Skill `ezagent-developer` —— 不变式 gate。
2. `docs/guide/world-coordination.md` —— **必读**（本包全在 world），并在 in-flight registry 加行。
3. `docs/notes/2026-07-15-kanban-layering-debt.md` —— ⑤-㉞ 全部现象记录（编号引用出处）。
4. `docs/notes/2026-07-16-kanban-fix-plan.md` —— 六个根因（X1-X6）与 PR 切分；你拿的是 PR5。
5. `docs/notes/2026-07-15-kanban-collab-model.md` —— 协作模型定稿（背景理解用，你不实施它）。

## 2. 锁定决策（用户已拍板，不要重开）

| # | 决策 | 值 |
|---|---|---|
| 1 | 归属 | **kanban 前端不归你**：Kanban.tsx / KanbanCanvas.tsx / kanban_data.ex / kanban_actions.ex / plugin_page_registry 的 kanban 条目，全部我方在飞，**别动** |
| 2 | tab 门控 | **不要动** `applies_to?` / `authorize_view`（T2-2b 平台契约，Allen D3 决策中）；成员见 tab 由 join 补发（我侧）达成 |
| 3 | 推送环 | 发布侧（emit/notify）我做；**world 订阅/分发基建**你做；kanban 面的事件消费（重拉 board_state）我做——接口 = §5 payload 约定 |
| 4 | ⑭ 邀请码 | 跨用户协作正路 = 邀请码注册（人"出生"进 workspace）；**不要**给 `workspace.add_member` 补 UI（接口存在性待审） |

## 3. 诊断（Y=现象 → X=根因，file:line）

### X1 —— world 是「拉模型 + 操作者自刷」，没有 server→同会话成员的推送环（Y=⑰㉒㉘）

"别人的界面不刷新"不是散点 bug：状态变更只有操作方本地 `push_event`，**发布侧从来没人往任何 topic 广播**。订阅侧其实全现成：

- per-user：`subscribe_global_inbound` 已订 `Ezagent.Notifications.topic(caller_uri)`（world_live.ex:836），`handle_info({:notification, ...})` 已有（:203）。
- per-session：打开会话即订（:106 `ensure_session_subscribed`）。
- 订阅先例：`maybe_subscribe_pty`（:888，:85 调用）；退订/泄漏教训在 world_live.ex:149-155 注释。
- board 是 workspace 级 agent，**不在** session topic 上——kanban 面需要订 board 自己的 events topic（那半边我做，用你的基建）。

**分工**：发布侧（membership `:notify` + kanban `:emit`）= 我；**订阅/分发基建 + ⑰ 的消费** = 你；kanban 面的消费（收到 board 事件重拉 board_state）= 我，挂在你的基建上。

### 会话面状态（Y=㉒-② / ⑱ / ⑫）

- ㉒-②：tab 切换是客户端 `session.view.switch`，URL 无 view 深链，刷新即丢 tab 态落回对话 tab。
- ⑱：深色主题机制现成（root `data-theme`，root.html.heex:21 + tailwind dark variant），但 **Conversation 层**有硬编码浅色：Conversation.tsx:863（`bg-[linear-gradient(#ffffff...)]`）、:684（`bg-[#fff2a6]`）、:1724（`bg-white`）。Kanban/KanbanCanvas 里的同类**我随面板重做吸收，你别动**。
- ⑫：建会话向导「创建」按钮折叠线下点不到（SessionsTable.tsx:180-255）。

### 投影失真（Y=⑩㉑）

"kanban-assistant · 未装载"横幅读的是 install 时刻的持久快照（`unfilled_agent_role_slots`，conversation_data.ex:58 原样透传），**不对照当前成员表**——后台补员后横幅仍报未装载；向导侧 `%{skipped: ...}`（session_creator.ex:329-343 已返回）没带回显示。这是通用 role-slot 投影（任何 role 都会失真），非 kanban 界面。上游（凭证供给/补物化）归 gaga，读侧归你。

### 管理面缺失（Y=㉛⑭）

机制全在、面没有：install/retract（installation.ex:470 `installed_definitions`、#1245 卸载）、`save_session_template`（workspace_plugin_actions.ex）、邀请码（`mix ezagent.invite` → registration_controller.ex:8 消费，零管理 UI）。

### ~~unfurl 渲染~~（已改归 kanban 侧，2026-07-16 用户定）

链接解析成气泡这件事**不在本 handoff**：用户定为「world 通用的链接 unfurl 机制 + kanban 第一个消费者」，由 kanban PR 一并做（我们修完要靠它跑 e2e 回归）。机制会做成通用注册式（plugin 声明链接模式→气泡渲染器），落地后其他 plugin 可复用——如影响你 Conversation 渲染层的接口，我们先出 payload 约定同步你。

### dev 前端体验（Y=⑬）

WS 退 longpoll / vite 冷启骨架屏：最可能因 = endpoint.ex:31 `check_origin` 拒 `http://<IP>` 握手 → 退 longpoll；vite dev server 时序（world_live.ex:549 `world_module_url`）。

## 4. 方案（建议 4 个 phase / PR）

### Phase A —— 推送订阅/分发基建 + ⑰（优先，我们 PR 的 kanban 刷新等你接口）
1. 通用订阅基建：per-user notification 分发 + "打开中的 plugin 数据 topic"订阅/退订通道（照 maybe_subscribe_pty 先例做成可复用形态；退订照 :149-155 教训）。给 kanban 面留挂载点（我方分支代码用你的接口订 board topic）。
2. ⑰ 消费：`handle_info({:notification, _, {:membership_changed, session_uri}})` → 重拉会话列表/成员面板推 `world:state`。
3. **红线**：只订 `:events` 族 topic，绝不 `PubSub.broadcast` 到 inbound（P14）；不引轮询替代（扩大 `@refresh_ms` 是抱薪救火）。

### Phase B —— 会话面状态
1. ㉒-② view 深链：`/sessions?session=...&view=kanban_board`（`Routes.route_for` + React 读写），刷新/直开不掉回对话 tab（view 名是通用参数，不算 kanban 界面）。
2. ⑱ Conversation 层硬编码浅色换 token（`bg-background`/dark variant），锚点见 §3。
3. ⑫ 向导 max-height + overflow 或按钮固定底部。

### Phase C —— 投影修 + 管理面
1. ㉑：读 `unfilled_agent_role_slots` 后对照当前成员表（`:session` slice members 的 role_name）剔除已有成员的行（conversation_data.ex:58 + conversation_actions.ex:965 同款）。
2. ⑩：建会话链路把 `%{skipped: ...}` 带回向导一次性提示（"kanban-assistant 未装载：缺 Claude 凭证"——文案按 gaga 侧结构化 reason 渲染）。
3. ㉛：会话设置面——已装 sw 列表 + 多选装/卸 + 「保存为 session template」（actions 全现成，纯接线）。
4. ⑭：邀请码管理卡（铸/列/失效；identity 薄 API 缺口先在 return 里报，形态可先只列+失效）。

### ~~Phase D~~（unfurl 已改归 kanban PR，本 handoff 收 Phase A-C）

### 搭车 —— ⑬ dev 前端
`check_origin` 修（dev.exs `check_origin: false` 或列 IP）+ vite 冷启时序。

## 5. 接口约定（与我方的契约，以我 PR 落地为准）

| 事件/动作 | 通道 | payload（草案） | 谁消费 |
|---|---|---|---|
| 成员变动 | `Ezagent.Notifications.topic(member_uri)`（per-user，现成） | `{:membership_changed, session_uri}` | 你（⑰） |
| 看板变更 | board agent 的 events topic（我 PR2 定名） | `{:kanban_changed, board_uri}`（收到只做"重拉"，不带增量） | 我（kanban 面，挂你基建） |
| 气泡点击挂载 | dispatch 动作 `kanban.claim_shared`（我定义） | `%{token: ..., session_uri: 当前会话}` | 我（动作本体）；你只接线 |

## 6. DoD（return 时逐行对账；四属性见 dev-together handoff-standard）

- [ ] 两账号真 UI e2e：A 把 B 加进会话 → B 的会话列表/成员面板**不手动刷新**即更新（⑰），每步截图（e2e 规矩：每个有意义步骤截图，非只最终）
- [ ] 订阅基建有挂载点文档 + 一条演示订阅（kanban board topic 由我方接，你附通道可用的测试证明）
- [ ] 深链：刷新/直开带 view 参数的 URL 落在对应 tab，不回对话 tab
- [ ] 深色主题走查：Conversation 层无白屏/刺眼块（截图对比）
- [ ] ㉑ 后台补员后横幅消失；⑩ 向导显示 skipped 提示（LiveViewTest 或 agent-browser 证明）
- [ ] ㉛ 装/卸/存模板三动作真 UI 走通；⑭ 邀请码面可铸/列/失效
- [ ] ㉝ 分享链接在 chat 渲染成可点气泡（点击接到约定动作名，动作可先 stub 等我方）
- [ ] ⑬ `http://<IP>` 访问 WS 不退 longpoll（网络面板证明）
- [ ] Playwright Tier-1（assets/e2e/，#1432）绿 + 新面补 spec
- [ ] All gates green：arch.scan / doc.scan / uri_query.scan / check_invariants / format / test / frontend-ci
- [ ] CI（precommit + check_invariants）绿 on PR head + rebase main（机器 return gate）

## 7. 红线（discuss-first）

- **不动** kanban 面文件：`Kanban.tsx` / `KanbanCanvas.tsx` / `kanban_data.ex` / `kanban_actions.ex` / `plugin_page_registry.ex` kanban 条目 / `board_provision.ex` / kanban plugin —— 全我方在飞，动作签名以我 PR 为准。
- **不动** `SessionView.authorize_view`/T2-2b 契约，**不改** `BoardView.applies_to?` 恒 true（Allen D3 决策中）。
- **不做**前端"补拉"绕过 cap（没钥匙=空列表是正确行为，授权洞由 join 补发修）。
- **不引**独立轮询替代推送。
- 订阅只订 `:events` 族 topic，绝不 `PubSub.broadcast` 到 inbound（P14）。

## 8. 冲突面 / merge

你 own：`world_live.ex` 订阅基建与 membership 分支、`Conversation.tsx`（消息渲染/主题）、`SessionsTable.tsx`、`conversation_data.ex` 投影行、管理面新组件、endpoint dev 配置。`world_live.ex` 是共享文件：基建先行（你），kanban 分支后挂（我），以你的基建接口为准。PR 进你的任务分支（不进 main），rebase main，lead 合并。
