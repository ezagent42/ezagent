# 怎么在 session 中操作（当前 UI 实证）

> 基线：worktree `kanban-agent-e2e`（feat/kanban-agent-e2e，2026-06-26）。
> 已用 skill `project-discussion-esr-ng` 核实；下面每条论断都带 `file:line` 实证，逐文件读码确认，没跑通的地方明确标注。
> 面向新人：照着点、照着 dispatch 就能复现。

---

## 0. 先把一句话讲清楚

"在 session（会话）里操作" 当前 UI 实际有**两套独立的入口**，新人最容易混淆：

1. **会话本身的操作面 = Conversation（对话）视图**（`/sessions?session=<uri>`）。在这里发消息、邀请成员、加路由规则、重启编排器、开 PTY。**派活 / 触发 agent 的主路径就在这里**。
2. **看板的操作面 = Kanban（看板）视图**（`/plugins/kanban/...`），**不在 Conversation 视图里**。看板本身是一个独立 agent，节点操作是对那个 agent 发 dispatch，跟会话没有直接关系。

两者之间唯一的"桥"叫 **B1（`bind_session`）**：把一张看板绑到某个会话，之后看板上的认领/改状态/挂 PR 会**自动往那个会话发一条公告，公告重入会话路由 → 触发下一个 agent（接力）**。

下面按"在会话里操作"和"看板接力"两条线分别讲，每步都给出"点哪 + dispatch 什么"。

---

## 1. 会话操作面的物理布局（先认清界面）

Conversation 组件是左右两栏：左边是聊天流，右边约 260px 的侧栏。
证据：`apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:319`（`lg:grid-cols-[minmax(0,1fr)_260px]`）。

右侧栏从上到下三块：

| 区块 | 干什么 | 代码位置 |
|---|---|---|
| 顶部按钮 | 切 PTY 视图、**Restart orchestrator（重启编排器）** | `Conversation.tsx:352`（PTY）/ `:355`（Restart orchestrator）|
| **Members（成员）** | 列成员 + **Invite（邀请）** 按钮 | `Conversation.tsx:557`（标题）/ `:560`（Invite 按钮）/ `:584`（输入 entity URI）|
| **Routing（路由）** | 加/开关路由规则 | `Conversation.tsx:648`（标题）/ `:654`（matcher 下拉）/ `:670`（receivers 输入）|

聊天输入框在左栏底部，支持 `@` 提及自动补全：`Conversation.tsx:488`（placeholder "Type a message… @ to mention"）。

**前端所有操作的统一出口**都是 `pushEvent("world:dispatch", {action, args})`，后端 `WorldLive` 按 action 名字分发。会话类的 12 个 action 走一张白名单 `@conversation_actions`（`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:236`），全部委托给 `Ezagent.World.ConversationActions.handle_dispatch/3`（`world_live.ex:238`）。

---

## 2. 在会话里"派活 / 触发 agent" —— 三步

核心模型：**消息发进会话 → 会话按路由规则把消息扇出（fan-out）给 receivers → receiver 是 agent 就投递给它 → agent 被触发**。
所以"派活"= 配好路由规则，"触发"= 发一条命中规则的消息。

### 步骤 A：把 agent 拉进会话当成员（Invite）

- **点哪**：右侧栏 Members 区的 `Invite` 按钮，填 agent 的 entity URI（形如 `entity://<workspace>/agent/<id>`）。
  代码：`Conversation.tsx:560`（按钮）→ `:572` 触发 `onInvite`。
- **dispatch 什么**：前端 `onInvite` 发 `session.invite`（`apps/ezagent_plugin_world/assets/src/main.tsx:258`）。
- **后端链路**：`ConversationActions.handle_dispatch("session.invite", …)`（`conversation_actions.ex:57`）→ `invite_member/3`（`conversation_actions.ex:395`）。它先把可能还"冷"的成员从快照拉起（`demand_spawn_member`，`conversation_actions.ex:405`），再 dispatch：
  ```
  target: session://… ?action=session.join     # Ezagent.URI.with_action(session_uri, :session, :join)
  mode:   :call
  args:   %{member: member_uri}
  ```
  证据：`conversation_actions.ex:408-413`。成功后给被邀成员挂上参与能力（`Membership.mount_participation_caps`，`conversation_actions.ex:417`）。

> 说明：邀请人自己的 `:join` 权限来自上线时的自加入（`self_join`），不是手搓判断——见 `conversation_actions.ex:383-392` 注释。

### 步骤 B：加一条路由规则，把"什么样的消息"派给"哪个 agent"

