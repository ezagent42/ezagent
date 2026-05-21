# Phase 3 — VERIFICATION

> Phase 3 sub-step gate + 整体 gate 的验收契约。
> 配套:`SPEC.md` / `PLAN.md` / `DECISIONS.md`
> Sub-step gate 是 /goal 自动化检查;Phase 整体 gate 是 Allen 人工 sign-off 单元(per Decision #80)。

## 验收原则(继承 Phase 1/2)

- 每个 sub-step tag(`phase3a`/`phase3b`/`phase3c`/`phase3d`)前 sub-step-gate.sh 必须绿
- Gate = `mix format --check-formatted` + `mix compile --warnings-as-errors` + `mix test` + `mix ezagent.check_invariants` 全清
- `phase3` 整体 tag 等价 `phase3d` 完成
- 任意 gate 红 → STOP,不 tag 不 push,Feishu 报失败模式
- 自动化 e2e(agent-browser)在 phase3d 后跑;USER ACTION 标注节点等 Allen 配合(见下)

## Phase 3 整体 demo(验收的终极标准)

完成后 Allen 能完成场景 walk-through:

1. `mix phx.server` 启动 esrd(已运行 4 sub-step 的 migration)
2. 浏览器 `/admin`:
   - 左侧 sessions 侧栏只有 `session://main`
   - 主区是 main 的 chat-window + members(只有 admin online)
   - 右上"Connected agents (floating)"区为空
3. 终端 `bash scripts/cc-bridge-attach.sh`(.local.sh.example 已 `EZAGENT_AGENT_URI=agent://cc-builder`)
4. LV 刷新看:floating 区出现 `agent://cc-builder · connected`,**不在任何 session**
5. 点 cc-builder 的 "Add to session..." → 选 `session://main`。Members 栏出现 cc-builder online
6. main compose 发"hi cc-builder,设计 X 给我"。chat stream 显示 admin 的消息;~2s 后 cc-builder 的回复(green row)出现
7. 顶部"+ New session"→ 输入 `architect-review` → session 出现在侧栏
8. 切到 architect-review。Members 只有 admin(automatically join after create)
9. 回 main,点 cc-builder "Add to session..." → 选 architect-review。cc-builder 现在**同时在 main 和 architect-review**(main Members 栏 cc-builder 有"也在 architect-review" badge)
10. 切到 architect-review。compose 发"now review your design"。claude 收到(`channel meta` 含 session=architect-review),reply 时 `session_uris=["session://architect-review"]`,只 architect-review session 看到回复
11. 写一条 routing rule(暂时通过 mix task:`mix ezagent.routing.add_rule MentionRouting text_contains:urgent receivers:session://architect-review`)。LV "Routing rules" 区 read-only 显示这条规则
12. main compose 发"server urgent down"。**两个 session 同时收到该消息**(main 因 default fan-out + architect-review 因 routing rule)
13. 验证 audit log 显示 `:granted`(Phase 3d 真 cap 路径),没有 `:stub_grant`
14. 验证 SQLite `routing_rules` table 至少有 2 行(默认 + 用户加的)
15. 测试 cap deny:LV Debug 区构造 dispatch 一个 admin 没有的 cap(例如假装 caller 是 `user://nobody`),audit 显示 `:denied` + reason

## Sub-step 切分(候选)

| Sub-step | 焦点 | sub-step gate(单元/集成 + e2e 部分) | 估时 |
|---|---|---|---|
| **3a** | Routing 数据层 | RoutingRegistry / Matcher / Resolver 全 unit 测试通过 | ~3-5h |
| **3b** | Multi-session UX | LV agent-browser snapshot:sessions sidebar 渲染 + create session + floating agent add-to-session | ~4-6h |
| **3c** | Chat + reply 改造 | curl 模拟新 reply 协议(3 字段)+ 多 session reply 一致性 soft warn telemetry assertion | ~3-4h |
| **3d** | CapBAC 真化 | dispatch deny 路径测试 + invariant #9 #10 + Phase 1/2 整体回归 | ~4-6h |

---

## Gate per sub-step

### 3a Gate · Routing 数据层

- [ ] `Ezagent.RoutingRegistry` 7 函数(`declare_table/2` + `put_new/3` + `put/3` + `lookup/2` + `lookup_all/2` + `list_all/1` + `reverse_index/3`),ETS-backed
- [ ] `Ezagent.Routing.Matcher` 5 个 leaf(`mention/1` / `from/1` / `text_contains/1` / `text_matches/1` / `always/0`)+ `match?/2`
- [ ] `Ezagent.Routing.Resolver.resolve/2` — 签名 `(message :: Message, current_session_uri :: URI) :: [recipient_uri]`,内部 hard-code query MentionRouting + SessionRouting 两表;additive 累加多 rules;返 `[]` 给 caller 表示 fall-through 到 in-session default
- [ ] `messages` 表 + `message_routings` 表 migration 应用;`MessageStore.write/2` upsert 行为(同 msg URI 写 2 个 session → messages 1 行 + message_routings 2 行)
- [ ] `Ezagent.Routing.RuleStore` Ecto.Schema + migration + `add/3` + `list/1`
- [ ] `Ezagent.Routing.Matcher.to_json/1` + `from_json/1` round-trip
- [ ] EzagentCore.Application 添加 RuleStore migration 到启动序列
- [ ] EsrPluginChat.Application declare SessionRouting + MentionRouting 表
- [ ] 单元覆盖:Matcher 各 leaf / Resolver additive 行为 / RuleStore round-trip
- [ ] G1 `mix compile --warnings-as-errors` clean
- [ ] G2 `mix test` 全绿(预期 +25-30 测试)
- [ ] G3 `mix format --check-formatted` clean
- [ ] G4 `mix ezagent.check_invariants` exit 0

### 3b Gate · Multi-session UX

- [ ] LV /admin 加 sessions sidebar(显示当前 sessions list + "+ New session" 按钮 + click 切换 current_session_uri)
- [ ] LV 加 floating agents 区(列 KindRegistry 里 agent:// 但不在任何 Session.members)
- [ ] LV 每个 floating agent 的 "Add to session..." 下拉(列当前 sessions,选后 dispatch chat/join)
- [ ] LV 创建 session 表单 → dispatch `session://<new>/behavior/chat/init` 或直接 `EsrPluginChat.create_session(short_name)` API
- [ ] Session create 时 admin 自动 join 新 session(boot pattern 同 admin User join main)
- [ ] EsrPluginChat boot 加 `create_session("main")`(idempotent)
- [ ] Bridge controller `announce/2` **不再** dispatch chat/join(removed Phase 2 行为)— 只 spawn Agent Kind + bind
- [ ] LV move agent 操作:dispatch leave-from-old + join-to-new(两条 cast)
- [ ] LV cross-reference badge:Members 栏 agent 在多个 session 时显示"也在 X session"
- [ ] 单元 + 集成测试:create session / add agent to N sessions / move agent / floating list 准确
- [ ] LV test:agent-browser snapshot 验 sidebar + floating + add-to-session UI 都渲染
- [ ] Phase 2 chat send/receive 仍工作(在 manual chat/join 之后,**走 default fan-out**)— Phase 3 contract change(per #P1-6):bridge attach **不再** auto-join,需手动 add-to-session 后才有 chat 流
- [ ] G1/G2/G3/G4 gates(同 3a)

### 3c Gate · Chat + reply 改造

- [ ] `Ezagent.Behavior.Chat.invoke(:send, ...)` 改 `Resolver.resolve(message, ctx.self_uri) ++ default_members` → receivers
- [ ] 默认 fan-out 路径:若 Resolver 返回 []`则 fall through 到 Phase 2 行为(members fan-out 默认)— per DECISIONS Resolver 接口决策 (b)
- [ ] Python bridge `reply` MCP tool schema 改 `{session_uris: [str], text: str, ref?: str}`
- [ ] Bridge Server `forward_reply_to_agent/2` 改 `forward_reply_to_agent/4`(bridge_id, session_uris, text, ref)
- [ ] Chat `handle_kind_message({:reply_received, session_uris, text, ref}, ...)` 改造:
  - 对每个 session_uri 各 dispatch 一次 chat/send,message envelope 复用(identity invariant)
  - 若 `ref` 提供:查 `Ezagent.MessageStore.by_uri(ref).session_uri`,跟 session_uris 比较;**不匹配 emit `[:ezagent, :chat, :reply_session_mismatch]` telemetry + audit warn**,**仍按 session_uris 路由**
- [ ] LV "reply session mismatch" 显示:audit 流里这种 event 显红字
- [ ] curl 测试:发 reply with mismatched ref → audit warn assertion + 消息正确路由
- [ ] Phase 2 整体回归:single-session reply(session_uris=["session://main"], ref=last_received)仍工作
- [ ] G1/G2/G3/G4 gates

### 3d Gate · CapBAC 真化

- [ ] `Ezagent.Behavior.Identity` 模块(ezagent_core)— init_slice `%{caps: MapSet}` + invoke `:list_caps` / `:has_cap?`
- [ ] `Ezagent.Entity.User.behaviors/0` 加 Identity;init_slice 初始化 admin_caps
- [ ] `Ezagent.Entity.Agent.behaviors/0` 加 Identity;init_slice 初始化空 caps(Agent 默认无 cap,只能"被 mention 时收消息")
- [ ] `Ezagent.Capability.cap_for_action(kind_module, action) :: cap_needed_t` 函数
- [ ] `Ezagent.Kind.Runtime.handle_dispatch` step 5.5:`authz_stub` 删除,替换为 `Ezagent.Capability.matches?(ctx.caps, needed)` 真调用
- [ ] dispatch `:granted` / `:denied` telemetry emit(取代 `:stub_grant`)
- [ ] LV/CLI ctx 构造时:`ctx.caps = Identity.list_caps(caller_uri)` 而非 `Ezagent.Entity.User.admin_caps()` 硬编码
- [ ] 所有现有测试 fixture 改造:测试 ctx 设置精确 caps 或用 admin_caps helper
- [ ] check_invariants #9:`grep stub_grant apps/ezagent_core` 命中 = bug(只能在 docstring 出现,不能在 code)
- [ ] check_invariants #10:`Ezagent.Capability.matches?` 出现在 `kind/runtime.ex` step 5.5
- [ ] cap deny 测试:精确 fixture 构造 deny 场景 → 验证 dispatch 返 `{:error, :unauthorized}`
- [ ] Phase 1+2 整体回归:全部测试改 fixture 后仍绿
- [ ] G1/G2/G3/G4 gates(等价整体 phase 3 gate)

---

## Phase 3 整体 Gate(`phase3` tag = 3d 完成)

- [ ] 3a + 3b + 3c + 3d 全部 sub-step gate 绿
- [ ] LV /admin agent-browser 截图存到 `docs/phase-specs/phase3/artifacts/phase3-final.png`,显示 2 个 session + 1 个 agent 在两个 session 都 online
- [ ] SQLite `routing_rules` table 至少 3 行(per-session 默认 fan-out + 一条 admin 加的 demo 规则)
- [ ] SQLite `messages` table 至少 4 条(单 message URI per envelope,跨 session 共享);`message_routings` 表至少 6 行(2-session demo 各 2 admin + 2 agent reply,跨 session 复用 message 走 routings 多行)
- [ ] `mix ezagent.check_invariants` 6 个老 + 2 个新(#9 #10)全绿
- [ ] Phase 2 全功能不退化(Echo / Manual Dispatch / Phase 2 chat send 仍可达,看 Debug 区)

## 人 review 关键点(Allen)

Phase 3 完成时 Allen 重点 review:

1. **Routing rules 配置体验** — admin 加规则的 mix task 体验 OK 吗?error message 清晰吗?
2. **多 session UX 直观度** — 切 session / add agent / floating list — 能否 1 次操作完成意图?
3. **Reply session mismatch warning** — audit log 红字 / LV 显示是否够明显?Operator 能否快速发现?
4. **Cap deny 错误反馈** — admin 触发 deny 时 LV 显示什么?error message 给 operator 信息够用?

## USER ACTION REQUIRED(Allen 介入节点)

Phase 3 3 处需要 Allen 介入:

1. **3a 完成后**:Feishu 报 API 设计 + Matcher 5 类是否够 demo 需求。Allen 看了 SPEC 同意就走 3b。如果觉得 5 个不够或缺组合子要重判 P3-D3
2. **3b 完成后**:agent-browser 截图发 Feishu。Allen 看 UI 是否如想象(sessions sidebar / floating list / add-to-session 流程)。改 UX 重排 3b
3. **3d 完成后**:cap deny scenario walk-through。Allen 跟着步骤 1-15(整体 demo)走一遍,确认 routing + cap 实际体验。这是 Phase 3 整体 sign-off 单元

每个节点 Feishu **明确停下来报告**(per memory `feedback_flag_user_assist_steps`)。autonomous 模式期间(无 Allen 在线)按 `feedback_wake_but_dont_stop`:proceed with recommendation,Allen 上线回看 + 必要时调整。

## 不变式 grep(继承 Phase 1+2,新增 Phase 3)

- 老 invariant #1:`PubSub.broadcast` allowlist(audit / invocation / chat.ex / **新增 chat.ex 多个 broadcast 场景仍同源**)
- 老 invariant #2:`def init(` 只能在 Kind.Server 等已知文件(新增 `esr_plugin_chat` 不加 def init)
- 老 invariant #3:`:not_ready, :call` fail-fast clause 存在
- 老 invariant #4:`Registry.register` 只能在 KindRegistry.put_new
- 老 invariant #6:audit handler 无直接 SQL
- 老 invariant #7:DLQ :unroutable 仍声明
- **新增 invariant #9**:`grep -E ':stub_grant' apps/ezagent_core/lib --include='*.ex'` 命中行 — atom literal `:stub_grant` 出现 = bug;allowlist 仅 `apps/ezagent_core/lib/esr/telemetry.ex` 内 @events list 的兼容声明(per #B5 pre-check)
- **新增 invariant #10**:`grep -E "Capability.matches\\?" apps/ezagent_core/lib/esr/kind/runtime.ex` 必有 — 不存在 = stub 复活;**真正语义验证靠 runtime test** `runtime_phase3d_test.exs` 内"deny ctx → :unauthorized"测试(per #P1-7 + memory `feedback_completion_requires_invariant_test`)
