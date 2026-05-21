# Phase 3 — PLAN

> 实施任务清单。`SPEC.md` 定义"做什么",`VERIFICATION.md` 是验收契约,本文件定义"按什么顺序做"。
> Phase 3 = 4 sub-step;每个 sub-step 内部切 step + 各步 commit;sub-step 末尾打 tag。
> 实施由 `/goal` 驱动(self-motivated skill)。

## 实施 conventions(沿用 Phase 1/2)

- 每个 PLAN step 一次 commit;commit message 形如 `phase3a step <N>: <subject>`
- 每个 sub-step 末尾打 tag(`phase3a` / `phase3b` / `phase3c` / `phase3d` = 整体)— VERIFICATION 全绿之后
- `sub-step-gate.sh` PreToolUse hook 在 commit/tag 时 fire,跑 `mix format --check + mix test + mix ezagent.check_invariants`
- 撞墙处理:any step 的 e2e gate 红 / 不变式违反 → `/goal` 自动暂停,Feishu 报错让 Allen 看
- 每 step 完成前自查:VERIFICATION.md 列的相关 grep + checkbox

---

## 3a 内部 PLAN step

### 3a-step 1 · RoutingRegistry + ETS owner 接入

**目标**:RoutingRegistry 模块完成 + EzagentCore.EtsOwner 加新表 + 单元测试全绿。

**文件**:
- `apps/ezagent_core/lib/esr/routing_registry.ex`:`declare_table(name, opts)` / `put_new/3` / `put/3` / `lookup/2` / `lookup_all/2` / `list_all/1` / `reverse_index/3`(可选 `opts: [reverse: true]` 时自动维护反向 ETS)。Plugin owner-only-write 通过 `owner_pid` 字段 + write 时 check caller pid
- `apps/ezagent_core/lib/esr/ets_owner.ex`:加 `Ezagent.RoutingRegistry.tables_ets` 表 owner

**单元测试**:
- `apps/ezagent_core/test/esr/routing_registry_test.exs`:declare → put → lookup 路径;put_new 同 key 撞 reject;owner-only-write deny non-owner
- reverse_index 双向 round-trip

**commit message**:`phase3a step 1: Ezagent.RoutingRegistry + ETS table family`

### 3a-step 2 · Routing.Matcher + JSON 序列化

**目标**:5 个 leaf matcher + match?/2 + to_json/from_json round-trip。

**文件**:
- `apps/ezagent_core/lib/esr/routing/matcher.ex`:5 个 leaf 构造函数 + `match?(matcher, %Message{}) :: boolean` + `to_json/1` + `from_json/1`

**单元测试**:
- `apps/ezagent_core/test/esr/routing/matcher_test.exs`:各 leaf match? 正负 case + JSON round-trip 不丢字段

**commit message**:`phase3a step 2: Ezagent.Routing.Matcher 5 leaf + JSON serde`

### 3a-step 3 · Routing.Resolver + RuleStore + 2 migrations

