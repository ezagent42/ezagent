# Phase 2 — PLAN

> 实施任务清单。`SPEC.md` 定义"做什么",`VERIFICATION.md` 是验收契约,本文件定义"按什么顺序做"。
> Phase 2 = 3 sub-step;2a / 2b 内部各切几个 PLAN step + 各步 commit;2c 因含 e2e + chat UI 是单大 commit 块。
> 实施由 `/goal` 驱动(self-motivated skill)。

## 实施 conventions(沿用 Phase 1)

- 每个 PLAN step 一次 commit;commit message 形如 `phase2a step <N>: <subject>`
- 每个 sub-step 末尾打 tag(`phase2a` / `phase2b` / `phase2`= 整体)— VERIFICATION 全绿之后
- `sub-step-gate.sh` PreToolUse hook 在 commit/tag 时 fire,跑 `mix format --check + mix test + mix ezagent.check_invariants`
- 撞墙处理:any step 的 e2e gate 红 / 不变式违反 → `/goal` 自动暂停,Feishu 报错让 Allen 看
- 每 step 完成前自查:VERIFICATION.md 列的相关 grep + checkbox

## 2a 内部 PLAN step

### 2a-step 1 · Ezagent.Message 数据型 + Ecto custom URI type

**目标**:Message struct + Jason 序列化 + Ecto URI type,单元测试全绿。零 dispatch / Kind 依赖。

**文件**:
- `apps/ezagent_core/lib/esr/message.ex`:6 字段 defstruct + `new(sender, body, opts \\ [])` + `Jason.Encoder` impl for both `%Ezagent.Message{}` 和 `%URI{}`
- `apps/ezagent_core/lib/esr/ecto/uri_type.ex`:custom Ecto type,`load/dump/cast` 实现 URI struct ↔ string round-trip

**单元测试**:
- `apps/ezagent_core/test/esr/message_test.exs`:new/3 各 opt 组合 / URI auto-gen 唯一性 / Jason encode round-trip
- `apps/ezagent_core/test/esr/ecto/uri_type_test.exs`:URI struct ↔ string 双向转

**commit message**:`phase2a step 1: Ezagent.Message struct + Ecto custom URI type`

---

### 2a-step 2 · SQLite messages 表 migration + MessageStore Ecto Schema

**目标**:数据库表 ready,Message struct 兼任 Ecto Schema(实现 §3.5 + §10.4 的 dual-purpose 落地)。

**文件**:
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_phase2_messages.exs`:CREATE TABLE messages(7 列)+ 2 index(per §10.4)
- 升级 `apps/ezagent_core/lib/esr/message.ex`:加 `use Ecto.Schema` + schema 块(field types 跟 column types 对齐;URI 字段用 `Ezagent.Ecto.URI`;body / mentions 用 `:map`,ecto_sqlite3 自动 JSON-encode)

**集成测试**:
- 跑 `mix ecto.migrate`(等价于 reset DB)
- `apps/ezagent_core/test/esr/message_test.exs` 加 schema 测试:Repo.insert(%Ezagent.Message{...} as struct) + Repo.get round-trip

**commit message**:`phase2a step 2: SQLite messages migration + Ezagent.Message as Ecto.Schema`

---

### 2a-step 3 · Ezagent.MessageStore API + Ezagent.Behavior.Chat 接口契约

**目标**:MessageStore 4 函数完整;Chat Behavior 模块声明 actions/0 + interface/0(invoke 留 stub for 2b)。

**文件**:
- `apps/ezagent_core/lib/esr/message_store.ex`:`write/2`, `in_session_since/2`, `recent_in_session/2`, `by_uri/1` — 全 Ecto query DSL
- 新 plugin `apps/esr_plugin_chat/`:
  - `mix.exs`:depends on ezagent_core,esr_plugin_chat is umbrella app
  - `lib/esr_plugin_chat/application.ex`:Application.start/2(2a 只 declare,无 children)
  - `lib/esr/behavior/chat.ex`:@behaviour Ezagent.Behavior;actions/0 → `[:send, :receive, :join, :leave]`;interface/0 用 `%Ezagent.Message{}` schema(`:send` action args)+ stub send schema for `{:join, :leave}` (URI map);invoke/4 全 clauses 返回 `{:error, :not_implemented_in_2a}`

**单元测试**:
- `apps/ezagent_core/test/esr/message_store_test.exs`:write/in_session_since(asc order)/recent_in_session(desc limit)/by_uri,使用 sandbox checkout
- `apps/esr_plugin_chat/test/esr/behavior/chat_interface_test.exs`:`Ezagent.Behavior.Chat.actions/0` 返回 4 element + `interface/0` 形状(可被 InterfaceValidator 调用)

**commit message**:`phase2a step 3: Ezagent.MessageStore + Ezagent.Behavior.Chat interface contract`

**2a Sub-step gate**:跑 VERIFICATION 2a checklist(G1/G2/G3 + 单元覆盖);tag `phase2a`。

---

## 2b 内部 PLAN step

### 2b-step 1 · Session/Agent Kind 模块 + boot wiring

**目标**:两个新 Kind 模块定义 + Application boot 时 spawn Session/admin User Kind;Agent Kind via DynamicSupervisor 但尚未 spawn(bridge announce 后才 spawn,2c)。

**文件**:
- `apps/esr_plugin_chat/lib/esr/entity/session.ex`(~15 LOC):@behaviour Ezagent.Kind,type_name :session,behaviors `[Ezagent.Behavior.Chat]`,persistence :ephemeral
- `apps/esr_plugin_chat/lib/esr/entity/agent.ex`(~15 LOC):同 shape,type_name :agent
- `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex`:children 加 DynamicSupervisor for agent + spawn Session `session://main` + spawn User `user://admin`(admin Kind upgrade 在下个 step)

