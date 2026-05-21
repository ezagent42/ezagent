# Phase 2 — SPEC

> Phase 2 brainstorm 产出 + 5 个核心决策 + 3 sub-step 切分。
> 配套:`VERIFICATION.md` / `PLAN.md` / `DECISIONS.md`
> 上游:Phase 1 完成(tag `phase1b` @ `f14e84f`,merged to main `22ebb72`)+ 架构师 Phase 1 sign-off review + ARCHITECTURE.md §12.8 Phase 1b 后重写

## 目标

把 ezagent_core 从 "能 invoke 单个 behavior 的 router" 升级到 "能在多个 agent 之间 route Message 的 router"。这是 Decision #61("Ezagent 是 router 不是 req/resp app")在代码层的**第一次真正落地** — 让 LV(代表 Allen)和 claude(经 bridge 接入)在 Ezagent 内部**对称地**作为 Session 内 chat 参与者,通过 Message envelope 互发。

Phase 1 → Phase 2 关键不变量变化:LV 输入和 claude 回复**在系统里成为同种数据**(`%Ezagent.Message{}`),走同一条 dispatch 路径(`session://main/behavior/chat/send`),持久化到同一表(`messages`),LV 上**视觉上 indistinguishable**(无 Phase 1 的"← from claude"独立面板)。

## 测试员体验 / demo

完成 Phase 2 后 Allen 能做到:

1. 启动 `mix phx.server`(Ezagent)+ 另一个终端 `bash scripts/cc-bridge-attach.sh`(真 claude session)
2. 浏览器开 `http://100.64.0.27:4000/admin`
3. 主视野是**chat 窗口形态**:消息流(垂直,自动滚动)+ session 成员侧栏 + 底部 compose 区
4. 成员侧栏显示 `user://admin · online` + `agent://cc-builder · online`
5. compose 输入"你好",bridge dropdown 选 cc-builder,发送
6. claude TUI 看到 `<channel source="esr-bridge" sender="user://admin">你好</channel>`
7. claude 回复
8. LV 主流多两条 chat row:`[admin]: 你好` / `[cc-builder]: <回复>`,**同一种 row 模板,只发言人不同**
9. Ctrl-C claude → LV 显示 cc-builder offline + last seen 时间
10. Allen 在 LV 继续发"还在吗?" → 消息持久但无人 receive
11. 重跑 attach script → claude 重连 → 收到 replay 的"还在吗?"+ 给新回复 → LV 显示 cc-builder online + 新 chat row

**Phase 1 的 Debug 功能(Echo button / Manual Dispatch / Audit Log)**:仍可达,折叠在 "Debug" 区(右侧或下方),不占主视野。

## Sub-step 结构

**3 个 sub-step,顺序 2a → 2b → 2c**:

| sub-step | 主题 | 主交付 | LOC ~估 | tag |
|---|---|---|---|---|
| **2a** | data 层 | `Ezagent.Message` + `Ezagent.MessageStore`(schemaful Ecto) + `Ezagent.Behavior.Chat` 接口契约 + SQLite migration | ~150 core(message ~25 + message_store ~50 + chat 接口 ~30 + migration ~20 + tests ~25 LOC reserved) | `phase2a` |
| **2b** | router 接线 | `Ezagent.Entity.Session` / `User`(升级真 Kind)/ `Agent` + Chat Behavior 4 actions invoke + Process.monitor + boot/dynamic spawn + LV 加 Session 成员显示 | ~250 LOC across plugins + 改 ezagent_core Application children | `phase2b` |
| **2c** | bridge 切换 + 真双向 e2e + chat UI 重建 | controller 改 forward to Agent / Agent Kind 自构造 Message / LV chat-window 重建 / Phase 1 "← from claude" 面板删 / offline-rejoin 状态机生效 | ~150 LOC(controller wire ~20 + Agent 转 dispatch ~30 + LV chat UI ~100),4 个 internal commit steps | `phase2` = phase 2 整体完成 |