这一步就是把"活"接进路由（对应主题里说的"动作进路由 / routing"）。

- **点哪**：右侧栏 Routing 区。两个控件：
  - matcher 类型下拉，4 个选项：**Always / Mention / From / Text contains**（`Conversation.tsx:654-658`）。
  - receivers 输入框，逗号分隔（`Conversation.tsx:670`）。
  提交按钮在 `Conversation.tsx:676`，触发 `submitRule`（`Conversation.tsx:303`）。
- **dispatch 什么**：前端 `onAddRoutingRule` 发 `session.routing.add`，args 带 `{matcher_type, matcher_arg, receivers}`（`main.tsx:282` + `Conversation.tsx:308-312`）。
- **后端链路**：`handle_dispatch("session.routing.add", …)`（`conversation_actions.ex:81`）→ `add_routing_rule/3`（`conversation_actions.ex:331`）：
  1. 把表单的 matcher 类型翻译成真正的 matcher（`build_session_form_matcher/1`，`conversation_actions.ex:612`）：
     - `mention` → `Ezagent.Routing.Matcher.mention(text)`（`:617`）
     - `from` → `…Matcher.from(text)`（`:620`）
     - `text_contains` → `…Matcher.text_contains(text)`（`:623`）—— **看板接力就靠这个**，见第 4 节
     - `always` → `…Matcher.always()`（`:626`）
  2. receivers 按逗号切（`parse_session_receivers/1`，`conversation_actions.ex:636`）。
  3. 用 `wrap_in_session` 把规则限定在当前会话（`conversation_actions.ex:337`），再 dispatch：
     ```
     target: session://… ?action=routing.add_rule   # with_action(session_uri, :routing, :add_rule)
     mode:   :call
     args:   %{table: MentionRouting, matcher_json: …, receivers: …}
     ```
     证据：`dispatch_session_routing/4`（`conversation_actions.ex:338-343` 的 `:add_rule`；target 拼法见该函数体 `with_action(session_uri, :routing, action)`）。规则写进 `MentionRouting` 路由表（`conversation_actions.ex:22` 的 alias + `:341`）。
- **开关规则**：`session.routing.toggle`（`main.tsx:288` → `conversation_actions.ex:86` → `toggle_routing_rule/3` `:362`），enable/disable 同一条。

> receivers 写什么？写 agent 的标识（成员/槽位名或 URI），由会话侧路由解析器在扇出时解析（`Conversation.tsx:765` 注释："a clean single token the server-side mention parser resolves"）。

### 步骤 C：发消息 —— 真正"触发"agent 的动作

- **点哪**：左栏底部输入框打字，回车发送。`@` 可提及成员（`Conversation.tsx:488`）。
- **dispatch 什么**：`chat.send`，args `{session_uri, text, grants}`（`main.tsx` 的 onChat 回调 → 白名单 `world_live.ex:236`）。
- **后端链路**：`handle_dispatch("chat.send", …)`（`conversation_actions.ex:34`）→ `send_message/4`（`conversation_actions.ex:131`）：
  ```
  target: session://… ?action=session.send       # with_action(session_uri, :session, :send)
  mode:   :cast                                    # 注意是 cast，不是 call
  args:   %{message: msg}
  ```
  证据：`conversation_actions.ex:141-149`。**用 `:cast`**——发出去就返回，消息通过 inbound 桥回流给发送者，所以前端不做乐观插入（`conversation_actions.ex:120-125` 注释）。
- **会话侧扇出**：消息落到会话 Kind 的 `handle_send/2`（`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:433`）：
  1. 先持久化（`MessageStore.write`，`session.ex:447`）——写失败即发送失败，不静默丢（`session.ex:445` 注释）。
  2. 交给 Resolver 做**唯一的路由决策**（`session.ex:461-463` 注释："Resolver is the SINGLE source of truth for routing decisions. No hardcoded fan-out"）。会话内成员的默认扇出，是一条 `receivers: ["$session_members"]` 的系统默认规则（`session.ex:462-464`）。
  3. 命中规则的 receiver 若是 agent，就走 `Ezagent.Behavior.Session.Delivery.deliver_agent_receive/2` 投递（`session.ex:35-37`、`:585-586`），agent 被触发干活。

**小结（派活/触发的最小闭环）**：Invite agent（步骤 A）→ 加一条 `mention <agent>` 或 `always` 的路由规则、receiver 填该 agent（步骤 B）→ 发一条命中的消息（步骤 C）→ Resolver 扇出 → agent 收到 → 触发。