**Phase 1 `Ezagent.Entity.User` 升级(此 step 完成)**:删除 Phase 1 的 stub callbacks(behaviors `[]`),改为 `behaviors [Ezagent.Behavior.Chat]`;保留 admin_uri/0 + admin_caps/0 函数;type_name :user;persistence :ephemeral(Phase 2 同形)

**单元测试**:
- spawn Session Kind via `Ezagent.Kind.Server.start_link/1`,确认在 KindRegistry 里
- spawn admin User Kind 同上
- DynamicSupervisor for agent 启动后 children 数 = 0(等 bridge announce 才 spawn)

**commit message**:`phase2b step 1: Session/Agent/User Kinds + boot wiring (admin upgraded to real Kind)`

---

### 2b-step 2 · Chat Behavior 4 invoke clauses 完整实现 + BehaviorRegistry per-Kind register

**目标**:Chat Behavior `:send` / `:receive` / `:join` / `:leave` 写完整逻辑;per-Kind register subset 进 BehaviorRegistry。

**文件**:
- `apps/esr_plugin_chat/lib/esr/behavior/chat.ex` 大改:
  - `invoke(:send, slice, %Message{} = msg, ctx)`:写 MessageStore.write/2 + broadcast `esr:session:<uri>:events` + for each URI in msg.mentions 在 slice.online 内:`dispatch URI/behavior/chat/receive(msg)`
  - `invoke(:receive, slice, %Message{} = msg, ctx)`:从 `ctx.kind_module` 分支:Agent → push SSE(经 `Ezagent.Bridge.V1Prototype.Server` to_claude topic);User → `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:user:<self_uri>:events", {:message_received, msg})`(LV 订阅 — 注意 `:events` 后缀,跟 audit / session events 一致,不用 `:inbox` 避免 invariant #1 allowlist 复杂化)
  - `invoke(:join, slice, %{uri: u}, ctx)`:MapSet.put members + online,KindRegistry.lookup u 拿 pid,Process.monitor(pid) → 加 monitors map;若 last_seen[u] 存在:MessageStore.in_session_since(self_uri, last_seen[u]) → 每条 dispatch u/behavior/chat/receive;清 last_seen[u]
  - `invoke(:leave, slice, %{uri: u}, ctx)`:MapSet.delete members + online,demonitor,drop last_seen[u]
- `Ezagent.Kind.Server` 加 `handle_info({:DOWN, ref, :process, _pid, _reason}, state)`:delegate to `Ezagent.Behavior.Chat.handle_member_down(slice, ref)` 如果 kind 模块 declare 该 hook;否则 default ignore
- Application boot 加 BehaviorRegistry per-Kind register subset(Session 注册 send/join/leave,Agent/User 注册 receive)

**单元 + 集成测试**(`apps/esr_plugin_chat/test/`):
- Chat Behavior 4 actions invoke 各 clause 单元(模拟 slice + verify state 变化)
- 集成测试:spawn Session + 2 个 mock User Kind,dispatch session/behavior/chat/send,验 receive 路径 propagation 到 mock Kind + MessageStore 写入
- Process.monitor 集成:kill 一个 Kind GenServer,Session 状态自动更新

**Phase 1 functionality 回归测试**:Echo button / Manual Dispatch / Phase 1 audit log 不退化

**`mix ezagent.check_invariants` 升级**(2b-step 2 同 commit):invariant #1 grep 的 file allowlist 加 `apps/esr_plugin_chat/lib/esr/behavior/chat.ex`(`Chat.invoke(:send, ...)` 和 `:receive` 都用 `PubSub.broadcast` 走 `:events` topic — 跟 audit.ex / invocation.ex 同形)。`Ezagent.Kind.Runtime` 加 `kind_module` 到 ctx 也是同 step。

**commit message**:`phase2b step 2: Chat Behavior 4 actions + monitor/DOWN/last_seen state machine + Kind.Runtime kind_module ctx + check_invariants allowlist`

---

### 2b-step 3 · LV /admin Session 成员显示(轻量改动)

**目标**:LV /admin 加 Session 区域显示成员列表 + 在线状态。**主 chat UI 不在 2b 改**,2c 才大改。2b 只显示成员侧栏。

**文件**:
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex`:
  - mount/3 加 subscribe `esr:session:session://main:events` topic
  - 加 assign `:session_members` = `[{URI, online?, last_seen}]`(读 Session.Chat state via Server API,Phase 2 暂时 LV 直接 GenServer.call Session GenServer 拿 state — 真接 ETS-cached 形态 Phase 3 再考虑)
  - 加 handle_info 处理 join/leave/DOWN broadcast → 刷新 :session_members
  - render 加 "Session members" 段(table 行:URI / status / last_seen),保留 Phase 1 所有现有区域

**单元测试**:
- `Phoenix.LiveViewTest`:mount → assert HTML 有 admin online row
- bridge mock 来一个 :join → assert HTML 多 row
- mock 一个 :DOWN → assert HTML status 变 offline

**2b Sub-step gate**:VERIFICATION 2b checklist + tag `phase2b`。

**commit message**:`phase2b step 3: LV /admin Session members display`

---

## 2c 内部 PLAN step

2c 是 Phase 2 真"产出 demo" sub-step,涉及 controller + Agent + LV 三处 cross-cutting 改动 + e2e + chat UI 重建。4 个 internal step,每步 commit;最后一步打 tag。

### 2c-step 1 · Controller + Server forward_reply_to_agent 路径

**commit message**:`phase2c step 1: Controller forward_reply_to_agent + Server bridge_id→agent map`

**文件**:
- `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex`:
  - `announce/2`:除原本 register Server,**加** spawn `Ezagent.Entity.Agent` Kind via DynamicSupervisor.start_child(at agent_uri)
  - `reply/2`:**删除** Server.record_reply 路径;改为 `Ezagent.Bridge.V1Prototype.Server.forward_reply_to_agent(bridge_id, text)`
  - `disconnect/2`:除 unregister,**加** terminate Agent Kind
- `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/server.ex`:
  - state 加 `bridge_to_agent: %{bridge_id => agent_pid}`
  - register/2 时同时记录 agent_uri → agent_pid 映射
  - 新增 `forward_reply_to_agent(bridge_id, text)` API:lookup agent_pid → send `{:reply_received, text}`
- `apps/esr_plugin_chat/lib/esr/entity/agent.ex` 加 `handle_info({:reply_received, text}, state)`(via `Ezagent.Kind.Server` 的 forward-to-behavior 机制):构造 `%Ezagent.Message{sender: self_uri, body: %{text, attachments: []}}` → dispatch `session://main/behavior/chat/send`(via Ezagent.Invocation.dispatch)

### 2c-step 2 · LV chat-window UI 重建

**commit message**:`phase2c step 2: LV chat-window UI (compose / stream / members sidebar) + Phase 1 forms moved to Debug area`

**文件**:`apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex` 大改 render/1:

**新主视野**(从上到下):
- Session header(session://main + 成员侧栏内联)
- 主 message stream(`Phoenix.LiveView.stream(:messages, limit: 50)`,desc 时间序但 autoscroll 到底)
  - 每条 row:`[<sender short_name>] <timestamp · iso8601> · <body.text>`
  - admin sender:浅蓝背景;agent sender:浅绿背景
  - 同一 row component template,无独立 panel
- Compose 区:agent dropdown(从 KindRegistry 动态读 Agent Kind list)+ text input + Send button + on submit dispatch session://main/behavior/chat/send

**Debug 区(折叠或独立 section)**:
- Phase 1 的 Echo button / Manual Dispatch form / Audit Log table 移到这里,带 `<details>` 折叠

**删除**:
- Phase 1 的 `bridge_messages` assign + 整套 `:to_claude / :from_claude` 渲染逻辑 cleanup
- 老的 "Send to Claude (via channel)" 区(集成进 chat compose,不再独立)

mount/3 改动:
- 加载 `Ezagent.MessageStore.recent_in_session(URI.parse("session://main"), 50)` 进 stream
- subscribe `esr:session:session://main:events` 用于新消息插入

handle_event "chat_compose":parse form fields → 构造 Message → dispatch session/behavior/chat/send,清空 compose box

### 2c-step 3 · 自动化 e2e + screenshot

**目标**:agent-browser 跑 VERIFICATION 2c gate 的自动化部分。

**步骤**:
1. mix phx.server background
2. **USER ACTION REQUIRED — 第一次**:Allen 在第二个终端跑 `bash scripts/cc-bridge-attach.sh` interactive。**报 Feishu 让 Allen 来做这一步**;等待 LV 显示 agent connected。
3. agent-browser open /admin → snapshot 验 Session members 有 admin 和 cc-builder
4. agent-browser type compose input "你好" + select agent dropdown cc-builder + click Send → snapshot 验 chat stream 多 `[admin]: 你好` 行
5. 等 5-15s claude 推理 → snapshot 验 chat stream 又多 `[cc-builder]: <回复>` 行,两条 row component 相同
6. agent-browser screenshot `/tmp/phase2-final.png`
7. SQLite 验证 SELECT FROM messages

**offline/rejoin 验证(需 Allen 配合)**:
- Feishu 报 Allen:"请 Ctrl-C claude TUI 完成 offline 验证 step"
- 等待 → snapshot 验 cc-builder 显示 offline
- LV 表单发"还在吗?" → snapshot 验 message 已发但 cc-builder 仍 offline
- Feishu 报 Allen:"请重跑 attach script 完成 rejoin 验证"
- 等待 → snapshot 验 cc-builder online + claude TUI 收到 "还在吗?" + 给新回复

### 2c-step 4 · 提交 + tag phase2

- 全 gate 绿
- screenshot `/tmp/phase2-final.png` 拷贝进 `docs/phase-specs/phase2/artifacts/`
- commit + tag `phase2`(注意:phase2 = phase2c 完成 = Phase 2 整体完成)
- push origin phase-2 branch + tag

**commit message**:`phase2c step 4: 2c sub-step gate verified + screenshot archived (Phase 2 complete)`

---

## /goal 触发(self-motivated skill)

spec 4 文件全部 sign-off(本主 agent self-review + subagent review 通过)后,**主 agent**(就是我)走 self-motivated skill:

1. **Define done-condition**:`VERIFICATION.md` Phase 2 整体 Gate 段
2. **Compose + announce**:压缩 /goal 文本到 ≤ 3500 chars(memory `feedback_goal_text` 提示新 skill 文档),Feishu post 给 Allen 看(虽然他 AFK 不会立即 ack,但留 log)
3. **send-slash submit**:注入当前 pane;`/goal` 文本必 include "user action required" 段(Phase 2 在 2c 必须等 Allen 介入 attach script 启动 + Ctrl-C/rejoin 模拟)

/goal 实施期 Phase 2 期间,主 agent 在 2c step 3 遇到需要 Allen 介入的 e2e step 时,Feishu **明确停下来报告**:

> "Phase 2 2c-step 3:e2e 进行中。需要你 Allen 操作 — 启动 attach script(终端跑 `bash scripts/cc-bridge-attach.sh`)。我会在浏览器等 cc-builder connected,然后继续 e2e。"

不 silently scope down(memory `feedback_flag_user_assist_steps` 落地)。Allen 回来时执行该操作,主 agent 继续 e2e 后续步骤,直到 phase2 tag 出现 + push。

## 实施期可能撞到的决策点(/goal 撞到时按原则定)

### Ezagent.Behavior.Chat handle_member_down hook 接入机制

`Ezagent.Kind.Server.handle_info({:DOWN, ...})` 怎么把 message 转给 Behavior?Phase 1 Kind.Server 没暴露 Behavior-level handle_info hook。两个原则:
- (a) Kind.Server 内 default for `{:DOWN, ...}`:scan slice 找 Behavior 模块,调 `behavior.handle_member_down(slice, ref)` if exported,update state
- (b) Behavior 显式 register `:trap_info` capability(优雅但 over-engineer)

**原则**:(a)。Phase 2 是第一个真用 Behavior-side handle_info 的 case;Phase 1 没需求所以没建。Kind.Server 加 ~10 LOC 检测 Behavior 是否 export `handle_member_down/2` 并 forward。

### MessageStore 写入失败怎么办

write/2 在 SQLite 写失败(磁盘满 / DB lock)时,Chat.invoke(:send) 应该:
- (a) 返回 `{:error, reason}`,caller(LV)看到错误
- (b) 继续 broadcast + dispatch,但记 DLQ
- (c) 重试 N 次,再失败 → DLQ

**原则**:(a)。Message 是 first-class business data,write 失败 = send 失败,caller 必须知道。LV 显示错误状态。

### Phase 1 LV 的 "Send to Claude (via channel)" form 跟 2c 主 compose 区是否合并

- (a) 合并:Phase 1 form 删掉,主 compose 接管(自然语言:Allen 用主 compose 给 cc-builder 发 = "send to claude")
- (b) 保留 Phase 1 form 在 Debug 区:两套 UI 共存,用户可以选

**原则**:(a)。合并 — 主 compose 是 Phase 2 唯一 sending UX,清理 Phase 1 兼容垃圾。Phase 1 form 删除,功能完全由主 compose 接管(原 form 的 "select bridge" 现在是主 compose 的 "select agent" dropdown — 同一种操作)。

### 多 Agent Kind 同 announce 时的去重

Phase 2 boundary 是"单 claude"但代码上不强制。如果 Allen 错误地启动了两个 attach script:
- (a) Ezagent 接受两个 Agent Kind spawn(同 agent_uri → put_new conflict crash 第二个;不同 agent_uri → 都活)
- (b) Ezagent reject 第二个 announce HTTP

**原则**:put_new 自然让相同 URI 的 announce crash 第二个 spawn(invariant #4)。不同 URI 的两个 Agent Kind 都允许 — 这就是 multi-agent 起点 — 但 Phase 2 LV chat UI 只 demo 单 agent 场景。Phase 5 加 production-grade 限制。

## /goal 文本预览(待最终 brainstorm/subagent 起草后定稿)

```
/goal Work in /Users/h2oslabs/Workspace/ezagent/.claude/worktrees/phase-2/ — cd there + verify git branch is phase-2.

Implement ezagent Phase 2 sub-steps 2a → 2b → 2c. Tags phase2a, phase2b, phase2 pushed.

DONE when:
1. git tag shows phase2a / phase2b / phase2 all pushed to origin
2. Every checkbox in docs/phase-specs/phase2/VERIFICATION.md ticked with evidence
3. sub-step-gate.sh green at all 3 tag commits (mix format / mix test / mix ezagent.check_invariants)
4. /tmp/phase2-final.png screenshot exists, archived to docs/phase-specs/phase2/artifacts/
5. Allen-side interactive verification (USER ACTION REQUIRED): Allen runs `bash scripts/cc-bridge-attach.sh` + tests offline/rejoin flow

PRIMARY REFS:
- docs/phase-specs/phase2/{SPEC, VERIFICATION, PLAN, DECISIONS}.md
- ARCHITECTURE.md §3.5 (Message) §6.3 (Chat Behavior) §10.4 (messages table) §12.8 (Channel rewrite post-Phase 1b)
- GLOSSARY.md Decision Log

APPROACH: TDD per PLAN.md. 2a 3 steps with commits; 2b 3 steps with commits; 2c 4 steps with commits + tag phase2 at end.

USER ACTION REQUIRED (cannot self-automate):
- Allen will run `bash scripts/cc-bridge-attach.sh` in a separate terminal for 2c-step 3 e2e verification.
- Brief Feishu BEFORE blocking on user action; do not silently scope down.

ARCHITECTURAL INVARIANTS (grep before each tag):
- ZERO hardcoded URI in code (P-4: EZAGENT_AGENT_URI env-driven)
- Process.monitor on join + last_seen on :DOWN (P-2 state machine)
- Phase 1 functionality NOT regressed (Echo / Manual Dispatch / Audit Log moved to Debug area not deleted)
- LV chat row component IDENTICAL for admin and agent senders (Phase 2 visual invariant)
- mix ezagent.check_invariants 6/6 still clean

If gate red: STOP, no push, no tag. Feishu report failure mode + which gate + exact failure.

Memory rules to apply: feedback_flag_user_assist_steps / feedback_completion_requires_invariant_test / feedback_let_it_crash_no_workarounds.
```

(待 self-review + subagent review 后定稿。)
