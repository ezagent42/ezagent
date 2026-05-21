# Phase 3 — SPEC

> Phase 3 brainstorm 产出 + 10 个核心决策(P3-D1..D10)+ 4 sub-step 切分。
> 配套:`VERIFICATION.md` / `PLAN.md` / `DECISIONS.md`
> 上游:Phase 2 完成(tag `phase2` @ `6330666`,merged to main `571c3ef`)+ Phase 2 emergent 9 项进 ARCHITECTURE/GLOSSARY Decision Log #88-#94

## 目标

把 ezagent_core 从"**单 session router + 永远 grant 的 stub CapBAC**"升级到"**多 session router + 真 cap check 的 production-grade 路由层**"。具体三件事一起完成:

1. **Routing 真实化** — `Ezagent.RoutingRegistry` 落地作 plugin-declared 表家族,`Ezagent.Routing.Matcher` 5 个 matcher 类型;chat fan-out 不再"mentions=members 默认",改走 routing rules
2. **多 session** — 一个 BEAM 同时活 N 个 Session Kind 实例;一个 agent 可同时属于多个 session;bridge attach 不再自动 join,改 admin 显式拉入
3. **CapBAC 真化(Phase 3d sub-phase 内)** — Identity Behavior 挂到 admin User;dispatch step 5.5 的 `:stub_grant` 替换为真 `Capability.matches?/2`;`:stub_grant` telemetry 反向作 alarm(还出现 = 测试 fixture 漏改)

Phase 2 → Phase 3 关键不变量变化:
- **Chat fan-out 入口换**:`Chat.invoke(:send)` 不再硬计算 recipients(原:mentions=[] 时 members,否则 mentions),改 `RoutingRegistry.route(message, in_session) → [recipient_uri]`。**这是 router 真正落地**
- **Agent 生命周期解耦自 session**:bridge attach → Agent Kind 在 KindRegistry,**floating**(不在任何 session);admin "Add to session" 是单独操作。data 模型 Phase 2 已允许 N-session,Phase 3 暴露 UX
- **Claude reply tool 契约升级**:从 `reply(text)` 改为 `reply(session_uris: [URI], text: str, ref: URI?)`。session_uris 是 list(支持同时回 N 个);ref 可选(支持主动开口);ref 提供时跟 session_uris 一致性 soft warning
- **CapBAC 从可观察 stub 变成 production gate**:Phase 3d 之后 `:granted`/`:denied` 取代 `:stub_grant`;denied 路径真正阻断 dispatch

## 测试员体验 / demo

完成 Phase 3 后 Allen 能做到:

1. 启动 `mix phx.server`(esrd)
2. 浏览器开 `http://100.64.0.27:4000/admin`
3. **左侧 sessions 侧栏**:显示 `session://main`(默认有)+ "+ New session" 按钮
4. 创建 `session://architect-review`:点 "+ New",输入 short-name,session 出现在侧栏
5. 终端跑 `bash scripts/cc-bridge-attach.sh`(`EZAGENT_AGENT_URI=agent://cc-builder`)。LV 顶部"Connected agents (floating)"出现 `agent://cc-builder`,**不在任何 session**
6. Admin 在 floating list 点 cc-builder 的 "Add to session..." → 选 `session://main`。cc-builder 进 main 的 members
7. Admin 在 main compose 发"`@cc-builder` 帮我设计 X"
8. claude TUI 收到消息,回复时**填**:`reply(session_uris=["session://main"], text="...", ref="message://abc")`
9. LV main 看到 cc-builder 的回复
10. Admin 创建 `session://oncall`,把 cc-builder "Add to session" 到 oncall(现在 cc-builder **同时在 main 和 oncall**)
11. Admin 在 oncall 发"`@cc-builder` URGENT" → claude 收到,这次回复填 `session_uris=["session://oncall"]`
12. **场景测**:admin 在 main 写一条"text:urgent" routing rule 配置 → "matcher: text_contains('urgent') → 同时落到 oncall session" → 之后任何 main 里 urgent 消息**自动**也进 oncall;LV oncall session 看到镜像
13. **Cap 测**(Phase 3d 后):admin 尝试 dispatch 一个**他没有 cap 的 action**(LV Debug 区构造一个)→ audit log 显示 `denied` + reason