## 5 brainstorm 核心决策

(详 DECISIONS.md;此处简述,跟 Q1..Q5 编号对应)

### P-1 `%Ezagent.Message{}` shape

```elixir
%Ezagent.Message{
  uri:         "message://<uuid16>",   # auto-gen at new/3, identity reference
  sender:      URI.t(),                # 谁创建
  mentions:    [URI.t()],              # 提到/针对的 URI 列表
  body:        %{text: String.t(), attachments: [URI.t()]},  # 结构化
  ref:         URI.t() | nil,          # ^reply-to 另一条 message URI
  inserted_at: DateTime.t()
}
```

构造器:`Ezagent.Message.new(sender, body, opts \\ [])`(idiomatic Elixir,sender+body 必填,其余 keyword opts)。identity invariant 仍锁原 5 字段(uri 是 identity reference 不是 identity payload)。

### P-2 Chat Behavior

- Module:`Ezagent.Behavior.Chat`
- Actions menu:`[:send, :receive, :join, :leave]`
- Per-Kind register subset:
  - `Ezagent.Entity.Session` 注册 `{Session, :send}` + `{Session, :join}` + `{Session, :leave}`
  - `Ezagent.Entity.Agent` 注册 `{Agent, :receive}`
  - `Ezagent.Entity.User` 注册 `{User, :receive}`

### P-3 K 路径 dispatch + state shape

K 路径(每个外部参与方有自己的 Kind 持 Chat Behavior 的 receive 端)— Ezagent-as-router 真落地。Session.Chat state slice:

```elixir
%{
  members:    MapSet<URI.t()>,           # roster(online + offline)
  online:     MapSet<URI.t()>,           # alive 子集
  last_seen:  %{URI.t() => DateTime.t()},# 每个 URI 最后 :DOWN 时间
  monitors:   %{reference => URI.t()}    # Process.monitor refs
}
```

Failure design:
- Process.monitor on join → `:DOWN` 触发自动 offline(保留 roster + 写 last_seen)
- rejoin 时从 MessageStore.in_session_since/2 replay,不维护独立 pending queue(避免 store 重复)
- explicit `:leave` 是 caller 明确意图 → 移 roster + 丢弃 last_seen
- BEAM 重启 Session state 重置(ephemeral),MessageStore 持久(historical messages 仍渲染)

### P-4 Bridge agent URI 来源

- Python bridge 启动通过 env `EZAGENT_AGENT_URI` 拿 preferred URI(`cc-bridge-attach.local.sh` 配,gitignored,operator 自定义)
- bridge announce body 多带 `agent_uri` 字段
- Ezagent `CcBridgeAnnounceController.announce` 动态 spawn `Ezagent.Entity.Agent` Kind 实例
- LV dropdown 动态读 KindRegistry 列出所有 connected agents
- **ZERO hardcoded URI in code**;default 值只在 `.local.sh.example` 中(operator-level config)

### P-5 admin User Kind 真 spawn + claude reply 路径

- admin User Kind 在 boot 时真 spawn(`user://admin`),持 Chat Behavior `:receive`
- bridge POST `/api/cc-bridge/reply` 时:
  - Controller 收到 → 调 `Ezagent.Bridge.V1Prototype.Server.forward_reply_to_agent(bridge_id, text)`
  - Server 通过 bridge_id 找对应 Agent Kind pid → 发 `:reply_received` message
  - Agent Kind 自己 GenServer 内构造 `%Ezagent.Message{sender: self_uri, body, mentions: ...}` → dispatch `session://main/behavior/chat/send`
  - 这跟 LV 提交时路径**完全对称**(LV 也是构造 Message → dispatch `session://main/behavior/chat/send`)

## 2a Deliverables