### 会话面其它操作（顺带）

| 操作 | 点哪 | dispatch | 后端 |
|---|---|---|---|
| 切 PTY 视图看某 agent 终端 | 顶部 PTY 按钮 | `session.pty.open` | `switch_to_pty/3` `conversation_actions.ex:282` |
| 重启编排器（卡死时修复） | 顶部 Restart orchestrator | `session.orchestrator.restart` | `restart_orchestrator/2` `conversation_actions.ex:312` → `repair_orchestrator`（`:316`，仅 admin，`:313`）|
| 切会话 | 顶部下拉（>1 会话时显示）| `session.switch` | `conversation_actions.ex:50`，push_patch 到 `?session=` |
| 新建会话 | Sessions 列表的建会话表单 | `session.create`（只问 `short_name`+`template_name`）| `create_session/3` `conversation_actions.ex:202` → `Workspace.create_session/3` |

---

## 3. 看板操作面（不在会话视图里，单独讲）

新人最大的误解：**看板不在 Conversation 视图里操作**。看板有自己的页面，且看板本身就是一个 agent。

### 看板 = 一个 passive agent

- 一张看板 = role `kanban-manager` × flavor `native` 的 agent，board 数据是该 agent 快照的 `:kanban` slice。这条 recipe 在 boot 时由 kanban 插件 `roles/0` 注册，**含 `passive: true`**（`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:294` 注释）。
- **passive 的含义**：看板 agent 没有聊天流量给它"保温"，BEAM（Erlang 虚拟机）重启后即使没活着，也能从持久化快照里枚举出来（`apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:60`），需要时用 `ensure_spawned/1` 从快照重新拉活（`kanban_data.ex:93`）。这就是"kanban passive"。

### 看板页面 & 节点操作怎么 dispatch

- **路由**：`/plugins/kanban`（列表）和 `/plugins/kanban/<编码后的 entity://<ws>/agent/<id>>`（单张板），归 Plugins 组（`apps/ezagent_plugin_world/lib/ezagent/world/routes.ex:89`/`:100`）。
- **新建看板 = 建 agent**：`KanbanActions.create_kanban`（`kanban_actions.ex:296`）调 `Workspace.create_agent(ws, %{flavor: "native", role: "kanban-manager", …})`。
- **节点操作（加节点/认领/改状态/挂 PR 等）**：前端 `Kanban.tsx` 的按钮调 `onAction("kanban.<x>", args)`（如 `kanban_actions` 同步 Miro 按钮 `Kanban.tsx:179`）。后端用一张 24 个 action 的白名单 `@kanban_actions`（`world_live.ex:242`）拦下，转 `KanbanActions.handle_dispatch`（`world_live.ex:244`）。每个 handler 经 `act/4`（`kanban_actions.ex:168`）拼出：
  ```
  target: entity://<ws>/agent/<id>?action=kanban.<action>   # URI.with_action(uri, :kanban, action)
  mode:   :call
  ```
  打到 `Behavior.Kanban`。world 层退成纯转发器，连接器逻辑（GitHub/Miro/PR）全在 Behavior 里。

> 授权诚实：ctx 带的是登录的人类用户身份（`current_entity_uri`/`current_caps`），不重写成 agent 身份，节点 owner 授权在 Behavior 内如实判（`kanban_actions.ex:351` 的 `ctx/1`）。

---

## 4. 看板 ↔ 会话的桥：B1（`bind_session`）+ 接力（relay）

这是主题里"B1 动作进路由"的真身。**B1 就是看板的 `bind_session` action**。

### B1 是什么

