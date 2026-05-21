# Phase 2 — DECISIONS

> Phase 2 brainstorm 阶段已决判断点 + 实施期可能撞到的决策点 + 决策原则。
> 已决项实施完后 append 进 `GLOSSARY.md` Decision Log(架构师本侧 patch,工程师建议编号 #88+)。

## 已决(Phase 2 brainstorm 全 5 主题 + offline 子题,Allen 代签 sign-off 2026-05-16)

### P2-D1 — `%Ezagent.Message{}` shape:6 字段 + UUID + 结构化 body

**决策**:Message struct 含 6 字段(`uri`, `sender`, `mentions`, `body`, `ref`, `inserted_at`),body 是 `%{text: String.t(), attachments: [URI.t()]}` 结构化 map。`uri` 是 UUID(`message://<uuid16>`)由 `Ezagent.Message.new/3` 在构造时生成,作为 identity reference 而非 identity payload — identity invariant 仍只锁原 5 字段(sender/mentions/body/ref/inserted_at 跨转发不变,per Decision #40)。

**理由**:body 结构化让 §10.5 attachments 字段 Phase 2 预留位但不实现(Phase 5);UUID 在 `new/3` 时立即生成支持 ref 字段引用 in-flight message(Echo reply 直接走 ref 时无需等 persist)。

**API**:`Ezagent.Message.new(sender, body, opts \\ [])` — sender + body 必填,`:mentions` / `:ref` / `:inserted_at` 在 opts。

### P2-D2 — Chat Behavior 模型:K 路径 + 4 actions menu + per-Kind register subset

**决策**:`Ezagent.Behavior.Chat` 暴露 actions menu `[:send, :receive, :join, :leave]`。每个 Kind 在 BehaviorRegistry register **subset**:
- `Ezagent.Entity.Session` 接 `send` / `join` / `leave`
- `Ezagent.Entity.Agent` 接 `receive`
- `Ezagent.Entity.User` 接 `receive`

dispatch 错误 `(Kind, action)` 对(如 `agent://X/behavior/chat/join`)→ BehaviorRegistry lookup 返 :error → `{:error, {:unknown_action, action}}` 自然拒绝。

**为什么 K 路径**(每外部参与方有自己的 Kind)而非 P 路径(Session 内 orchestrator 含特殊知识):K 路径在 6 个 Elixir/OTP 维度全胜(let-it-crash + supervisor / 进程隔离 / pattern matching dispatch / plugin 隔离北极星 / PubSub 模式 / dispatch 可组合性),且是 Decision #61("Ezagent 是 router")真正落地。+30 LOC for proper plugin isolation 完全值。

### P2-D3 — Session.Chat state slice 4 字段 + MessageStore as single source of truth

**决策**:Session.Chat state slice = `%{members: MapSet, online: MapSet, last_seen: %{URI => DateTime}, monitors: %{ref => URI}}`。**无 pending queue**:offline 期消息从 MessageStore 派生(via `in_session_since(session_uri, last_seen[URI])` on rejoin)。

**Failure design — 5 failure modes 全覆盖**:
- (1) **BEAM 重启**:Session state 重置(`:ephemeral`),MessageStore 持久;LV mount 渲染历史不丢;在线状态在 admin/agent 重 join 后恢复
- (2) **优雅 leave vs involuntary DOWN**:explicit `:leave` 走 invoke clause 主动 remove members + drop last_seen(caller 表示不要 replay);`:DOWN` 走 `handle_member_down/2` hook,保留 members + 写 last_seen(等 rejoin replay)
- (3) **Monitor race**(`KindRegistry.lookup` 返还活 pid,但 `Process.monitor` 之前进程刚死):`Process.monitor` 对已死 pid **立刻**触发 `{:DOWN, ref, :process, pid, :noproc}` —— `handle_member_down/2` 同样处理,member 立刻进 last_seen + offline。无需特殊代码,Process.monitor 语义自然保证
- (4) **Pending replay 边界**(member 离线很久,MessageStore 累积 N 条):`MessageStore.in_session_since/2` SQL 加 **`LIMIT 1000` cap**(Phase 2 边界,Phase 3 加分页);超过 1000 条的 backlog,replay 仍是 last_seen 之后的最近 1000 条,older messages 仍在 store 可查但 rejoin 不全部回放。emit `[:ezagent, :session, :replay_bounded]` telemetry 让 operator 知道有截断
- (5) **Network partition**(bridge SSE 连接断,但 Agent Kind 还活):Phase 2 **不主动检测**(SSE socket 断时 Python bridge 进程会自然死,SIGPIPE → Python finally 块 POST DELETE → controller terminate Agent Kind → `:DOWN` → 正常 offline 路径)。Phase 3 加 application-layer heartbeat 给 partition 兜底场景

**为什么不存 pending queue**:logic 重复 MessageStore。memory `feedback_converge_to_uri_list` 同精神 —"可派生的就不该独立维护"。-30 LOC + 单一真相源。

### P2-D4 — Bridge agent URI 配置驱动 + 动态 Kind spawn

**决策**:
- Python bridge env `EZAGENT_AGENT_URI`(在 `cc-bridge-attach.local.sh` 配,gitignored,operator-level)
- announce body 多带 `agent_uri` 字段
- Ezagent controller 收 announce → 动态 spawn `Ezagent.Entity.Agent` Kind 实例 via DynamicSupervisor
- LV dropdown 动态读 KindRegistry,**ZERO hardcoded URI in code**

**为什么**:Phase 2 → Phase 5 multi-agent 平台目标。hardcoded 在 LV / Chat Behavior / bridge / attach script 共 4 处会爆,Phase 5 全要拆。Phase 2 +20 LOC 解 4 处 future debt。memory `feedback_production_usability_is_selection_criterion` + `feedback_let_it_crash_no_workarounds` 都指向此路径。

**Default 是 config-driven**:`cc-bridge-attach.local.sh.example` 内 `export EZAGENT_AGENT_URI=agent://cc-builder`,operator cp 后改自己的 URI。代码 zero hardcode。

### P2-D5 — Bridge reply 路径:Agent Kind 自构造 + 自 dispatch(完整对称)

**决策**:
- Phase 1 `Server.record_reply` + `bridge_messages` LV 面板 **删除**
- 新路径:HTTP `/api/cc-bridge/reply` → Controller forward to `Server.forward_reply_to_agent(bridge_id, text)` → Server 找 Agent Kind pid → cast `:reply_received` → **Agent Kind 自己**构造 `%Ezagent.Message{sender: self_uri, body: %{text, attachments: []}}` → `Ezagent.Invocation.dispatch(target = session://main/behavior/chat/send, args = message)`

**为什么**:跟 LV submit 路径**完全对称** — LV 构造 Message + dispatch session/behavior/chat/send,Agent 也构造 Message + dispatch 同 entry。两条 ingestion path 合流,符合 K 路径精神(每个 Kind 自治,代表自己发言)。

**LV 视觉表现**:chat stream 里 Allen 输入和 claude 回复 row 模板完全一致(同一 component,只 sender / 颜色微差)。Phase 2 visual invariant — 验证"Phase 1 的特殊化已经打破"的唯一直接证据。

### P2-D5b — admin User Kind 升级为真 Kind(P-5 实施落地)

**决策**:Phase 1 `Ezagent.Entity.User` 是 stub(只暴露 admin_uri/admin_caps 常量函数)。Phase 2 升级为真 Kind:
- behaviors `[Ezagent.Behavior.Chat]`(实现 :receive 实现 — push to LV via PubSub user-inbox topic)
- admin_uri/0 + admin_caps/0 函数保留不变
- type_name :user / persistence :ephemeral(Phase 2 同形)
- Application boot 时 spawn `user://admin`,init 时 dispatch `session://main/behavior/chat/join`
- Phase 3d cap 真化后,User Kind 加 Identity Behavior(那时是 Phase 3d 工作)

### P2-D6 — Phase 2 加 LV chat-window UI 重建(在 2c sub-step)

**决策**:仅删 Phase 1 "← from claude" 独立面板不够,必须**重建为 chat-window 形态**(垂直 message stream + 成员侧栏 + 底部 compose)。**Phase 1 的 Echo button / Manual Dispatch form / Audit Log table 不删,移到 "Debug" 折叠区**,不占主视野。

**为什么**:Phase 2 visual invariant("Allen 输入和 claude 回复 row 模板一致")需要正常 chat UI 而非裸 audit table。仅删 Phase 1 面板而不重建 = LV 比 Phase 1 还差(老面板至少有专门区,新版只剩单一 audit 流混合)。chat UI 不是 nice-to-have,是 Phase 2 完成的必要可视化载体。

**Phase 2 不做的 UI 形态**:thread / 富文本 / 文件上传 — 全部 Phase 3+ / Phase 5。

---

## 实施期决策点(/goal 撞到时按原则定)

### Ezagent.Behavior.Chat handle_member_down hook 接入机制

**问题**:`Ezagent.Kind.Server.handle_info({:DOWN, ref, ...})` 怎么把消息转给 Behavior 模块?Phase 1 Kind.Server 没暴露 Behavior-level handle_info hook。

**原则**:`Ezagent.Kind.Server` 加 ~10 LOC — `handle_info({:DOWN, ref, :process, _pid, _reason}, state)` 内查 `state.kind` Behaviors 哪个 export `handle_member_down/2`(`Code.ensure_loaded?` + `function_exported?`),逐 Behavior call。`Ezagent.Behavior.Chat` 实现该 hook,update slice 中 monitors / online / last_seen。**Phase 1 Decision #84 trade-off note** 提到的"shared Server defensive 处理多 Kind state shape"在此处具体落地。

### MessageStore.write 写入失败处理

**问题**:Chat.invoke(:send) 调 MessageStore.write 失败(磁盘满 / DB lock / 网络分区)怎么办?

**原则**:`{:error, reason}` 返回,**不**继续 broadcast / dispatch。Message 是 first-class 业务数据,write 失败 = send 失败。LV 显示 flash error。Caller 决定重试。

### Phase 1 LV form "Send to Claude (via channel)" 处理

**问题**:Phase 1b 在 LV 加的 "Send to Claude" form(`channel_push` event handler)跟 Phase 2 主 chat compose 区有功能重叠?

**原则**:**删除** Phase 1 form。Phase 2 主 compose 是唯一 sending UX:Agent dropdown(替代原 bridge dropdown)+ text + Send。语义无变化(操作员选目标 + 输入 + 发),只是位置和形态融入 chat-window。memory `feedback_self_explained_naming` 同精神(不留两个语义相同的入口让用户迷惑)。

### 多 Agent Kind 同 EZAGENT_AGENT_URI announce

**问题**:Allen 错误地启动两个 attach script 用相同 `EZAGENT_AGENT_URI`,第二个 announce 怎么办?

**原则**:`KindRegistry.put_new` 自然 reject 第二个 spawn(invariant #4 维护)。**Controller `announce/2` 必须显式 pattern-match `DynamicSupervisor.start_child/2` 返回值**:`{:ok, _pid}` → 200;`{:error, {:already_registered, _}}` 或 `{:error, {:shutdown, {:already_registered, _}}}` → **HTTP 409 conflict** + 详细错误消息("agent URI X already attached");其他 error → HTTP 500。第一个 bridge 不受影响。Phase 2 boundary 不主动验证多 agent UX,但 controller 不返 500 给正常竞争场景。

### Ezagent.InterfaceValidator 跟 %Ezagent.Message{} 的兼容

**问题**:`Ezagent.Behavior.Chat.interface/0` 声明 `:send` 的 args 时,直接写 `%Ezagent.Message{}` struct 还是写 type-spec schema map?

**原则**:**写 type-spec schema map**(per Phase 1 InterfaceValidator 现有 grammar)。`Ezagent.Behavior.Chat.interface/0` 返回:
```elixir
%{
  send: %{
    args: %{
      uri: :string,
      sender: :string,
      mentions: {:list, :string},
      body: :map,
      ref: {:option, :string},
      inserted_at: :string
    },
    returns: %{},
    modes: [:call, :cast]
  },
  receive: %{args: %{...}, returns: %{}, modes: [:cast]},
  join: %{args: %{uri: :string}, returns: %{}, modes: [:cast]},
  leave: %{args: %{uri: :string}, returns: %{}, modes: [:cast]}
}
```

Caller 构造 `%Ezagent.Message{}` struct 然后 dispatch 时,InterfaceValidator 把 struct 当 map(structs 是 maps)读各字段,跟 schema map 比对类型。URI 字段在 schema 是 `:string`(因为 Ecto custom type 在持久化层把 URI struct ↔ string),但在 in-memory message struct 是 `%URI{}` —— InterfaceValidator 见 `%URI{}` 不 match `:string` 会 fail。**所以 InterfaceValidator 需要小改 1**:`:uri` 作为新 type-spec primitive,接受 `%URI{}` struct(2a-step 1 加 ~5 LOC)。Schema 改成 `uri: :uri, sender: :uri, mentions: {:list, :uri}, ref: {:option, :uri}`,其他保持。

### LV chat stream limit + scroll behavior

**问题**:LV mount 加载 recent 50 + new message stream_insert 时,显示 limit 怎么设?

**原则**:Phoenix.LiveView.stream `limit: 50` 自然 LRU 滚出旧条目。autoscroll 默认开(JS `scrollIntoView` hook on `stream_insert` event)。无 manual pagination(Phase 3+ 加 history 滚动加载)。

### `docs/phase-specs/phase2/artifacts/` 存 screenshot

**原则**(沿用 Phase 1):screenshot 跟 spec 同 commit 进 git;Phase 2 只一张 `phase2-final.png`(2c 整体 e2e 完成时的截图);size 限 < 1MB(SCREENSHOT 是验收凭证)。

---

## 跟 ARCHITECTURE.md / GLOSSARY.md 同步

**架构师本侧 patch(工程师 phase 2 完成后建议)**:

| # 建议编号 | 决策内容 | period |
|---|---|---|
| **#88** | **Chat Behavior K 路径实施落地**:actions menu `[:send, :receive, :join, :leave]`(Phase 2);per-Kind register subset(Session 接 send/join/leave;Agent/User 接 receive);Process.monitor + last_seen offline 状态机替代独立 pending queue | impl |
| **#89** | **MessageStore = chat history single source of truth**;Session.Chat state slice 仅 ephemeral 在线状态(members/online/last_seen/monitors);BEAM 重启历史保留 + 在线状态重置;rejoin 从 MessageStore.in_session_since 派生 replay(不维护 pending) | impl |
| **#90** | **Agent Kind 动态 spawn 机制(Phase 2)**:bridge announce → controller spawn via DynamicSupervisor;agent_uri 由 bridge 自报(env `EZAGENT_AGENT_URI`);disconnect → terminate;Phase 5 `ezagent_plugin_cc` 升级时 wholesale replace | impl |

**ARCHITECTURE.md §3.5 微调**:Message struct 文本写 5 字段;Phase 2 实施加 `uri` 第 6 字段(identity reference)。架构师可在 §3.5 末尾加 note:"实施期 Decision #88:`uri` 字段在 `Ezagent.Message.new/3` 时 UUID 生成,identity invariant 锁原 5 字段不变。"

具体编号留架构师本侧定夺,可能跟 Phase 1 后他自己加的其他 entries 撞;实施期完成后跟 Allen sync。

---

## 验证流程的 user-action 显式列(memory `feedback_flag_user_assist_steps`)

Phase 2 在以下 step 必须 USER ACTION REQUIRED,**spec / VERIFICATION / /goal 文本都显式标**:

| Step | User action | 原因 |
|---|---|---|
| 2c-step 3 启动 e2e 前 | Allen 在另一终端跑 `bash scripts/cc-bridge-attach.sh` interactive | 需要 PTY 真 claude session;agent 不能 silently spawn 跟 user 用一个 TUI |
| 2c-step 3 offline 验证 | Allen Ctrl-C 该 claude TUI | 物理操作,无法 agent 远程触发 |
| 2c-step 3 rejoin 验证 | Allen 重跑 attach script | 物理重启,跟 step 1 同 |

**Agent 行为约定**:遇到这些步骤时 — Feishu **明确停下来报告**,不 silently proceed 或 scope down。等 Allen 回来介入后再 continue。