**核心 4 模块**:
- `apps/ezagent_core/lib/esr/message.ex`(~25 LOC):defstruct 6 字段 + new/3 + `Jason.Encoder` impl(URI 字段 stringify)+ optional `Ecto.Schema` 同 file
- `apps/ezagent_core/lib/esr/message_store.ex`(~50 LOC):4 函数 API(`write/2`, `in_session_since/2`, `recent_in_session/2`, `by_uri/1`),Ecto query DSL
- `apps/ezagent_core/lib/esr/ecto/uri_type.ex`(~15 LOC):Ecto custom type `Ezagent.Ecto.URI`,implement `load/1` `dump/1` `cast/1`,allow URI struct ↔ string 自动转
- `apps/esr_plugin_chat/lib/esr/behavior/chat.ex`(~30 LOC,plugin 形式):`@behaviour Ezagent.Behavior`,actions/0 返回 4-element menu,interface schema 声明 `:send` args 是 `%Ezagent.Message{}`;invoke 各 clause 暂留 `{:error, :not_yet_implemented_in_2a}`(2b 才写完)

**Ecto migration**(`apps/ezagent_core/priv/repo/migrations/...phase2_messages.exs`):
- `messages` 表 7 列:`uri PK / session_uri / sender / mentions JSON / body JSON / ref / inserted_at`
- 2 索引:`(session_uri, inserted_at)` + `(sender)`

**测试**(`apps/ezagent_core/test/esr/`):
- `message_test.exs`:new/3 各 opt 组合,URI auto-gen,Jason 序列化 round-trip
- `message_store_test.exs`:write/in_session_since/recent_in_session/by_uri 各自单元 + 排序确认 + sandbox checkout
- `ecto/uri_type_test.exs`:URI struct ↔ string round-trip via Ecto.Type API
- `apps/esr_plugin_chat/test/esr/behavior/chat_interface_test.exs`:@interface schema 形态(各 action args schema)

## 2b Deliverables

**新 Kind 模块**(在 `apps/esr_plugin_chat/lib/esr/entity/`):
- `session.ex`(~15 LOC):@behaviour Ezagent.Kind,type_name :session, behaviors [Ezagent.Behavior.Chat], persistence :ephemeral(state 不持久,只在 GenServer 内)
- `agent.ex`(~15 LOC):type_name :agent, behaviors [Ezagent.Behavior.Chat], persistence :ephemeral
- **Phase 1 `Ezagent.Entity.User` 升级**:从 stub Kind 改为真 Kind — behaviors `[Ezagent.Behavior.Chat]`,admin_uri/admin_caps 保留

**Chat Behavior 4 invoke clauses 完整实现**(`apps/esr_plugin_chat/lib/esr/behavior/chat.ex` 接入主体):
- `invoke(:send, slice, %Ezagent.Message{} = msg, ctx)`:写 MessageStore + broadcast session events PubSub + for each mention in online: dispatch URI/behavior/chat/receive
- `invoke(:receive, slice, %Ezagent.Message{} = msg, ctx)`:通过 **`ctx.kind_module`**(由 `Ezagent.Kind.Runtime` 在调 invoke 前注入)分支:
  - `ctx.kind_module == Ezagent.Entity.Agent` → push to bridge SSE(经 `Ezagent.Bridge.V1Prototype.Server` 的 per-bridge to_claude topic)
  - `ctx.kind_module == Ezagent.Entity.User` → `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:user:<self_uri>:events", {:message_received, msg})`(LV /admin 订阅)
  - `kind_module` ctx injection 是 2b-step 1 对 `Ezagent.Kind.Runtime.handle_dispatch/3` 的 1-line patch
- `invoke(:join, slice, %{uri: u}, ctx)`:add to members + online + Process.monitor(KindRegistry.lookup)+ if last_seen[u] exists: replay messages from MessageStore
- `invoke(:leave, slice, %{uri: u}, ctx)`:remove from members + online + demonitor + drop last_seen

