# Phase 3 — DECISIONS

> Phase 3 brainstorm 阶段已决判断点 + 实施期可能撞到的决策点 + 决策原则。
> 已决项实施完后 append 进 `GLOSSARY.md` Decision Log(架构师本侧 patch,工程师建议编号 #95+,接 Phase 2 emergent #88-#94)。

## 已决(Phase 3 brainstorm 10 主题,Allen sign-off 2026-05-16)

### P3-D1 — Phase 3 含 Identity flip(router 完成 + CapBAC 真化一并落地)

**决策**:Phase 3 不分两期。Identity Behavior + 真 CapBAC 在 Phase 3d sub-phase 内一并完成。

**理由**:
- Identity 跟 multi-session 真实 coupling — multi-session 下 admin User join 哪些 session 由 cap 决定;不一起做的话 Phase 3d 又要回头改 multi-session 路径
- stub_grant 多活一个 phase 的代价(每多一周测试者看到的都是假 grant)大于 Phase 3 内增 1 sub-phase 的复杂度
- 4 sub-phases 数量是 Phase 1 (3) 和 Phase 2 (3) 自然的下一档,risk 可控

**Rejected alternative**:Phase 3 只做 router(multi-session + routing),Phase 4 单独做 Identity。代价是 Phase 3 -> Phase 4 之间会出现"router 已多 session 但 cap 仍 stub"的诡异中间态。

### P3-D2 — Workspace 留 Phase 4(跟 CLI 一起做)

**决策**:Phase 3 不做 Workspace / Template Instance / 真 snapshot。全部推 Phase 4。

**理由**:
- Workspace 真正 UX 是 CLI 操作(`esr workspace create ...` / `esr workspace switch ...`)— 没 CLI 落地的 LV-only Workspace 是怪 demo
- snapshot 真实化跟 Workspace 绑(没 Workspace 也不强需要,Session 仍 :ephemeral 就够)
- Phase 3 已经 4 sub-phase 容量饱和,加 Workspace 会破 LOC 预算 + 拖累 routing 部分的清晰度

**Rejected alternative**:Phase 3 含 Workspace,证明 Template Instance 模型。代价是 LV 操作 Workspace 体验差 + Phase 3 范围爆炸。

### P3-D3 — Matcher 5 leaf,不含组合子

**决策**:Phase 3 实现 5 个 leaf matcher,不实现 and/or/not 组合子。

5 个 matcher:
- `mention(URI)` — `message.mentions` 含此 URI
- `from(URI)` — `message.sender == URI`
- `text_contains(str)` — `message.body.text` 含子串
- `text_matches(regex)` — `message.body.text` 匹配正则
- `always()` — 永远 true(默认 catchall rule 用)

**理由**:
- 5 个 leaf 覆盖 Phase 3 demo 场景 90%(@oncall 路由、urgent 关键字、from broker agent → 转发等)
- 组合子(`and(mention(X), text_contains(Y))`)在 Phase 3 demo 场景里需要的概率 < 10%
- 加组合子 = 加 Matcher AST 求值器复杂度,Phase 4 跟 DSL 一起做更合理(DSL 编译期产 AST,Phase 3 不需要)
- 单条规则不够时,**多写几条 always() pattern 的规则**完全可以替代组合子(routing rules 是 additive — Decision #41)

**Rejected alternatives**:
- (a) 只 3 个 leaf:不够 demo(text 匹配是真实需求)
- (c) 全 DSL + 组合子:Phase 3 过重

### P3-D4 — Agent 可同时属于 N 个 session(数据层 Phase 2 已支持,Phase 3 暴露 UX)

**决策**:Phase 3 把 agent "在多个 session" 作为正常状态。LV "Add to session..."(不是 Move),Members 栏 cross-reference 显示 agent 也在哪些 session。

**理由**:
- Phase 2 的 `Session.chat.members: %{URI => %{online}}` 数据模型本来就允许 N 个 Session 都把同一个 agent URI 加进 members
- 我之前 UX 描述用了"Move to" 是隐性 assumption,跟数据层不一致
- Multi-session-per-agent 是 Slack 等 chat 系统的自然形态;限制 1-session-per-agent 是人为加的没必要约束

**真实限制是 reply path 的 target session 怎么定** — 由 P3-D8 解决。

### P3-D5 — LV sessions sidebar 形态(左侧 list + 右侧 chat)

**决策**:LV /admin 改造为 Slack-style:左侧 sessions list + 右侧当前 session chat-window。

每个 session entry 显示:URI / name / online member count / unread badge(unread = LV mount 之后未浏览的消息计数)。

**理由**:
- (a) sessions list 侧栏跟 (b) 每个 session 独立 URL 比 — (a) 单页面切换体验好,不需要浏览器 tab 管理
- Phase 4 加 CLI 后,LV 仍需要,sidebar 是稳定形态
- 不大改 LV 框架 — 仍是单 LiveView mount,LiveView assign 切 current_session_uri 时重建 stream + members

**Phase 3 LV 不做**:thread / replies-as-thread / 富文本 / drag-drop / 文件上传(全 Phase 5)。

### P3-D6 — CapBAC hard flip(单 commit 替换 + telemetry 反向 alarm)

**决策**:Phase 3d 内**单 commit**完成:
1. dispatch step 5.5 的 `authz_stub` 删除,替换为 `Ezagent.Capability.matches?(ctx.caps, needed_cap)` 真调用
2. 所有测试 fixture 改造(ctx 必带匹配 admin_caps 或被 deny)
3. `:stub_grant` telemetry 反过来:emit 它 = bug,加 invariant check
4. emit `:granted`/`:denied` 取代

**理由**:
- 跟 memory `feedback_let_it_crash_no_workarounds` 同精神 — feature flag / parallel paths 都是后悔药
- hard flip 反而最易调试:hot reload 后所有 dispatch 一致行为,要么 grant 要么 deny,不混合
- "telemetry 反向 alarm" 是 Decision #82 ("`:stub_grant` 防 simplification") 的逻辑闭环 — Phase 1-2 用它防 stub 简化,Phase 3d 用它防 stub 复活

**Rejected alternatives**:
- (b) feature flag 渐进:`Application.get_env(:ezagent_core, :authz, :stub)` 切 `:real` — 双形态共存,测试覆盖矩阵爆炸
- (c) parallel paths:dispatch 同时跑两路径对比 — N 周后删 stub 永远拖

### P3-D7 — sub-step 切 3a/3b/3c/3d

**决策**:Phase 3 内 4 sub-step,按 routing 数据层 → multi-session UX → fan-out 改造 + reply 契约 → CapBAC flip 的依赖顺序:

| Sub-step | 焦点 | 主要 deliverable | LOC est | commits est |
|---|---|---|---|---|
| 3a | Routing 数据层 | RoutingRegistry + Matcher + Resolver + RuleStore + SessionRouting demo table | ~290 | 4 |
| 3b | Multi-session UX | Sessions sidebar + floating agents + N-session add + new session create | ~280 | 5 |
| 3c | Chat + reply 改造 | Chat.invoke(:send) 走 Resolver + reply 三字段契约 + Python bridge MCP schema | ~180 | 4 |
| 3d | CapBAC 真化 | Identity Behavior + dispatch step 5.5 真 check + fixture 全改 + stub_grant alarm | ~250 | 6 |

**预计 commits 总数 ~19**(Phase 2 9 个,Phase 3 接近 2x 体量合理)。

**依赖顺序**:
- 3b 依赖 3a(Session create / move agent 经 dispatch + 可选用 RoutingRegistry 存 session metadata)
- 3c 依赖 3b(reply 多 session 需要先有多 session)
- 3d 依赖 3a-3c(Identity 在 routing 完成后 flip)

### P3-D8 — Reply 契约(最灵活 — session_uris list + 可选 ref + 一致性 soft warn)

**决策**:Python bridge `reply` MCP tool schema:

```json
{
  "type": "object",
  "properties": {
    "session_uris": {"type": "array", "items": {"type": "string", "format": "uri"}},
    "text": {"type": "string"},
    "ref": {"type": "string", "format": "uri", "optional": true}
  },
  "required": ["session_uris", "text"]
}
```

- `session_uris` 是 list — claude 可一次回多个 session(典型场景:A session 讨论的话题需要同时通知 B session 的 observers)
- `ref` optional — claude 可主动开口(proactive,无 inbound 触发),典型场景:claude 完成 long-running task 后主动报告
- ref 提供时,Agent Kind 查 ref 指向的 message 的 session_uri,跟请求 session_uris 比较:
  - 完全一致 → 静默通过
  - 部分一致 / 完全不一致 → emit `[:ezagent, :chat, :reply_session_mismatch]` telemetry + audit log warn + LV 红字提示,**仍按 session_uris 路由**(信任 claude 显式选择)

**理由**:
- claude 知道自己在干什么 — 用 ref 一致性 hard reject 反而阻断合法 cross-session 场景
- soft warn 既给 operator 调试线索(频繁 mismatch = routing rules 有问题或 claude prompt 有误),又不阻断
- ref optional 必要 — Phase 4+ proactive agent / scheduled task 会主动开口

**Agent Kind handle_kind_message 实现**:对每个 session_uri 各 dispatch 一次 chat/send,message envelope 复用(identity invariant — Decision #40)。

### P3-D9 — Bridge attach 默认 floating(不自动 join)

**决策**:Python bridge announce → Ezagent spawn Agent Kind + register KindRegistry。**不自动 dispatch chat/join 到任何 session**。

LV /admin 新增"Connected agents (floating)"区,列出 KindRegistry 里有但不在任何 Session.chat.members 的 agent。admin 点 "Add to session..." 选 session 后,dispatch chat/join 把 agent 拉进。

**理由**:
- Phase 2 默认 join main 是单 session 时代的简化;多 session 后"默认 main" 反而是隐式 routing decision
- floating 让用户对 agent 归属有显式 control,符合 "Ezagent 是 router 不是 req/resp app" 顶层原则
- 配 D8 后,reply 必带 session_uris;agent 自己也无法在 floating 状态发消息(没 session 没人收)— 强制配置才能工作,是 production usability 的好属性(memory `feedback_production_usability_is_selection_criterion`)

**Rejected alternatives**:
- (ii) 默认进 main:Phase 2 行为,但 Phase 3 多 session 后是 implicit 行为
- (iii) bridge announce 带 `EZAGENT_SESSION_URIS`:配置在 wrong 层 — session attach 是 operator runtime decision,不该烧到 bridge env

### P3-D10 — Routing rules persist 进 SQLite(admin 创建的规则重启后还在)

**决策**:加 `routing_rules` SQLite table。Schema:

```
id              integer primary key
table_name      string  (e.g. "MentionRouting" / "SessionRouting")
matcher_data    text    (Jason-encoded matcher AST)
receivers       text    (Jason-encoded [String.t()] of URI)
created_by      string  (URI of admin)
created_at      utc_datetime_usec
```

System-default rules(每个 session 启动时 `always() → [self.session_uri members]`)在 `EsrPluginChat.Application.start/2` boot 时写入(idempotent — 启动时 check 表里有没有,没有才插)。

Admin 创建的 rules 通过 LV form 或 mix task(`mix ezagent.routing.add_rule`)写入。Phase 3 LV 只 read-only 显示;Phase 4 跟 CLI 一起做完整 write UI。

**理由**:
- Routing rules 是 admin 长期配置物,跟 Workspace 类似 — 不能 in-memory 重启就丢
- 持久化层用现有 `EzagentCore.Repo` SQLite + 一个 migration,~50 LOC
- Phase 4 CLI 把这块的写入 UX 真正做完整

**Rejected alternative**:Rules 只 in-memory(boot 时从 application config 重建)— 等于 hardcode routing rules,失去 admin 配置能力。

---

## 实施期 spec review 已决判断(subagent code-reviewer 发现的 blockers,定稿前已 patch 进上面文档)

### #B1 — kind_server_spec 必须接受 extra_args

**问题**:Phase 2 `kind_server_spec(child_id, kind_module, uri)` 只传 `%{uri: uri}` 进 init_slice。Phase 3d Identity Behavior 需要 `initial_caps` 也进 args。

**决策**:3d-step 1 同时改 `kind_server_spec/3` → `kind_server_spec/4` 接受 `extra_args :: map()`,与 `%{uri: ...}` merge 传给 init_slice。Identity.init_slice 读 `args[:initial_caps]`(默认 MapSet.new())。

### #B3 — ref 在 wire 边界 string,内部 URI struct

**问题**:Python bridge JSON 传 `ref` 是字符串(MCP tool schema 定义为 string format=uri),但 `Message.new/3` 的 `:ref` opt 期望 `%URI{}`,`MessageStore.by_uri/1` 接受 string。

**决策**:Chat.handle_kind_message 收到 `(session_uris, text, ref)` 时:
- 调 `MessageStore.by_uri(ref)` 时 ref 保持 string(`by_uri` 内 query 用 string PK)
- 调 `Message.new(sender, body, ref: URI.new!(ref))` 时把 string parse 成 %URI{}(`new!/1` 失败可让进程死)

### #B4 — `main` Session 保持 static child(不通过 create_session/2)

**问题**:`EsrPluginChat.create_session/2` 内部用 `EsrPluginChat.SessionSupervisor` DynamicSupervisor;但 SessionSupervisor 也是 EsrPluginChat 的 static child。在 Application.start/2 内,supervisor 还没 start_link 完就 call create_session → 循环依赖。

**决策**:
- `main` 仍是 EsrPluginChat 的静态 Kind.Server child(Phase 2 行为)
- non-main session 才走 `create_session/2`(运行时由 admin / LV 触发)
- 默认 routing rule(`always() → main members`)在 `EsrPluginChat.bootstrap_default_rules/0` 内,跟 admin User join 一起在 post-Supervisor-up hook 里跑

### #B5 — invariant #9 grep 前置改造(audit.ex / telemetry / LV label)

**问题**:Phase 2 `audit.ex` 行 `authz: "stub_grant"`、telemetry @events 列表、admin_live.ex `authz_label` 都使用 `stub_grant` 字符串/atom。直接加 invariant #9 grep `stub_grant` 会 false-positive 命中这些合法代码常量。

**决策**:Phase 3d step 5 加 invariant 之前,先在 step 3 / step 4 内完成:
1. `audit.ex` 列名改 `authz` 接受 `"granted"` / `"denied"` / `"stub_grant"`(legacy)
2. telemetry `@events` list 加 `:granted` / `:denied`,**保留 `:stub_grant`** 但 Phase 3d 后 emit 不再触发
3. admin_live.ex `authz_label` 加 `[:ezagent, :authz, :granted] → "granted"` + `[:ezagent, :authz, :denied] → "denied"`
4. invariant #9 grep 用 atom 形态 `:stub_grant`(带 colon)— code 里所有 emit 路径都是 `[:ezagent, :authz, :stub_grant]`,改完后不应该出现这个 atom literal

### #P1-1 — RoutingRegistry vs BehaviorRegistry / KindRegistry 模式分歧

**问题**:RoutingRegistry 含 put_new + owner-pid check;BehaviorRegistry 是 bare ETS 无 check(boot-time-only,last-writer-wins OK);KindRegistry 用 stdlib Registry。三种模式。

**决策**:RoutingRegistry 走第三模式有正当理由 — admin 运行时写入(非 boot-only),owner-only-write 防 plugin 互相 stomp 各自 table。在 module moduledoc 加段比较表 + 解释。BehaviorRegistry / KindRegistry **不**改造,Phase 4+ 评估是否统一。

### #P1-3 — Resolver 签名:`resolve(message, current_session_uri)`,内部 query 多 tables

**问题**:SPEC L11 + PLAN 3a-step 3 + DECISIONS 实施期不同处提了 3 个不同 Resolver 签名。

**决策**:统一为 `resolve(message :: Message, current_session_uri :: URI) :: [recipient_uri]`。Resolver 内部 hard-code query `MentionRouting` + `SessionRouting`(可读 application config 改 table 列表 — Phase 4+)。

### #P1-5 — `msg.mentions` 仍是 mention(URI) matcher 的 input

**问题**:spec 没明说 Resolver 重构后 msg.mentions 字段还有没有用。

**决策**:`msg.mentions` 字段保留,作 `Ezagent.Routing.Matcher.mention(URI)` 的判断 data source(matcher.match? 内查 message.mentions)。Chat 不直接看 mentions,但 routing rules 用 mention(URI) 时就会触发。这样保持 Phase 2 admin compose form 的 @-agent dropdown 行为不变。

### #P1-6 — 3b-step 2 不是"Phase 2 regression",是 contract change

**问题**:bridge announce 移除 auto-join 后,Phase 2 cc_bridge_announce_controller_phase2_test.exs 的 announce assertions 失败 — 不是 regression(回归)而是合约变更。

**决策**:VERIFICATION 3b 段 wording 改为 "Phase 2 chat send/receive once member manually joined" — 强调 manual join 这一步是 Phase 3 的新合约。Phase 2 测试代码必须随之更新(在 3b step 2 commit 内完成)。

### #P1-8 — `Capability.cap_for_action` 必须接受 target URI

**问题**:dispatch step 5.5 已有 `target :: URI`(e.g., `session://main/behavior/chat/send`),`cap_for_action` 需要从 target 提取 `instance` URI(session://main),才能构造 cap_needed。

**决策**:`Ezagent.Capability.cap_for_action/3` 签名:`cap_for_action(kind_module, action, target_uri) :: %{kind: atom, behavior: module, instance: URI}`。instance 从 target_uri 提取(Ezagent.URI.instance/1,已存在)。

---

## 实施期可能撞到的决策点(/goal 撞到时按原则定)

### Routing Resolver 跟 Matcher 的接口

`Resolver.resolve(message, current_session_uri) → recipients` 的内部要 query 哪些 routing tables?

- (a) 只 query 1 张表 per session(per-session routing decisions all in MentionRouting)
- (b) Query 多张表然后 union(SessionRouting + MentionRouting + 默认 always() rules)
- (c) Resolver 接受一个 `[table_name]` 参数,plugin 自决

**原则**:(b)。Phase 3 hard-code 查 MentionRouting + default rules;Phase 4 跟 CLI 加可配置 table priority。

### Matcher AST 序列化格式

`matcher_data` 字段存什么?

- (a) 字符串 representation(`"mention(agent://X)"`)+ runtime parse
- (b) JSON struct(`{"type": "mention", "uri": "agent://X"}`)
- (c) Erlang term `:erlang.term_to_binary/1`

**原则**:(b)。跟 ARCHITECTURE.md Decision #42 一致(Matcher AST 可序列化 → JSON-friendly)。Phase 4 CLI 写入时也好生成。`Ezagent.Routing.Matcher` 加 `to_json/1` + `from_json/1`。

### default routing rules 怎么"代表 session"

System-default rule 写入时 receivers 列表是空(因为新创建 session 还没成员)— 怎么实现 "always() → 本 session members"?

- (a) 特殊 receiver token `{:self_members, :all}`,Resolver 解析时查 session 当前 members
- (b) 不写"members"规则进 RoutingRegistry,Chat.invoke(:send) **fall through** 时(routing rules 全 miss)默认 fan-out 给 members
- (c) 每次有 member join/leave 时 rebuild routing rules

**原则**:(b)。Phase 3 维持"显式 rules + 默认 members fan-out"双轨。routing rules 用来配置 cross-session / mention-based 路由;基础 in-session fan-out 仍走 Phase 2 的 members 默认。这样 routing rules 完全 additive(memory `feedback_let_it_crash_no_workarounds` — 不为新增能力打破老路径)。

### Identity Behavior 的 slice 形态

`Ezagent.Behavior.Identity.init_slice(args)` 返回什么?

- (a) `%{caps: MapSet}` — 直接持 caps
- (b) `%{user_id: String, profile: %{...}, caps: MapSet}` — 全 identity state
- (c) `%{}` — caps 在 User Kind 的 admin_caps/0 函数返回,Identity Behavior 只是占位 attach point

**原则**:(a)。Phase 3 Identity 只持 caps(Phase 4 加 profile / user_id 等)。`admin_caps/0` 改为 read Identity.slice.caps,确保 cap 真的在 Kind state 里(repl 时可 inspect)。

### CapBAC flip 后的测试 fixture 改造

Phase 1/2 所有测试 fixture 用 `ctx = %{caps: MapSet.new(), ...}` 空 caps。Phase 3d 后所有 dispatch 会 deny(except admin_caps)。

- (a) 全测试改:`ctx.caps = Ezagent.Entity.User.admin_caps()` — copy admin all-caps
- (b) 加 test helper `Ezagent.Test.Caps.granting(needed_cap)` 生成精确 cap — 强类型,但每个测试要想清楚
- (c) Mixed:大部分单元测试用 (a) admin caps;1-2 个 integration 测试明确测 cap denial 用 (b) 精确

**原则**:(c)。日常测试 admin caps 足够;cap 拒绝场景明确 case 化测。

### routing rule 删除 + audit

如果 admin 删除一条 routing rule,旧消息的 routing 历史是否仍可追溯?

- (a) Rules soft delete(`deleted_at` 字段);historical routing 可解释
- (b) Rules hard delete;routing 历史在 audit log 里有(invocation 表里 trace_id + 当时 routing 决策的 receivers list)
- (c) 不支持删除,只支持 disable(toggle)

**原则**:(b)。invocation 表已有 trace_id + receivers;rules 表保持简洁。Phase 4 加 cli 命令时把 enable/disable 加进来(不破坏 rule history)。

---

## /goal 文本预览(待 subagent review 通过后定稿)

```
/goal Work in /Users/h2oslabs/Workspace/ezagent/.claude/worktrees/phase-3/
(create via git worktree if not exists). cd there + verify git branch is phase-3.

Implement ezagent Phase 3 sub-steps 3a → 3b → 3c → 3d. Tags
phase3a, phase3b, phase3c, phase3d (=phase3) pushed to origin.

DONE when:
1. git tag shows 4 sub-step tags pushed
2. Every checkbox in docs/phase-specs/phase3/VERIFICATION.md ticked
3. sub-step-gate.sh green at all 4 tag commits
4. /tmp/phase3-final.png agent-browser screenshot exists,
   archived to docs/phase-specs/phase3/artifacts/
5. SQLite routing_rules table populated with default + 1 admin rule
6. Phase 1+2 functionality NOT regressed (Echo / Chat /
   bridge attach all still work)
7. Phase 3d alarm check: no `:stub_grant` telemetry emitted

PRIMARY REFS:
- docs/phase-specs/phase3/{SPEC, VERIFICATION, PLAN, DECISIONS}.md
- ARCHITECTURE.md §5.4 (RoutingRegistry) §6.6 (Matcher) §7 (CapBAC)
- GLOSSARY.md Decision Log #88-#94 (Phase 2 emergent context)

APPROACH: TDD per PLAN.md. 3a-d each ~4-6 commits with internal gates.
Tag at end of each sub-step.

ARCHITECTURAL INVARIANTS (grep before each tag):
- ZERO hardcoded URI in code (continue Phase 2 invariant)
- RoutingRegistry put_new for unique-key tables
- Chat.invoke(:send) calls Resolver.resolve (not mentions=members default)
- After phase3d: no :stub_grant in telemetry handlers (invariant #9)
- After phase3d: Capability.matches? called in dispatch (invariant #10)
- Phase 1+2 regression: bridge attach + chat send/receive still work
- LV chat row template stays identical for admin/agent (Phase 2 invariant)

If gate red: STOP, no push, no tag. Feishu report failure mode.

Memory rules: feedback_flag_user_assist_steps /
feedback_completion_requires_invariant_test /
feedback_let_it_crash_no_workarounds /
feedback_subagent_review_plans (before each sub-step commit).

USER ACTION REQUIRED (Allen):
- Phase 3a end: review RoutingRegistry API + Matcher set adequacy
- Phase 3b end: visual LV sessions sidebar + floating agents (agent-browser screenshot)
- Phase 3d end: cap denial scenario walk-through
```