- Behavior 声明：`action(:bind_session, …)`，描述原文就写着 "（B1）"：
  > "绑定本看板到一个会话（B1）：之后认领/状态/挂PR 等动作会向该会话 session.send 一条公告，重入路由触发下一个 agent（接力）"
  证据：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:225-230`。
- 绑定关系存在板级配置里（`BoardConfig`，`kanban.ex:719-721` 的 `board_session`）。

### 接力机制（动作怎么"进路由"）

看板 Behavior 用 `post_handle`（动作成功后的钩子）实现接力，只对三个"接力动作"生效：

```elixir
@relay_actions [:claim_node, :set_status, :register_pr]   # kanban.ex:702
```

逻辑（`kanban.ex:704-715`）：当这三个动作之一成功、且本看板绑了会话，就往那个会话注入一条 `{:dispatch}` 到 `session.send`，公告文本是带机器可读标记的：

```
"[kanban:claimed] by <操作者>"     # set_status → [kanban:status]，register_pr → [kanban:pr_registered]
```

证据：`relay_text/2`（`kanban.ex:726-736`）。注释明说"消息只做触发器，不做数据源"（`kanban.ex:723`）——被触发的 agent 自己去 `get_tree` 读真相源。

### 闭环：B1 + routing + passive 三者怎么咬合

1. **passive**：看板 agent 静静躺着（第 3 节）。
2. **B1**：把看板 `bind_session` 到某会话（板级配置记下 session_uri）。
3. 有人在看板上 `claim_node` / `set_status` / `register_pr`。
4. `post_handle` 自动往绑定的会话 `session.send` 一条 `[kanban:claimed] by …` 公告（动作"进了路由"）。
5. 公告进会话 `handle_send`（`session.ex:433`）→ Resolver 扇出。
6. 如果你在第 2 节步骤 B 用 **Text contains** 类型加了一条规则、matcher_arg 填 `[kanban:claimed]`、receiver 填某 agent（`build_session_form_matcher` 的 `text_contains` 分支，`conversation_actions.ex:623`），公告就命中这条规则 → 触发那个 agent（接力到下一棒）。

这就是"kanban passive + B1 动作进路由 + routing"拼成的完整链：**看板上的人工动作 → 公告 → 会话路由 → 下一个 agent 自动接手**。

---

## 5. 新人必须知道的两个"坑/缺口"（实证）

1. **B1（`bind_session`）当前没有 world 前端入口。**
   全仓 `grep "bind_session" apps/ezagent_plugin_world/{lib,assets}` 返回空（exit 1），而且 `world_live.ex:242` 的 `@kanban_actions` 白名单 24 个 action 里**没有 `kanban.bind_session`**。
   含义：B1 的 Behavior 实现是齐的（`kanban.ex:225`、`:697`），但**当前 UI 上没有按钮去绑定会话**——只能由编排器 agent 或程序化 dispatch 触发。想在界面上走通"看板接力"，要么补这个入口，要么用 iex/编排器直接 dispatch。这是一个真实缺口，不是你操作错了。

2. **看板和会话是两个分区，别在 Conversation 视图里找看板。**
   看板在 Plugins 组（`routes.ex:89`），会话在 Sessions 组（Conversation 视图）。两者只通过 B1 关联。新人若在对话视图里找"加看板节点"会找不到——那是设计上的信息架构划分，不是 bug。

---

## 6. 一页速查（点哪 → dispatch → 落到哪）

| 想干的事 | 点哪 | 前端 action | 后端落点（target / 函数）|
|---|---|---|---|
| 拉 agent 进会话 | Conversation 右栏 Invite | `session.invite` | `session.join` dispatch（`conversation_actions.ex:408`）|
| 配"派活"规则 | Conversation 右栏 Routing | `session.routing.add` | `routing.add_rule` → MentionRouting（`conversation_actions.ex:338`）|
| 开关规则 | Routing 区开关 | `session.routing.toggle` | `routing.enable/disable_rule`（`conversation_actions.ex:362`）|
| 触发 agent | 左栏发消息 | `chat.send` | `session.send` cast → Resolver 扇出（`conversation_actions.ex:141` / `session.ex:433`）|
| 看 agent 终端 | 顶部 PTY | `session.pty.open` | `switch_to_pty`（`conversation_actions.ex:282`）|
| 修复卡死编排器 | 顶部 Restart orchestrator | `session.orchestrator.restart` | `repair_orchestrator`（`conversation_actions.ex:316`）|
| 建看板 | /plugins/kanban | `kanban.create` | `Workspace.create_agent`（`kanban_actions.ex:296`）|
| 看板节点操作 | /plugins/kanban/<板> | `kanban.<action>` | `entity://…?action=kanban.<x>`（`kanban_actions.ex:168`）|
| 看板绑会话（接力）| **当前无 UI 入口** | （`kanban.bind_session`，未挂前端）| `handle_bind_session`（`kanban.ex:697`）|

---

## 附：本文核实方式

- 已加载 skill `project-discussion-esr-ng`（根目录），按其"读当前代码 + 给 file:line 实证"流程作业。
- 所有 `file:line` 均在本 worktree（`kanban-agent-e2e`）当前 HEAD 逐文件读码确认。
- 未实跑浏览器 E2E；UI 交互按前端组件代码 + dispatch 链路推断，缺口（B1 无前端入口）已用 `grep` 实证（返回空 / 白名单不含）。要进一步确认运行时，建议起 dev server 走一遍 Conversation 发消息 + /plugins/kanban，并按团队规矩每步截图。