**Ezagent.Kind.Server `handle_info` 扩展**(2b-step 2 + 2c-step 1 一起做):

`Ezagent.Kind.Server.handle_info/2` 现在只 match 几个 Phase 1 case;Phase 2 加**unmatched message forwarder**:

- `{:DOWN, ref, :process, _pid, _reason}` → if 当前 kind 的 Behavior list 中有 module export `handle_member_down/2`,call 它并 update slice;否则 ignore
- `{:reply_received, text}`(来自 Bridge Server)→ if kind 的 Behavior list 中有 module export `handle_kind_message/3`(message_tuple, slice, ctx),call 它;否则 log warning + ignore

这两个 hook 用同一种"defensive forward unmatched info messages to Behavior modules"机制,实现一次。`Ezagent.Behavior.Chat` 实现两个 hook。`Ezagent.Entity.Agent` 通过 Chat Behavior 的 `handle_kind_message/3` 接到 `:reply_received`,内部构造 `%Ezagent.Message{}` + dispatch `session://main/behavior/chat/send`。

**Server `forward_reply_to_agent` 用 `send/2` 不是 `cast/2`**:`Ezagent.Bridge.V1Prototype.Server.forward_reply_to_agent(bridge_id, text)` 用 `send(agent_pid, {:reply_received, text})` 投递,landed 在 Kind.Server 的 `handle_info`(per 上)。NOT `GenServer.cast`(会撞 Phase 1 `handle_cast({:ezagent_dispatch, _}, _)` 唯一 clause)。

**Application boot**(2b-step 1):
- ezagent_core Application children 加 `Ezagent.Entity.Agent.Supervisor`(DynamicSupervisor)— 给 bridge announce 时 spawn 用
- esr_plugin_chat Application start/2 时 **按序** spawn:
  1. `Ezagent.Entity.Session` at `session://main`(用 Supervisor.start_link with explicit ordering;不依赖默认 children list order)
  2. `Ezagent.Entity.User` at `user://admin`(**替换** Phase 1 admin_uri/admin_caps stub Kind 形态)
- admin User Kind **在 `handle_continue(:announce_ready, ...)` 中** dispatch `session://main/behavior/chat/join`(**not in `init/1`** — `init` 内 synchronous call 给 Session 会撞 supervisor 启动竞态)
- Join dispatch 用 `:cast` 模式 — 若 Session 还在 `:not_ready`(Phase 1 reliability primitives,ReadyGate),`Ezagent.PendingDelivery` buffer until Session announce_ready 后 flush
- 因此 boot 不论顺序都收敛:Session 先起 → admin join 直接命中;Session 后起 → admin join 进 PendingDelivery,等 Session announce_ready 时 flush 同效果

**LV `/admin` 改动(2b 范围)**:
- 加 "Session" 区域显示 session://main 成员列表(从 KindRegistry + Session.Chat state PubSub 实时更新)
- 显示成员在线状态(online / offline)
- 暂不改主 message stream UI(2c 再做)

**测试**:
- Chat Behavior 4 actions 各自单元测试 + 集成测试(spawn 2 个 mock Kind,join/send/leave 验 dispatch propagation)
- Process.monitor + `:DOWN` 路径集成测试(kill 一个 Kind GenServer,验 Session 状态更新)
- Phase 1 functionality 回归测试(Echo button / Manual Dispatch 不退化)

## 2c Deliverables

**Controller 改造**(`apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex`):
- `announce/2` 改:除了 register 到 V1Prototype.Server 还触发 spawn `Ezagent.Entity.Agent` Kind(at agent_uri)
- `reply/2` 改:**不再调** `Ezagent.Bridge.V1Prototype.Server.record_reply`(这条 Phase 1 的状态机砍掉);改为 `forward_reply_to_agent(bridge_id, text)`,内部由 Server 找到 Agent Kind 然后发信
- `disconnect/2` 改:除了 unregister 还 terminate Agent Kind(through Server)