**目标**:Resolver(给 message 派生 cross-session recipients)+ RuleStore(SQLite 持久化 routing rules)+ message_routings 关联表(per #P1-4 fix:支持同一 message 落多个 session)。

**文件**:
- `apps/ezagent_core/lib/esr/routing/resolver.ex`:`resolve(message :: Message, current_session_uri :: URI) :: [recipient_uri]`(内部 hard-code query MentionRouting + SessionRouting 两表;各 rule match?/2 通过则 union receivers;**返 [] 给 caller 表示 fall-through 到 in-session default**)
- `apps/ezagent_core/lib/esr/routing/rule_store.ex`:Ecto.Schema for `routing_rules` table + `add(table_name, matcher, receivers, created_by)` / `list(table_name)` / `delete(id)`
- `apps/ezagent_core/priv/repo/migrations/20260517000000_phase3_routing_rules.exs`:CREATE TABLE routing_rules(6 columns,index on table_name)
- `apps/ezagent_core/priv/repo/migrations/20260517000100_phase3_message_routings.exs`:CREATE TABLE message_routings(message_uri TEXT, session_uri TEXT, inserted_at TIMESTAMP,**复合 PRIMARY KEY (message_uri, session_uri)**,index on session_uri)
- `apps/ezagent_core/lib/esr/message_store.ex` 改造:
  - `write(message, session_uri)`:upsert messages(`on_conflict: :nothing`)+ insert message_routings;失败仍 propagate 错误
  - `recent_in_session(session_uri, limit)`:`join message_routings → messages`(以前是直接 messages where session_uri = ?)
  - `in_session_since(session_uri, since)`:同上 join
  - `by_uri/1`:保持 — 直接查 messages PK lookup

**单元测试**:
- `apps/ezagent_core/test/esr/routing/resolver_test.exs`:Resolver additive(2 rules 都 match → union receivers)+ no match → []
- `apps/ezagent_core/test/esr/routing/rule_store_test.exs`:add → list round-trip + JSON serde of matcher_data
- `apps/ezagent_core/test/esr/message_store_test.exs` 加 case:同一 message URI 写入 2 个 session → messages 1 行 + message_routings 2 行;recent_in_session join 正确

**commit message**:`phase3a step 3: Ezagent.Routing.Resolver + RuleStore + message_routings (multi-session persist)`

**单元测试**:
- `apps/ezagent_core/test/esr/routing/resolver_test.exs`:Resolver additive 行为(2 rules 都 match → union receivers)+ no match → []
- `apps/ezagent_core/test/esr/routing/rule_store_test.exs`:add → list round-trip + JSON serde of matcher_data column

**commit message**:`phase3a step 3: Ezagent.Routing.Resolver + RuleStore + migration`

### 3a-step 4 · Plugin declare tables + 系统默认 rules

**目标**:EsrPluginChat 声明 2 张 routing table + boot 时 idempotent insert 默认 rules + 引入 mix ezagent.routing.add_rule task。

**文件**:
- `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex`:start/2 加 `Ezagent.RoutingRegistry.declare_table(SessionRouting, key_type: :string, value_type: :string)` + `declare_table(MentionRouting, ...)`
- `apps/esr_plugin_chat/lib/esr_plugin_chat/default_rules.ex` (新)~30 LOC:`bootstrap_default_rules/0` — idempotent check `routing_rules` 表里有没有 system-default,没有则 insert
- `apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex` (新)~50 LOC:`mix ezagent.routing.add_rule MentionRouting mention:agent://X receivers:session://Y` 解析 + 写入 RuleStore

**集成测试**:
- `apps/esr_plugin_chat/test/integration/routing_default_test.exs`:boot 后 routing_rules 表已含默认 rules + 第二次 boot 不重复 insert
- `mix ezagent.routing.add_rule` smoke test

**commit message**:`phase3a step 4: declare routing tables + default rules + mix ezagent.routing.add_rule`

**3a sub-step gate**:VERIFICATION 3a checklist;tag `phase3a`。Feishu 报 Allen "3a 完成,API design + Matcher set OK 吗?"。

---

## 3b 内部 PLAN step

### 3b-step 1 · Session create flow + admin auto-join(per #B4: main 保持 static)

**目标**:non-main session 动态创建 + admin User 自动 join。**`main` Session 保留 Phase 2 行为(static child)**。

**文件**:
- `apps/esr_plugin_chat/lib/esr_plugin_chat/session_supervisor.ex` (新)~20 LOC:DynamicSupervisor for non-main Session Kinds(类 AgentSupervisor)— 加入 Application static children list
- `apps/esr_plugin_chat/lib/esr_plugin_chat.ex` (新)~40 LOC:`create_session(short_name, creator_uri) :: {:ok, session_uri} | {:error, _}`(参数: short_name e.g. "review" → URI session://review;spawn via SessionSupervisor + RuleStore insert default rule + dispatch admin chat/join to new session)
- `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex`:`main` 仍 static child(不动);静态 children list 加入 SessionSupervisor

**单元测试**:
- `apps/esr_plugin_chat/test/integration/dynamic_session_test.exs`:create_session("foo", admin_uri) → session://foo registered + admin in members + 默认 routing rule 插入

**commit message**:`phase3b step 1: dynamic non-main session create (main stays static per #B4)`

### 3b-step 2 · Bridge attach floating(removed auto-join,per #P1-6 contract change 非 regression)

**目标**:Bridge announce 不再自动 join session;Agent Kind floating。**Phase 2 测试改造,不是 regression — 是 contract change。**

**文件**:
- `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex`:announce/2 删除 `join_agent_to_default_session/1` 调用;只 spawn Agent + bind to bridge_id 留下
- `apps/ezagent_web/test/ezagent_web/controllers/cc_bridge_announce_controller_phase2_test.exs`:**改造**(同 commit)— "announce-with-agent-spawns-and-joins" 测试改为 "announce-with-agent-spawns-floating"(断言 agent in KindRegistry 但**不**在任何 session.members);"reply-forwards-to-admin" 测试加 "after manual chat/join" 前置步骤

**commit message**:`phase3b step 2: bridge attach leaves agent floating (contract change, Phase 2 tests updated)`

### 3b-step 3 · LV sessions sidebar + current session switcher

**目标**:LV 重构成 sidebar + main area 双区,sessions 列表 + click 切换。

**文件**:
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:
  - mount/3 加 `@sessions :: [%{uri, name, unread}]` assign,初始读 KindRegistry session:// list
  - 加 `@current_session_uri` assign(默认 main)
  - 加 handle_event "switch_session" → update assign + re-load messages stream
  - render 重构:左侧 `<aside>` sessions list + 右侧 main area(用现 chat-window)
  - subscribe `esr:session:*:events`(所有 session events)→ unread badge update

**测试**:
- `apps/ezagent_web_liveview/test/admin_live_test.exs`:create 2 sessions + assert sidebar 显示 2 个;click 切换后右侧 stream 更新

**commit message**:`phase3b step 3: LV sessions sidebar + current session switcher`

### 3b-step 4 · LV floating agents 区 + add-to-session

**目标**:LV 显示 floating agents 列表 + 每个有 "Add to session..." dropdown。

**文件**:
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:
  - 加 `@floating_agents :: [URI]` — read KindRegistry agent:// minus all sessions.members 联合
  - render 加 "Connected agents (floating)" 区
  - handle_event "add_agent_to_session" {agent_uri, session_uri} → dispatch chat/join

**测试**:
- LV test:bridge announce(模拟)→ floating list 显示 agent;click add to session → members 出现 agent

**commit message**:`phase3b step 4: LV floating agents area + add-to-session UI`

### 3b-step 5 · LV multi-session badges + create session form

**目标**:agent 在 N sessions 时 LV cross-reference badge;LV "+ New session" 表单 dispatch create_session/2。

**文件**:
- LV admin_live.ex render 改:Members 行 agent URI 后,如果其他 sessions 也含 → 小 badge "(also in X)"
- LV 顶部 "+ New session" button → modal/inline form → submit handle_event "create_session" → call `EsrPluginChat.create_session/2`

**测试**:
- LV test:add agent to 2 sessions → 两边 Members 都显示 + badge 互链;"+ New session" 提交 → 新 session 出现在 sidebar

**commit message**:`phase3b step 5: LV cross-reference badges + create session form`

**3b sub-step gate**:VERIFICATION 3b checklist + agent-browser snapshot;tag `phase3b`。Feishu 报 Allen "3b UI 已完成,看截图 OK 吗?"。

---

## 3c 内部 PLAN step

### 3c-step 1 · Chat.invoke(:send) 改造走 Resolver(per #P1-3 + #P1-5)

**目标**:把 `mentions=members default` 行为换成 Resolver 调用;Resolver 返 [] 时 fall-through 到 in-session default。**`msg.mentions` 字段仍存在,作 `mention(URI)` matcher 的 data source**。

**文件**:
- `apps/esr_plugin_chat/lib/esr/behavior/chat.ex`:
  - `invoke(:send, slice, %{message: msg}, ctx)` 内部改:
    ```
    cross_session = Resolver.resolve(msg, ctx.self_uri)   # cross-session via rules
    in_session = if cross_session == [], do: Map.keys(slice.members), else: []
    recipients = (cross_session ++ in_session) -- [msg.sender]
    ```
  - **`msg.mentions` 不直接读**;`Resolver` 内的 `mention(URI)` matcher 读 message.mentions 判断是否触发
  - 修改 `derive_recipients/2` 为 `derive_recipients/3`(slice + msg + ctx)
  - 删除 Phase 2 的 mentions=[] → members / mentions=non-empty → mentions 逻辑(被 Resolver + fall-through 替代)

**测试**:
- `apps/esr_plugin_chat/test/esr/behavior/chat_test.exs` 加 case:
  - 无 routing rule → fall-through fan-out 给 members(原 Phase 2 行为保留)
  - admin 加 `MentionRouting: mention(agent://X) → [session://Y]` rule;admin compose 包含 mention X → X 收到(通过 Y session 推到 X)
  - 写一条 `always() → [session://Z]` rule → 任何 message 同时 Z 也收到

**commit message**:`phase3c step 1: Chat.invoke(:send) routes via Resolver + fall-through to members`

### 3c-step 2 · Python bridge MCP tool schema 升级

**目标**:Python `reply` tool 改 3 字段;bridge controller `reply/2` 改 4 参数。

**文件**:
- `apps/ezagent_plugin_cc_bridge_v1_prototype/python/esr_mcp_bridge_v1_prototype.py`:
  - `reply` MCP tool input_schema 改:`{"session_uris": ..., "text": ..., "ref": ...}`(required: session_uris + text)
  - `handle_reply_tool` parse 三字段
  - `post_reply` 改:URL body 加 `session_uris` + `ref`
- `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex`:`reply/2` 改 require `session_uris: [string]`;optional `ref: string`;调 `Server.forward_reply_to_agent/4`
- `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/server.ex`:`forward_reply_to_agent/4` 改 send `{:reply_received, session_uris, text, ref}` 而非 `{:reply_received, text}`

**测试**:
- 模拟 reply curl:`{"session_uris": ["session://main"], "text": "hi", "ref": "message://abc"}` → 200 OK
- 缺 session_uris → 422

**commit message**:`phase3c step 2: Python bridge reply MCP tool to 3-field schema`

### 3c-step 3 · Agent handle_kind_message 多 session reply + consistency soft warn(per #B3 ref type)

**目标**:Chat handle_kind_message 改造接 4 字段,dispatch chat/send per session_uri,ref 一致性检查。

**文件**:
- `apps/esr_plugin_chat/lib/esr/behavior/chat.ex`:
  - `handle_kind_message({:reply_received, session_uris, text, ref_str_or_nil}, _slice, ctx)` 新签名(**ref 在 wire 是 string;为了 schema 兼容,在这层 internal 保持 string 给 by_uri/1,parse 成 URI 给 Message.new**)
  - **同一个 message envelope**:`msg = Ezagent.Message.new(ctx.self_uri, %{text: text, attachments: []}, ref: URI.new!(ref_str_or_nil_to_uri))` — 构造一次,UUID 唯一,跨 N session dispatch 复用(identity invariant)
  - 对每个 session_uri:`Invocation.dispatch(target = <session>/behavior/chat/send, args = %{message: msg}, ...)` — Chat.invoke(:send) 在 Session 端会 MessageStore.write(msg, session_uri)。第一次 insert messages 表 + 1 行 message_routings;第二次 message_uri 已存在 → upsert noop + 又 1 行 message_routings
  - 若 ref 非 nil:`MessageStore.by_uri(ref_str)` → 比较 `loaded.session_uri` 与 session_uris;不全 match → emit `[:ezagent, :chat, :reply_session_mismatch]` telemetry + audit warn(仍按 session_uris 路由)

**测试**:
- 模拟 reply 单 session 包含 ref → message 落 messages 1 行 + message_routings 1 行
- 模拟 reply 多 session 复用同 ref → messages 仍 1 行 + message_routings N 行(per session)
- ref mismatch → telemetry emit assertion + audit warn 落地

**commit message**:`phase3c step 3: Agent multi-session reply + ref consistency soft warn (envelope reuse via identity invariant)`

### 3c-step 4 · LV reply mismatch warn 显示

**目标**:LV audit 流里 `reply_session_mismatch` 显红字 + 跨 session 链路可视化。

**文件**:
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:Audit 表加 `result` column color:red 当 event = `reply_session_mismatch`

**测试**:
- LV test:trigger mismatch → audit row 出现红字

**commit message**:`phase3c step 4: LV reply mismatch warning display`

**3c sub-step gate**:VERIFICATION 3c checklist;tag `phase3c`。Feishu 报 Allen "3c 完成,reply 契约 + routing fan-out 上线"。

---

## 3d 内部 PLAN step

### 3d-step 1 · Ezagent.Behavior.Identity + kind_server_spec extra args(per #B1)

**目标**:Identity Behavior 在 ezagent_core 内 + admin User boot 时把 admin_caps 装进 Identity slice。**关键依赖**:`kind_server_spec` 必须升级支持 extra args(Phase 2 只接 uri)。

**文件**:
- `apps/ezagent_core/lib/esr/behavior/identity.ex` (新)~80 LOC:`@behaviour Ezagent.Behavior` + actions [`:list_caps`, `:has_cap?`] + state_slice `:identity` + init_slice 接受 `args[:initial_caps]`(默认 `MapSet.new()`)
- `apps/ezagent_core/lib/esr/entity/user.ex`:behaviors 改 `[Ezagent.Behavior.Identity]`(从 `[]`);moduledoc 更新("Phase 3 起 admin_caps 通过 Identity slice 持有,不再函数硬编码 — admin_caps/0 函数仍保留供 boot 初始化用")
- `apps/esr_plugin_chat/lib/esr/entity/agent.ex`:behaviors 改 `[Ezagent.Behavior.Chat, Ezagent.Behavior.Identity]`(Agent 也持 cap,默认空 MapSet)
- `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex`:
  - `kind_server_spec/3` 升级为 `kind_server_spec/4`(加 `extra_args :: map()` 参数,合并进 `%{uri: uri}`)
  - admin User spawn 改 `kind_server_spec(:user_admin, User, admin_uri, %{initial_caps: User.admin_caps()})`
  - main Session spawn 不变(extra_args = %{})
- `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex`:
  - `start_agent_kind/1` 改造接受 extra args(可选 `initial_caps`,默认 `MapSet.new()`)— Phase 3 Agent 默认空 caps

**测试**:
- `apps/ezagent_core/test/esr/behavior/identity_test.exs`:Identity invoke `:list_caps` 返 slice.caps;`:has_cap?` 检查
- 集成:admin User spawn 后 `:sys.get_state` → `state.identity.caps == admin_caps`
- 集成:Agent Kind spawn 后 → `state.identity.caps == MapSet.new()`

**commit message**:`phase3d step 1: Ezagent.Behavior.Identity + admin_caps in slice via kind_server_spec extra_args`

### 3d-step 2 · Ezagent.Capability.cap_for_action/3 helper(per #P1-8)

**目标**:dispatch step 5.5 需要的"action → cap_needed" 反查函数。**签名加 target URI 参数,从中提取 instance**。

**文件**:
- `apps/ezagent_core/lib/esr/capability.ex`:加 `cap_for_action(kind_module, action, target_uri :: URI) :: %{kind: atom, behavior: module, instance: URI}`(从 BehaviorRegistry 查 behavior 模块;instance 由 `Ezagent.URI.instance(target_uri)` 提取)

**测试**:
- `apps/ezagent_core/test/esr/capability_test.exs`:`cap_for_action(Session, :send, URI.new!("session://main/behavior/chat/send"))` 返 `%{kind: :session, behavior: Ezagent.Behavior.Chat, instance: URI.new!("session://main")}`

**commit message**:`phase3d step 2: Ezagent.Capability.cap_for_action/3 helper (with target_uri for instance)`

### 3d-step 3 · dispatch step 5.5 hard flip + audit/telemetry/LV cleanup(per #B5 + #P1-8)

**目标**:同 commit 完成 dispatch 替换 + 所有 `stub_grant` 字符串/atom 改造。**这是 hard flip 关键 commit**。

**文件**:
- `apps/ezagent_core/lib/esr/kind/runtime.ex`:
  - `authz_stub/4` 函数删除
  - 替换为 `authz_check/5`(加 target 参数):
    ```
    needed = Capability.cap_for_action(kind_module, action, target)
    granted? = Enum.any?(ctx.caps, &Capability.matches?(&1, needed))
    granted → emit [:ezagent, :authz, :granted] + :ok
    !granted → emit [:ezagent, :authz, :denied] + {:error, :unauthorized}
    ```
  - 删除 `PHASE-3D-STUB: DO NOT REMOVE` 注释
- `apps/ezagent_core/lib/esr/audit.ex`:
  - row 构造时 authz column 从 `"stub_grant"` 改 `"granted"` / `"denied"`(基于 telemetry event 名)
  - 加 telemetry handler `[:ezagent, :authz, :denied]` 记录 + broadcast(同 stub_grant 模式)
  - **保留** `[:ezagent, :authz, :stub_grant]` handler 兼容(Phase 3d 后理论不该 emit)
- `apps/ezagent_core/lib/esr/telemetry.ex`:
  - `@events` list 加 `[:ezagent, :authz, :granted]` + `[:ezagent, :authz, :denied]`
  - **保留** `[:ezagent, :authz, :stub_grant]`(legacy,Phase 3d 后不该触发)
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:
  - `authz_label/1` 加:`[:ezagent, :authz, :granted] → "granted"` + `[:ezagent, :authz, :denied] → "denied"`
  - `result_label/2`:`:denied` row CSS red(同 `reply_session_mismatch` pattern)

**测试**:
- `apps/ezagent_core/test/esr/kind/runtime_test.exs` 加 case:
  - cap 充足 → dispatch 返 `{:ok, _}` + `:granted` telemetry emit
  - cap 不足 → dispatch 返 `{:error, :unauthorized}` + `:denied` telemetry emit
- `apps/ezagent_core/test/esr/audit_test.exs` 加:`:granted` event → audit row.authz == "granted"

**commit message**:`phase3d step 3: dispatch step 5.5 hard flip + audit/telemetry/LV granted/denied wiring`

### 3d-step 4 · 全测试 fixture 改造

**目标**:全部测试 fixture 改用 admin_caps 或精确 cap;Phase 1+2 全测试仍绿。

**文件**:
- `apps/ezagent_plugin_echo/test/integration/f1_direct_invoke_test.exs`:已使用 `Ezagent.Entity.User.admin_caps()`,不需改
- `apps/esr_plugin_chat/test/esr/behavior/chat_test.exs`:ctx fixtures 加 `caps: Ezagent.Entity.User.admin_caps()`
- `apps/esr_plugin_chat/test/integration/chat_routing_test.exs`:同上
- `apps/ezagent_web/test/ezagent_web/controllers/cc_bridge_announce_controller_phase2_test.exs`:同上(注 dispatch path)
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:`ctx/0` 函数已经使用 admin_caps,但加 helper 确保 dispatch path 一致
- 新 helper:`apps/ezagent_core/test/support/cap_helpers.ex` (新) — `granting_caps(needed_cap_shape)` 生成精确单一 cap

**测试**:全 umbrella mix test 全绿(预期 175+ 个测试不退化)

**commit message**:`phase3d step 4: test fixtures use admin_caps / granting helper`

### 3d-step 5 · check_invariants #9 + #10 + cap deny runtime test(per #B5 + #P1-7)

**目标**:加 2 个新 invariant + 1 个 runtime test 永久 enforce cap deny path 工作。

**文件**:
- `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex`:
  - `check_invariant_9/0`(grep `:stub_grant` 带 colon prefix in code,排除 docstring/comment)— allowlist: telemetry @events list 内的 `[:ezagent, :authz, :stub_grant]`(legacy 兼容保留)
  - `check_invariant_10/0`(grep `Capability.matches?` in `kind/runtime.ex`)— **tripwire only**,真正语义验证靠 runtime test
- moduledoc 更新
- `apps/ezagent_core/test/esr/kind/runtime_phase3d_test.exs` (新)— **runtime invariant test**:构造一个 ctx 带空 caps + 一个 Echo target → dispatch → 断言 `{:error, :unauthorized}` + audit row.authz == "denied"。**此测试 fail = #10 invariant 真正失效**(per memory `feedback_completion_requires_invariant_test`)

**测试**:
- 运行 `mix ezagent.check_invariants` exit 0
- 运行新 runtime test 绿
- 故意加 `:stub_grant` literal to a non-allowlisted file → invariant #9 fail(然后 revert)

**commit message**:`phase3d step 5: check_invariants #9 :stub_grant alarm + #10 + runtime cap deny test`

### 3d-step 6 · Phase 3 整体 e2e + screenshot

**目标**:scripts/cc-bridge-attach 真跑通 multi-session flow + agent-browser 截图。

**步骤**:
1. mix phx.server background(port 4002)
2. **USER ACTION REQUIRED**:Allen 终端跑 `bash scripts/cc-bridge-attach.sh`(.local.sh.example 已 EZAGENT_AGENT_URI 配)
3. 等待 LV 显示 cc-builder floating
4. agent-browser:add cc-builder to main + send chat + verify reply
5. agent-browser:+ New session "review" + add cc-builder to review + send chat in review + verify reply 只到 review
6. agent-browser:mix ezagent.routing.add_rule MentionRouting text_contains:urgent receivers:session://review + send "urgent" in main + verify main 和 review 都收到
7. agent-browser screenshot `/tmp/phase3-final.png` + archive
8. SQLite query verify: messages table + routing_rules table

**commit + tag**:`phase3d step 6: 3d integration e2e + screenshot + tag phase3d/phase3`

**3d/Phase 3 sub-step gate**:VERIFICATION 3d + 整体 checklist;tag `phase3d` + `phase3`(等价);push origin。

---

## /goal 触发(self-motivated skill)

spec 4 文件 + subagent code-reviewer review 通过后,主 agent(我)走 self-motivated skill 注入 `/goal`,开 4 sub-phase 自主实施。Allen 在 3 个 USER ACTION 节点回上线 review。

3 个 节点回来时执行该操作,主 agent 继续 e2e 后续步骤,直到 phase3 tag 出现 + push。

## 实施期可能撞到的决策点(/goal 撞到时按 DECISIONS.md §实施期 决策原则定)

详见 `DECISIONS.md` 末段"实施期可能撞到的决策点"5 项:Resolver 接口 / Matcher AST 序列化 / default rules 怎么"代表 session" / Identity slice 形态 / 测试 fixture 改造范围 / routing rule 删除审计。

撞墙处理:STOP + Feishu 报 + 等 Allen 回复(per `feedback_flag_user_assist_steps`)— 不 silently scope down。