## 范围(Phase 3 做什么)

### 数据 / 持久化

- 新 ETS table:`Ezagent.RoutingRegistry` 表家族(plugin-declared,owner-only-write)
- 新 SQLite migration:`routing_rules` 表(persisted routing rules — admin 创建的规则重启后还在)
  - 列:`id, table_name, matcher_data (JSON encoded matcher AST), receivers (array of URI strings), created_by (URI), created_at`
- 新 SQLite migration:`message_routings` 表(同一 Message 落到多个 Session 的关联表)
  - 列:`message_uri (string FK), session_uri (string), inserted_at (utc_datetime_usec)`,**复合主键 `(message_uri, session_uri)`**
  - **理由**:Phase 2 `messages.uri` 是 primary key(Decision #40 identity invariant —— 同一个 Message 跨任意中转其 uri 不变)。Phase 3 D8 reply 可同时 target N 个 session,如果直接 `MessageStore.write` 写 N 行 messages 表 → PK 冲突。新加 message_routings 解耦:`messages` 永远 1 行 / message URI(identity invariant 不破),`message_routings` 给"在哪些 session 出现过" N 行
  - `MessageStore.write/2` 改造:upsert messages(若 message_uri 已存在则 noop)+ insert message_routings
  - `MessageStore.recent_in_session/2` 改造:join 两表查 session-scoped 消息
- **不**做 snapshot 真化(Workspace 留 Phase 4 — 见 P3-D2)
- **不**做 MessageStore 分页(Phase 4 LV 历史滚动一起做)

### 模块新增 / 改造

**ezagent_core 新增**:
- `Ezagent.RoutingRegistry`(~120 LOC,cap 150)— ETS-backed table family,`declare_table/3` + `put_new/put/lookup/lookup_all/list_all/reverse_index/2`
- `Ezagent.Routing.Matcher`(~80 LOC,cap 100)— 5 matcher type 构造函数 + `match?/2`
- `Ezagent.Routing.Resolver`(~40 LOC,cap 60)— 给 message + routing table → derive recipients
- `Ezagent.Routing.RuleStore`(~50 LOC,cap 70)— routing_rules table 的 Ecto.Schema + write/list API
- `Ezagent.Behavior.Identity`(~80 LOC,cap 100,ezagent_core 内 — Identity 是 core 概念)— Phase 3d 加,挂在 User/Agent 实例上,持 `caps: MapSet` slice + invoke `:list_caps`/`:has_cap`

**ezagent_core 修改**:
- `Ezagent.Kind.Runtime.handle_dispatch/4` 的 step 5.5(authz):Phase 3d 把 `:stub_grant` 替换为真 `Capability.matches?` 调用 + emit `:granted`/`:denied`
- `Ezagent.Capability` 模块:Phase 3d 加 `cap_for_action/2` 给 dispatch step 5.5 用
- `Ezagent.Entity.User` 模块:Phase 3d 加 `Ezagent.Behavior.Identity` 到 behaviors 列表

**esr_plugin_chat 修改**:
- `Ezagent.Behavior.Chat.invoke(:send, ...)` 大改:不再 `mentions=members default`。改两步:
  1. `Ezagent.Routing.Resolver.resolve(message, ctx.self_uri)` 派生 **cross-session recipients**(rules 决定路由到哪些其他 session)
  2. 若 resolver 返 [] 则 fall-through 到 **in-session fan-out**:`Map.keys(slice.members) -- [msg.sender]`(Phase 2 行为)
  3. **`msg.mentions` 字段仍是 `mention(URI)` matcher 的 input**(不是 Chat 直接消费;由 Resolver 通过 Matcher 读)
- `Ezagent.Behavior.Chat.handle_kind_message({:reply_received, ...}, ...)` 改 Pattern:接受 `{session_uris: [URI], text: str, ref: URI? (string at wire, URI struct internal)}` 而不是 `text`;**对每个 session_uri 各 dispatch 一次 chat/send,Message envelope 复用相同 uri(identity invariant)**;ref ↔ session_uri 一致性 soft warn
- `EsrPluginChat.Application.start/2` 加 `Ezagent.RoutingRegistry.declare_table(SessionRouting, key: bridge_id, value: session_uri)` + `Ezagent.RoutingRegistry.declare_table(MentionRouting, key: matcher, value: [session_uri])`
- `main` Session 仍 **static child**(per impl-time 决策 #B4);**non-main** session 通过 `EsrPluginChat.create_session/2` 动态 spawn via `EsrPluginChat.SessionSupervisor` DynamicSupervisor(boot 时 declare 但 0 children)
- 默认 routing rules 写入(系统启动时):`always() → [self.session_uri]`(每个 session 自己的所有消息 fan-out 给自己 members,即"在这 session 收到的消息发给这 session 成员")

**ezagent_plugin_cc_bridge_v1_prototype 修改**:
- Python bridge `reply` MCP tool schema 改:`{session_uris: [string], text: string, ref?: string}`
- 内部 forward_reply_to_agent 路径:从 `(bridge_id, text)` 改 `(bridge_id, session_uris, text, ref)`
- announce 不再自动 dispatch chat/join — Agent 进 floating 状态
- 新 controller endpoint:`POST /api/cc-bridge/agent/:agent_uri/add-to-session/:session_uri`(或经 LV → dispatch session/behavior/chat/join,更对称)
- 推荐后者(LV → dispatch)— 跟 admin User 同流

**ezagent_web_liveview 修改**:
- Sessions 侧栏(`@sessions :: [%{uri, name, unread_count}]`)
- Floating agents 区(`@floating_agents :: [URI]`)
- 当前 session 切换 LiveView mount param(URL `/admin/sessions/:session_uri` 或 LiveView assign)
- "+ New session" 表单 + dispatch
- 每个 floating agent 的 "Add to session..." 下拉
- Routing rules 显示(只读 Phase 3,Phase 4 CLI 写;Phase 3 admin 通过 LV 表单或 mix task 写)

### check_invariants 升级

- Invariant #5 (snapshot on slice change) — **Phase 3 不开**,留 Phase 4 Workspace 时同时 enable
- Invariant #8 (CC channel via stdio) — **Phase 3 不开**,留 Phase 5
- Phase 3d 加新 invariant #9:`grep -E ':stub_grant' apps/ezagent_core/lib --include='*.ex'` 命中 = bug(Phase 3d 后 `:stub_grant` atom 不能在代码出现;**必须**先把 audit.ex 的 `authz: "stub_grant"` 字符串列改为 `"granted"` / `"denied"`、admin_live.ex 的 `authz_label` 也改、把 telemetry @events list 里的 `:stub_grant` 去掉,再加这个 invariant)
- Phase 3d 加新 invariant #10:**runtime test 而非 grep** — 写一个测试:构造 deny 场景的 ctx → dispatch → 断言返 `{:error, :unauthorized}`。grep `Capability.matches?` 在 `kind/runtime.ex` 作辅助 tripwire(只验存在性,不验语义)

### LOC 估算

Phase 2 累积 ezagent_core ~2500 LOC。Phase 3 增量:
- RoutingRegistry + Matcher + Resolver + RuleStore = ~290 LOC
- Identity Behavior = ~80 LOC
- Capability.cap_for_action + dispatch 改造 = ~40 LOC
- 测试 ~600 LOC

esr_plugin_chat 增量:
- Chat.invoke(:send) 改造 ~50 LOC
- handle_kind_message 多 session reply ~50 LOC
- Application 加 declare_table + 默认 rules ~30 LOC

ezagent_web_liveview 增量:
- Sessions sidebar + state ~150 LOC
- Floating agents + add-to-session UI ~80 LOC
- Session create form ~50 LOC

总增量 ~1400 LOC(Phase 2 增量约 1500,体量接近)。

## 不范围(明确写下来)

- ❌ **Workspace / Template Class / Template Instance**(P3-D2)— 留 Phase 4 跟 CLI 一起做
- ❌ **Snapshot 真实化** — Phase 4 跟 Workspace 绑(没 Workspace 就没刚需)
- ❌ **MessageStore 分页 / history scroll** — Phase 4 LV 升级时做
- ❌ **Application-layer heartbeat for partition** — Phase 4+(Phase 2 P2-D3 noted)
- ❌ **Matcher 组合子(and/or/not)** — Phase 4+(P3-D3 推荐"5 个 leaf matcher 够 Phase 3 demo")
- ❌ **Routing rule editor UI** — Phase 3 只 read-only 显示;写入靠 mix task `mix ezagent.routing.add_rule` 或直接构造 dispatch invocation。完整 UI 表单 Phase 4 跟 CLI 一起
- ❌ **多用户 / non-admin login** — Phase 4+(Identity Behavior 把路径铺好,Phase 3 LV 仍 admin-only)
- ❌ **ETS-cached Session state**(LV 现在仍 `:sys.get_state` 直接查 Session GenServer)— Phase 4 优化
- ❌ **跨 BEAM federation** — 永远不在 v0

## Phase 3 sub-step 切分

- **3a**:RoutingRegistry core 模块 + Routing.Matcher 5 个 leaf + Routing.Resolver(全 unit 测试,没改 Chat)+ 第 1 张 demo table(SessionRouting,bridge_id → session_uri 映射,Phase 3a 内只展示不真用)
- **3b**:Multi-session UX + LV sessions sidebar + floating agents 区 + agent N-session 订阅(数据层已 OK,LV 重渲染逻辑)+ 新 session 创建 dispatch path
- **3c**:Chat.invoke(:send) 改造走 Resolver + 默认 routing rules 写入 + Python bridge MCP tool schema 升级到 D8 三字段契约 + handle_kind_message 多 session reply + soft warn 一致性检查
- **3d**:Identity Behavior + dispatch step 5.5 真 authz + admin_caps 注入 Identity slice + 全测试 fixture 重写 + check_invariants #9 #10 + telemetry 反向 alarm

Tag 顺序:`phase3a` / `phase3b` / `phase3c` / `phase3d` / `phase3`(整体 tag 在 3d 完成后打,等价 phase3d 但语义清晰)。

## 上线后下一步(Phase 4 预告)

Phase 3 完成 = production-grade router + cap。Phase 4 的 framing:

- **Optimus CLI 自动派生 + Workspace + Template Instance 真实化** — Phase 4 的"使产品可被运维"phase
- 把 Phase 3 漂亮的 router 接上 LV 之外的第 2 个驾驶面(CLI)
- Workspace 是 Template Instance 的代表用例,跟 CLI 一起做 UX 才完整(没 CLI 操作 Workspace 是怪 demo)
- Snapshot 真实化 = Workspace 持久化需要

## Decision boundaries 速查

10 个 decision 详见 `DECISIONS.md` P3-D1..D10。一句话清单:

| # | 决策 | 一句话 |
|---|---|---|
| P3-D1 | Phase 3 含 Identity flip | 是,4 sub-phases |
| P3-D2 | Workspace 留 Phase 4 | Phase 3 不做 |
| P3-D3 | Matcher 5 leaf 不含组合子 | mention/from/text_contains/text_matches/always |
| P3-D4 | Agent N-session 订阅 | 数据已支持,Phase 3 暴露 UX |
| P3-D5 | LV sessions sidebar 形态 | 左侧 list + 右侧 chat |
| P3-D6 | CapBAC hard flip | 单 commit 替换 + stub_grant 反向 alarm |
| P3-D7 | sub-phase 切 3a/3b/3c/3d | 上面已详 |
| P3-D8 | Reply 契约最灵活 | session_uris: list + ref: optional + 一致性 soft warn |
| P3-D9 | Bridge attach floating 默认 | 不自动 join,admin 手动拉 |
| P3-D10 | Routing rules persist 进 SQLite | admin 创建的规则重启后还在;系统默认 rules 在 plugin Application 写入 |