**Bridge Server 扩展**(`apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/server.ex`):
- `forward_reply_to_agent(bridge_id, text)` 新 API
- 内部维护 `bridge_id -> agent_pid` 映射,通过它找 Kind 发 `{:reply_received, text}` cast

**Agent Kind 内部 handle_info**:`{:reply_received, text}` → 构造 `%Ezagent.Message{sender: state.uri, body: %{text: text, attachments: []}, mentions: []}` → dispatch `session://main/behavior/chat/send` via Ezagent.Invocation.dispatch

**LV chat UI 重建**(`apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex` 大改):

主视野:
- 顶部 header:Session 名 + 成员侧栏(成员列表 + online/offline 状态 + last_seen 时间戳)
- 中间 message stream:垂直,自动滚动到底,Phoenix.LiveView.stream(:messages, limit: 50)。每条 row:`[<sender short-name>] <timestamp> · <body.text>`。Allen 输入(sender 是 user://...)和 claude(sender 是 agent://...)用不同浅色背景区分,但 row 组件**同一种**(没有 Phase 1 的"← from claude"独立面板)
- 底部 compose 区:agent dropdown(从 KindRegistry 动态读)+ text input + Send button

Debug 区(折叠或独立 tab):
- Phase 1 的 Echo button / Manual Dispatch form / Audit Log table 移到这里
- 不删除,只移位

订阅:
- `esr:session:<uri>:events`:新消息广播,LV `handle_info` → stream_insert
- `esr:bridge_v1:events`:bridge connect/disconnect 触发成员列表刷新
- 老的 `Ezagent.Audit.stream_topic()`:Debug 区 audit log 仍订阅

**老 bridge_messages 面板 + bridge_messages assign 删除**:Phase 1b LV 里 `bridge_messages` panel + `:to_claude / :from_claude` 渲染逻辑 全部 cleanup,只剩 chat stream 视图。

**测试**:
- Controller `reply/2` 路径:POST → forward_reply_to_agent → Agent dispatch `:send` → MessageStore + broadcast
- Chat UI 单元(`Phoenix.LiveViewTest`):mount 加载历史 / compose form 提交 / handle_info 流插入新消息 / 成员侧栏 online/offline 切换
- 整 e2e via agent-browser:跟着 VERIFICATION 2c gate 跑,含 user-action(Allen 启动 attach)

## 前序依赖

Phase 1(tag `phase1b` @ `f14e84f`,merged to main `22ebb72`)的所有:
- ezagent_core 18 模块 dispatch backbone
- ezagent_plugin_echo(Echo Kind + Behavior)— Phase 2 不退化
- ezagent_web_liveview AdminLive Phase 1b 形态(2c 大改之但保留 Debug 区)
- ezagent_plugin_cc_bridge_v1_prototype(MCP+channel bridge,SSE 流,reply 路径)
- `.mcp.json` 项目根 drop file 机制(Decision #87)
- `scripts/cc-bridge-attach.sh` + `.local.sh` 模式
- agent-browser 验证流程

## 当前 ezagent 状态对照(Phase 2 新借鉴 / 反例)

### 借鉴(Phase 1 已用 + Phase 2 直接复用):
1. ✓ Phase 1 dispatch 12-step + Kind.Server lifecycle(K 路径 dispatch propagation 直接走这条)
2. ✓ Phase 1 Audit handler 双 fan-out(PubSub + cast Writer)pattern → Phase 2 MessageStore.write 走类似 sync write,Chat 内部 PubSub broadcast 走类似 pattern
3. ✓ Phase 1 DLQ 模式 → Phase 2 中 mention 提到 unknown URI 时走 DLQ 兜底
4. ✓ Phase 1 LV stream + handle_info pattern → Phase 2 chat stream 直接复用
5. ✓ Phase 1 Process.monitor 在 Bridge Server 已经用 → Phase 2 Chat Behavior 复用模式

### 反例(Phase 1 后 review 时识别,Phase 2 避免):
1. ❌ Phase 1b 一开始我"silently scope down"是 Phase 2 必须避免的反例 — memory `feedback_flag_user_assist_steps` + spec 中 USER ACTION REQUIRED 段落显式标
2. ❌ Phase 1 bridge_messages assign 维护 in-memory `to/from claude` map 是 Phase 2 的 anti-pattern(应该是 MessageStore-as-source-of-truth 不复制状态)— 2c cleanup 这部分
3. ❌ Phase 1 Audit Writer 写 messages 表用 schemaless `insert_all` + 手 JSON encode → Phase 2 MessageStore 走 Ecto.Schema typed insert,自动 JSON encode + 类型安全

## 不在 Phase 2 范围(boundary)

- ❌ **RoutingRegistry**(Decision #28 / §5.4)— Phase 3 引入,跟 Workspace + multi-session 一起。Phase 2 单 session,mention 直接 = receiver URI,不需 routing rules
- ❌ **Matcher**(§6.6 / Decision #71)— Phase 3 跟 RoutingRegistry 一起。Phase 2 mentions 是显式 URI list,无需文本 parsing 或字段 match
- ❌ **Workspace / Template Class / Template Instance**(§3.6 / Decision #69-#70)— Phase 3。Phase 2 单 session 不够 Workspace 用例
- ❌ **Identity Behavior**(Phase 3d)— Phase 2 admin User Kind 升级为持 Chat 但**仍是 stub**:admin_caps 继续返回 all-caps(per Phase 1 P1-D5),authz_check 仍是 stub_grant(per Decision #82)。Phase 3d 才有真 Identity + 真 cap check
- ❌ **Attachments(file URIs)**(§10.5 G)— Phase 5。Phase 2 `body.attachments` 字段保留但 LV form 不允许添加(永远是空 list)。spec 设计预留,实现 deferred
- ❌ **多 session / Cross-session routing**— Phase 3。Phase 2 单 session(`session://main`)
- ❌ **CC channel 完整 plugin `ezagent_plugin_cc`**— Phase 5。Phase 2 继续用 v1_prototype(但 controller reply 路径升级走 Agent Kind,这部分被 Phase 5 wholesale replace 时一并替换)
- ❌ **Permission relay(`claude/channel/permission`)**— Phase 5
- ❌ **多 claude session 同时连接**— Phase 5。Phase 2 boundary:技术上多 bridge 可以同 announce(每个走不同 agent URI),都加入同 session://main,但 LV / Chat 行为是否 production-ready 不验证;Phase 2 唯一 demo path 是 1 个 claude
- ❌ **Permission gating on Chat send**— Phase 3d cap 真化后才加;Phase 2 send 永远走 stub_grant

## v1_prototype 命名约定(沿用)

`apps/ezagent_plugin_cc_bridge_v1_prototype/` 整 plugin 保留 `_v1_prototype` 后缀,Phase 5 由 `ezagent_plugin_cc` wholesale replace。Phase 2 在该 plugin 内的改动(controller reply 路径走 Agent Kind 等)Phase 5 替换时一并扔。

## 跟 architect 后续 sync 点

Phase 2 完成时建议 architect append 到 GLOSSARY:
- **#88** Phase 2 Chat Behavior K 路径实施落地(actions menu + per-Kind register subset + Process.monitor offline 状态机)
- **#89** MessageStore = chat history single source of truth,Session.Chat state slice 不维护重复 pending queue;BEAM 重启历史保留,在线状态重置
- **#90** Phase 2 Agent Kind 动态 spawn 机制(bridge announce → spawn,disconnect → terminate,URI from `EZAGENT_AGENT_URI` env)

具体编号待 Phase 2 完成后跟 architect 对齐(可能跟其他 Phase 1 后 architect 自己加的 entries 撞)。
