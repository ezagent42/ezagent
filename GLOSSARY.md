# GLOSSARY.md

Ezagent 项目的**单一真相源**(single source of truth)for:

1. **Decision Log** — 累积所有架构决策(v0.1 → v0.4,#1-#83;实施期持续 append,#84-#155)
2. **术语表** — Ezagent domain 词汇定义
3. **易混淆词表** — 跟外部世界同名概念的消歧 convention

本文件由 Allen + 工程师共同维护。实施期每产生新的架构决策 → append 到 Decision Log;每新增 domain 词汇 → 加进术语表;每发现跟外部世界的命名碰撞 → 加进易混淆词表。

---

## 0. 怎么用本文件

- **查决策为什么这么定** → §1 Decision Log,按编号或主题搜
- **不确定某个词在 Ezagent 里啥意思** → §2 术语表
- **写文档 / 代码碰到易混淆词** → §3 消歧表 + convention
- **实施期产生新决策** → append 到 §1,编号递增

每条 Decision 包含: 编号 / 决策内容 / 时期(v0.1/v0.2/v0.3/v0.4/impl)。具体论证回 `ARCHITECTURE.md` 对应章节,本文件只列简要表述方便快查。

---

## 1. Decision Log

按讨论顺序累积(v0.1 → v0.2 → v0.3 → v0.4 → 实施期):

| # | 决策 | 时期 |
|---|---|---|
| 1 | **Kind = Class** — 系统所有可寻址实体是 Kind 实例,Kind 跟 OO Class 等价;URI 是 instance ID;`Ezagent.<Category>.<KindType>` 模块定义 Kind | v0.1 |
| 2 | **Behavior** — Kind 上的能力切片,跨 Kind 复用;每个 Behavior 拥有 state slice + invoke/4 | v0.1 |
| 3 | **Invocation 中心化** — 一切 actor 间通信走 `%Invocation{target, action, args, mode, ctx}`,无第二条路径 | v0.1 |
| 4 | **CapBAC** — capability-based access control(struct,不是字符串);每个 Invocation 在 ctx 携带 caps;dispatch step 5.5 检查 | v0.1 |
| 5 | **5 个 mode** — `:call` / `:cast` / `:call_stream` / `:subscribe` / `:introspect`,有限集不可扩 | v0.1 |
| 6 | **URI scheme 集合** — `agent://` / `user://` / `session://` / `workspace://` / `resource://...` 等,scheme 决定 Kind 类型 | v0.1 |
| 7 | **3 个 Kind 子类** — Session(routing context owner)/ Entity(Principal, 持 cap)/ Resource(被操作,无 cap) | v0.2 |
| 8 | **@interface 是 SSOT** — Behavior 声明 `@interface` 含 args/returns/errors/modes;所有 UI(LiveView/CLI/HTTP/MCP)从它派生 | v0.2 |
| 9 | **不变量:Session 是 routing context owner** — chat/IM 系统的 channel,RoutingRules 挂在 Session 上 | v0.2 |
| 10 | **Phoenix as transport, not fullstack** — 用 Endpoint/Socket/Channel/PubSub/Presence/Plug;不用 Controller/View | v0.2 |
| 11 | **少发明多装配** — 判断标准:新人记多还是少;ezagent_core 是 thin convention layer + glue | v0.2 |
| 12 | **Cross-cutting Behavior** — 通过 attach 注入(audit、logging),不修改 Kind 模块 | v0.2 |
| 13 | **Adapter pattern** — 所有外部 transport(Feishu/Slack/CC/Web)是 Adapter;Adapter 不允许有业务语义 | v0.2 |
| 14 | **PubSub 用于不确定旁观者**(view 渲染、telemetry),dispatch 用于确定 receiver | v0.2 |
| 15 | **ctx.reply 路由表** — Invocation 结果按 ctx.reply 字段路由(phoenix_channel / webhook / mcp_response / none) | v0.2 |
| 16 | **state_slice 隔离** — 每个 Behavior 只能读写自己声明的 slice,不能越界 | v0.2 |
| 17 | **Plugin = OTP application** — no DSL,纯 convention;mix.exs 标准依赖管理 | v0.2 |
| 18 | **Kind 实例化策略** — Session 是 ephemeral GenServer(任务结束 terminate),Entity 是 long-lived,Resource 是 lazy GenServer | v0.2 |
| 19 | **Cap 三档 scope** — `:instance` / `:kind` / `:all` | v0.2 |
| 20 | **Plugin 注册自己的 Kind** — Plugin 启动时 `BehaviorRegistry.register/3`,无中心化配置 | v0.2 |
| 21 | **Behavior 是 plugin,不是 core** — `Ezagent.ActionSet.*` 全是 plugin(标准 Behavior plugin 集合),core 只提供 behaviour 契约 | v0.3 |
| 22 | **具体 Kind 是 plugin** — `Ezagent.Entity.Agent` / `Ezagent.Resource.Workspace` / `Ezagent.Session.*` 都是 plugin,不是 core | v0.3 |
| 23 | **Cross-cutting 通过 attach API** — `Ezagent.BehaviorRegistry.attach(Kind, Behavior, slice)`,无 mixin | v0.3 |
| 24 | **Identity Behavior 标准化** — `Ezagent.ActionSet.Identity` 是所有 Entity Kind 的基础 Behavior(handle/caps/inbox) | v0.3 |
| 25 | **Chat Behavior 标准化** — `Ezagent.ActionSet.Chat` 处理 Message 收发,跨 Session/Agent 复用 | v0.3 |
| 26 | **Message 是 core 概念** — `%Ezagent.Message{}` 在 ezagent_core 定义,Message routing 不专属 chat plugin | v0.3 |
| 27 | **Snapshot 持久化策略 4 选** — `:on_change` / `:periodic` / `:on_terminate` / `:ephemeral` / `:external` | v0.3 |
| 28 | **RoutingRegistry plugin 自声明 tables** — core 不预定义任何 table,plugin 在 Application.start/2 里 `declare_table` | v0.3 |
| 29 | **CapBAC step 5.5 in dispatch flow** — 每次 invocation 必经 cap 检查,核心权限 gate | v0.3 |
| 30 | **三档 cap scope** — instance(`uri`)/ kind(`module`)/ all(`:*`) | v0.3 |
| 31 | **Behavior unit testing** — 纯函数 invoke/4 可直接测,无需 mock | v0.3 |
| 32 | **OSProcess Behavior** — pty / 外部进程通过 erlexec wrapped,统一 Behavior 接口 | v0.3 |
| 33 | **Webhook plug** — Plug 作为 webhook 入口,构造 Invocation,走标准 dispatch | v0.3 |
| 34 | **REST AdminAPI 走 Plug** — admin 操作不是 LiveView,是 Plug + JSON | v0.3 |
| 35 | **WebSocket adapter** — `Ezagent.Web.UserSocket` (公开)+ `Ezagent.Web.AdminSocket` (内部)分两 socket | v0.3 |
| 36 | **三种 transport 全 first-class** — WS / stdio / MCP via channel,没有"主"和"次" | v0.3 |
| 37 | **RoutingRegistry core 不预定义 table** — plugin 自声明 + 自维护 | v0.3 |
| 38 | **`Ezagent.Capability` struct, not string** — 老 esr 字符串 cap 撞 typo 事故;新版用 struct + 严格 matcher | v0.3 |
| 39 | **5 个 mode 是有限集** — 不允许新 mode,要扩展用 ctx 字段 | v0.3 |
| 40 | **Behavior state_slice 是 map** — 不是 struct;运行时灵活,持久化 JSON-friendly | v0.3 |
| 41 | **Routing rules additive** — 已加路径不会因新增 rule 被消除,除非显式 revoke;`always() → A` + `mention(B) → B` 时 @B → A 和 B 同时收到 | v0.3 |
| 42 | **Matcher AST 可序列化** — RoutingRegistry 存 matcher_data,运行时反序列化求值 | v0.3 |
| 43 | **Invocation flow 9 步标准化** — Appendix A 详述,plugin 作者不需要看 | v0.3 |
| 44 | **LOC budget 显式化** — ezagent_core target ~580 LOC(v0.3 数字,后被校准);每模块 hard ceiling;超 cap 触发设计 review | v0.3 |
| 45 | **持久化 F+G 全 Phoenix 原生** — Ecto + SQLite BLOB / S3 via `req_s3`;无新外部依赖 | v0.3 |
| 46 | **SQLite 是唯一数据库** — 不双轨;Postgres 不在 v0 spec | v0.3 |
| 47 | **`:oban` 移除** — snapshot / DLQ / drain 用 `Process.send_after/3`;~15 LOC Ezagent.Scheduler;BEAM 原生足够 | v0.3 |
| 48 | **Federation 形态 A 确认** — 独立节点 + cross-node 协议;v0 不实现,share-nothing 持久化 / URI / CapBAC 已留接口 | v0.3 |
| 49 | **LiveView IM dogfood + CLI 写入 spec**(Appendix D),让 spec 读者直观感受系统怎么用 | v0.3 |
| 50 | **Ezagent 不内置通用 MCP server** — 内嵌 BEAM agent 直接调 Elixir API,Python adapter 走 WS;唯一 MCP 集成是 CC Channel | v0.3 |
| 51 | **CC Channel = Ezagent ↔ CC 桥** — 反向 MCP push 模型(不是 LLM pull tools);双向 | v0.3 |
| 52 | **`ezagent_plugin_cc` 单 plugin 含两侧组件**(Elixir adapter + Python channel server)统一发布 | v0.3 |
| 53 | **CC Channel 实现语言:Python 优先**(复用现有 esr),Bun 备选 | v0.3 |
| 54 | **Adapter driver 关系两种** — Ezagent-driven(Feishu/Slack,OSProcess 拉起)与 external-driven(CC Channel,CC 用 `--channels` 拉起) | v0.3 |
| 55 | **单层鉴权模型** — WS connect 验 token(身份)+ Invocation 验 cap(权限);Channels 协议的 sender allowlist / pairing 不使用 | v0.3 |
| 56 | **`ezagent_plugin_cc` vs `ezagent_plugin_cc` 独立 plugin** — 本地 pty vs 外部桥接,两者并存 | v0.3 |
| 57 | **LiveView IM 不限于 dogfood** — v0 期内部 IM 验证 spec,v0 之后作为产品 web 入口,跟 Feishu/Slack/CC channel 并列 | v0.3 |
| 58 | **LiveView ↔ CLI 同构映射** — 两侧 UI 都从 `@interface` 自动派生;`/agent:set-default A` ↔ `esr agent set-default A` 等价 | v0.3 |
| 59 | **`:on_change` 触发时机:slice 真变了才写**(`new_slice != old_slice`),不是 invoke 后都写;BEAM 不可变 + 值比较自然给出正确语义 | v0.3 |
| 60 | **Audit log 异步写入** — `:telemetry` handler 只 `GenServer.cast` 到 `Ezagent.Audit.Writer`;Writer 内 batch + 100ms flush;不用 Oban | v0.3 |
| 61 | **顶层加 "Ezagent 是 router 不是 req/resp app" framing** — 4 个 P1/P2 设计动作的共同根 | v0.4 |
| 62 | **"持久化层存了代码引用"为第二条 framing** — `type_name` 稳定 ID 间接层,模块改名时映射改一处 | v0.4 |
| 63 | **Resource Kind "shared referent needs identity"** — 任何被多方按身份引用的命名锚点都需要独立身份;Workspace 是示范 | v0.4 |
| 64 | **Template 升级双层模型** — Class(模块级,开发者写)+ Instance(运行时 Resource Kind,用户创建);Workspace 是 Template Instance 代表性例子 | v0.4 |
| 65 | **RoutingRegistry 加 `put_new` 语义**(unique-key only)+ duplicate-key 表用 `put` | v0.4 |
| 66 | **`use Ezagent.Kind` 宏强制生命周期** — register→subscribe→announce_ready 严格三步,plugin 作者无法绕过 | v0.4 |
| 67 | **`:call` to not-ready actor 必须 fail-fast,不能 buffer** — caller 同步阻塞,buffer 撞 deadline_ms | v0.4 |
| 68 | **零匹配路由 telemetry + DLQ unroutable** — 不能静默;Ezagent router 必须人工造可观测性 | v0.4 |
| 69 | **Idempotency ETS 模块** — bounded LRU,ctx 带 `idempotency_key`,dispatch step 2.7 自动检查 | v0.4 |
| 70 | **Matcher 边界按"读 core 数据"画线** — Message-field matcher 全在 core;读 plugin 专属 payload 才在 plugin | v0.4 |
| 71 | **Plugin 判定原则显式化(§2.2)** — 读 core 数据 → core;读 plugin 专属 → plugin;通用 invariants → core | v0.4 |
| 72 | **LOC 预算校准 595 → ~870** — dev review 实测扎实;invocation/matcher/kind 上调;新增 reliability 4 模块;red line 1100 | v0.4 |
| 73 | **feishu-cc 切片 3 张参考表入 spec(§10.7)** — ChatRouting / PrincipalMapping(unique, put_new)+ SessionRules(duplicate, put) | v0.4 |
| 74 | **Routing 迁移分诊规则**(§17.12) — 1722 行不一次性迁;偶然复杂度蒸发;真实业务重新表达;feishu-cc 切片优先 | v0.4 |
| 75 | **inbound 永远走 dispatch,绝不裸 `PubSub.broadcast`** — 升级为 §5.7.6 硬不变式;Phoenix.PubSub 不 buffer 没订阅者的 topic | v0.4 |
| 76 | **Idempotency v0 语义:收到即记,不是成功才记**(§5.7.3) — 失败走 DLQ;事务化"成功才记"超出 v0 复杂度预算 | v0.4 |
| 77 | **Event Sourcing 不做** — 从 deferred 改成已决不做;append-only Message stream 已具备 ES 真实好处 | v0.4 |
| 78 | **`SessionBindings` 作为 v0.4 第 4 张参考表**(duplicate-key)+ RoutingRegistry 加 `reverse_index` 可选反查 | v0.4 |
| 79 | **LOC cap 总和 > red line 是预期** — cap 是单模块异常天花板,red line 是实测合计触发器,两个独立信号 | v0.4 |
| 80 | **sub-step 是 /goal 内部 e2e gate,phase 才是 Allen review 单元** — 行为正确性自动化 + 架构判断人工拆开;VERIFICATION.md 先于 PLAN.md 写 | v0.4 |
| 81 | **`user://admin` bootstrap principal,持 all-caps 不可 revoke** — 结构性 invariant 集中在 `Ezagent.Capability.revoke/2`;Phase 1-3c LiveView/CLI 默认 `ctx.caller = user://admin` | v0.4 |
| 82 | **authz stub 带 `:stub_grant` telemetry 防"顺手简化"** — Phase 1 永远 grant + emit telemetry;Phase 3d in-place 替换为真实检查 + `:granted`/`:denied` | v0.4 |
| 83 | **§14 LOC budget round-2 校准** — `message_store.ex` 之前漏列;补进清单 ~50 LOC;target 870 → 920;red line 1100 → 1150 | v0.4 |
| 84 | **Phase 1 采用路径 B(`@behaviour Ezagent.Kind` + 共享 `Ezagent.Kind.Server`)** 不用宏 — register→subscribe→announce_ready property 等价 Decision #66 但 means 不同;共享 Server 把 Kind 隔离从 compile time 推到 runtime;`Ezagent.Kind.Runtime.handle_dispatch/3` 必须 defensive 处理多 Kind state shape;Phase 1 接受 trade-off 因为只有 Echo 一个业务 Kind;Phase 2+ 若 state shape 假设冲突再评估(详见 ARCHITECTURE.md §5.7.4) | impl |
| 85 | **`.claude/` 暂用 plain dir 不 vendor+submodule**(Phase 0 实施期决策)— 短期符合"少发明多装配"+ 镜像老 esr 实际结构;trigger 迁 vendor: (a) 出现 skill 需要 upstream 更新需求,或 (b) Phase 5 完成后整理 tech debt | impl |
| 86 | **CC channel 协议层简化:Channel = MCP server + 1 capability**(Phase 1b 实证)— v0.3 §12.8 之前假设 channel 是独立通信协议(独立 server 进程 + 类似 WebSocket 的 wire),Phase 1b 发现 Channels 是 MCP 协议扩展(`capabilities.experimental['claude/channel']` + `notifications/claude/channel` + 标准 MCP tools/call)。`ezagent_plugin_cc_bridge_v1_prototype` ~250 LOC Python。**LOC 对比的诚实表述**:老 esr `cc_channel_runner`(973 LOC)和 cc-openclaw `channel_server`(4164 LOC)包含 channel 之外功能(多 session / persistence / permission relay 等),直接拿 4164 vs 250 对比是**不公平的**;**协议层简化是真的**,LOC 简化幅度模糊。Phase 5 `ezagent_plugin_cc` 走简化路径(详见 ARCHITECTURE.md §12.8) | impl |
| 87 | **`--dangerously-load-development-channels server:<name>` 需要项目根 `.mcp.json`**(per-operator,gitignored,通过 `git rev-parse --show-toplevel` 锚定)— 否则 claude 启动期 lookup 失败打印 warning;`--mcp-config <abs>` 只读 session-level,**不**满足 dev-channels lookup。`Ezagent.Bridge.V1Prototype.McpConfigWriter.write!/0` 同时写 session-level 和 project-level | impl |
| 88 | **K-path Behavior 模型**(Phase 2 落地 Decision #61)— 一个 Behavior 模块同时挂在多个 Kind 上,每个 Kind 通过 `BehaviorRegistry.register(kind, action, behavior)` 注册自己消费的 **action subset**(Chat: Session→send/join/leave, User+Agent→receive)。`Kind.behaviors/0` 从"action 路由权威"降级为"`init_slice` 用的列表",真正权威是 BehaviorRegistry per-Kind 表。User Kind 可以 `behaviors() = []` 但仍接收 `:receive` 分发(实现细节见 `apps/esr_plugin_chat/`)。这是 plugin isolation 北极星的核心原语:加新 Behavior(语音/file 等)不动 Kind 模块 | impl |
| 89 | **`Ezagent.Kind.Server.handle_info/2` 统一 Behavior 消息转发器**(新合约面)— 任何非 dispatch 入站(Process.monitor `:DOWN`, bridge `send/2` 回调, 未来 timer tick 等)都进 Kind.Server 单 mailbox,转发到每个 composing Behavior 的可选回调 `handle_kind_message(message, slice, ctx)`,返 `{:ok, new_slice}` 或 `:ignore`。Kind.Server 仍完全不感知任何业务 Behavior。Phase 2 Chat 用这个 hook 实现 offline 状态机(:DOWN→last_seen)和 bridge→Agent reply 回路。在 §5.7.4 Kind.Server 节增补合约 | impl |
| 90 | **`ctx.kind_module` + `ctx.self_uri` 在 Kind.Runtime 注入**(Invocation flow 增补)— Behavior 跨 Kind 时(Chat 的 :receive 要分支 User vs Agent / Session 的 :send 要 broadcast topic 含自己 URI)需要这两个值,Phase 1 没有。Kind.Runtime.handle_dispatch/4 在 `invoke_behavior` 前单点 `Map.put` 注入,plugin 作者永远不需要手 plumb。`Invocation.ctx` type spec 同步:这两 key 是 runtime-injected,Behavior 内可见,adapter 构造 Invocation 时不需要填 | impl |
| 91 | **MessageStore 为聊天历史的单一真相源**(Phase 2 P2-D3)— Session.Chat slice 只持 ephemeral 在线状态(members/monitors/last_seen),offline 期消息从不维护 pending queue;rejoin 时通过 `MessageStore.in_session_since(session_uri, last_seen[uri])` 派生 replay 集,SQL `LIMIT 1000` 兜底超长 backlog。理由跟 memory `feedback_converge_to_uri_list` 同源(可派生的不该独立维护)。详见 `apps/ezagent_core/lib/esr/message_store.ex` | impl |
| 92 | **`InterfaceValidator` 加 `:uri` primitive**(§6.2 type-spec 语法扩展)— Chat 的 `@interface` schema 声明 `sender: :uri, mentions: {:list, :uri}` 等典型 URI 字段,validator 在 dispatch 边界要求 `%URI{}` struct,**拒绝裸字符串**。配合 `Ezagent.Ecto.URI` 自定义 Ecto type 实现 URI 跨进程/跨持久化层都是 struct,序列化/反序列化由专门 type 处理 | impl |
| 93 | **`session://` URI scheme + 两条新 PubSub `:events` 通道**(§3.5 URI types + §5.7.6 topic taxonomy 扩展)— Phase 2 新增 `session://` 作为 Kind URI scheme(Session Kind 用)。`esr:session:<uri>:events` 用于 chat stream 订阅(消息/成员变更/online-offline)+ `esr:user:<uri>:events` 用于个人 inbox 通知。两个 topic 都是 §5.7.6 的 view fan-out 合法用法(已加入 `check_invariants` #1 allowlist) | impl |
| 94 | **Bridge↔Agent dual map**(v1_prototype 实现层模式,Phase 5 channel 重写时复用)— `Ezagent.Bridge.V1Prototype.Server` 同时维护 `bridge_to_agent: %{bridge_id => pid}` + `agent_to_bridge: %{agent_uri_str => bridge_id}`。出站(Agent.invoke(:receive) → claude)用 `bridge_for_agent/1`;入站(claude reply tool → Agent)用 `forward_reply_to_agent/2` 找 pid → `send/2`。模式本质:wire-id 和 business-URI 解耦,routing 层不感知 wire 协议。Phase 5 ezagent_plugin_cc 重写时延续此模式 | impl |
| 95 | **RoutingRegistry 作第 3 个 Registry 家族 + owner-pid check**(Phase 3a 落地 Decision #28/#37/#65)— `Ezagent.RoutingRegistry` 跟 `KindRegistry`(URI→pid,boot 时 register)/`BehaviorRegistry`(boot-only 注册,last-writer-wins OK)并列;独有 **owner-pid check**(declare_table 时记 owner,只该 pid 能写)— 因为 admin 是**运行时**写 routing rules(`mix ezagent.routing.add_rule` / Phase 4 LV 表单),不像 BehaviorRegistry 是 boot-only。Plugin X 不能 stomp plugin Y 的 routing table。详见 `apps/ezagent_core/lib/esr/routing_registry.ex` moduledoc 三者对比表 | impl |
| 96 | **Matcher AST 5 leaf + JSON serde**(Decision #41/#42/#70 落地)— `Ezagent.Routing.Matcher` 5 个 leaf(`mention/from/text_contains/text_matches/always`);plain tuple 形态(`{:mention, "agent://X"}`)无 macro;`to_json/1` + `from_json/1` 让 matcher 进 SQLite `routing_rules.matcher_data` 列。组合子(and/or/not)Phase 4+(P3-D3 决定单层规则 + 多条规则 additive 已覆盖 demo 场景)| impl |
| 97 | **Resolver 双层 fan-out:cross-session 走规则 + in-session 走 members fall-through**(P3-D impl 决策 b)— `Chat.invoke(:send)` 先调 `Ezagent.Routing.Resolver.resolve/2` 拿 cross-session targets,再 always 加上 in-session members(`Map.keys(slice.members)`)— 同一条 message 同时落本 session 成员 + 走规则到其他 session。Recursion guard:不 re-dispatch 到 current session。这是 router 真正能让"在 main 发的 urgent 消息**同时** 落 oncall"工作的关键 | impl |
| 98 | **`message_routings` 关联表保 Decision #40 identity invariant + 多 session 持久化**(#P1-4 spec review 修复)— Phase 2 `messages.uri` 是 PK,Phase 3 D8 reply 可同时 target N 个 session → PK 冲突。新 `message_routings` 复合 PK `(message_uri, session_uri)`:`messages` 保 1 行/uri(identity invariant 不破),per-session 路由信息走 routings 表。`MessageStore.write/2` 内 transaction upsert messages + insert message_routings。新加 `MessageStore.sessions_for_message/1` 给 ref/session_uris 一致性 soft warn 用 | impl |
| 99 | **Identity Behavior in slice + admin_caps 注入 init_slice**(Phase 3d step 1 / Decision #24 落地)— Phase 1-2 admin_caps 是 `Ezagent.Entity.User.admin_caps/0` module function 硬编码常量。Phase 3d 加 `Ezagent.ActionSet.Identity`(`@callback init_slice/1` 读 `args[:initial_caps]`,默认空 MapSet)+ User Kind.behaviors 加 Identity。chat plugin Application spawn admin User 时传 `kind_server_spec(:user_admin, User, admin_uri, %{initial_caps: User.admin_caps()})`(per #B1 — kind_server_spec/4 加 extra_args 参数)。caps 现在在 `:sys.get_state(admin_user_pid).state.identity.caps` 可观测 | impl |
| 100 | **`Ezagent.Capability.cap_for_action/3` helper**(#P1-8)— dispatch step 5.5 需要的 "action → cap_needed" 反查,签名加 `target_uri`(必填)以从中提取 `instance`(via `Ezagent.URI.instance/1`)。返 `%{kind, behavior, instance}` 喂 `matches?/2`。`behavior` 从 `BehaviorRegistry.lookup(kind_module, action)` 拿,缺失则返 `:unknown`(caller 决定 deny vs skip)| impl |
| 101 | **Phase 3d hard flip:`:stub_grant` 永久死亡 + check_invariants #9 #10 invariant test gate**(P3-D6 落地)— `Ezagent.Kind.Runtime.handle_dispatch` step 5.5 的 `authz_stub/4` 函数**整个删除**,替换为 `authz_check/4`(真 `Capability.matches?` + `[:ezagent, :authz, :granted]` / `:denied` telemetry)。`:stub_grant` atom 全 codebase 清空(per #B5:audit.ex/telemetry.ex/admin_live.ex 的字符串/atom 用法全改为 `granted/denied`)。**runtime invariant test**(`runtime_phase3d_test.exs`)真正构造 deny ctx → dispatch → 断言 `{:error, :unauthorized}` + `:denied` telemetry — 这是 invariant #10 的**语义 gate**(grep 只是 tripwire,per memory `feedback_completion_requires_invariant_test`)| impl |
| 102 | **Reply 契约 D8:`{session_uris: [URI], text, ref?}`** — Python bridge `reply` MCP tool 三字段;`session_uris` 是 list(claude 可一次回 N session,典型场景:跨 session 转发);`ref` optional(支持 proactive reply,无 inbound 触发也能 reply)。Agent.handle_kind_message 用同一 `%Ezagent.Message{}` envelope dispatch chat/send per session_uri(identity invariant — 配合 #98 message_routings)。ref + session_uris 不一致 emit `[:ezagent, :chat, :reply_session_mismatch]` telemetry 但**仍按 session_uris 路由**(soft warn,信任 claude 显式决定)| impl |
| 103 | **Bridge↔Agent floating (P3-D9 contract change) + LV @-dropdown 只列 session 成员**(real-claude e2e exposed)— Phase 2 bridge announce auto-join `session://main`;Phase 3 改为 spawn Agent Kind 但**不 join 任何 session**(floating),admin 通过 LV "Add to session..." dropdown 显式拉入。配合 LV 修复:compose 区 `@ agent` dropdown 只列 current_session_uri 的 members(不再列所有 KindRegistry agent://),空时显 hint "(no agents in this session — add one via Floating list)"。multi-agent demo 暴露的 UX 问题(@ floating agent 后 message 静默 drop)的根本修复 | impl |
| 104 | **push_to_claude meta 必含 `"session"` 字段 + reply dispatch failure 可见**(real-claude e2e hotfix)— `Chat.invoke(:receive)` Agent 分支构造 push_to_claude 的 meta 时**必须**包含 `"session" => URI.to_string(ctx.caller)`(`ctx.caller` 是 Session.dispatch_receive 设的源 session URI),claude 才能正确填 reply 的 `session_uris`。配合:`Chat.handle_kind_message` 在 dispatch chat/send 返 `{:error, _}` 时 emit `[:ezagent, :chat, :reply_dispatch_failed]` telemetry(以前静默 drop,real-claude 测试时把 reply 发到 `session://admin` 这种瞎猜的不存在 session,完全丢失) | impl |
| 105 | **admin_live Phase 4a 拆分用 Phoenix.Component**(stateless)而非 LiveComponent(Phase 4 D2 推荐)— Phase 4 D2 原话推 LiveComponent,但 admin_live 状态紧耦合(session 选择驱动 chat + members + sidebar),LiveComponent 的 `send_update` 跨组件协调比直接 parent assign 多绕一层。Phoenix.Component 拿到 file-boundary split(主目标 — 让 4b/c/d 新增 surface 进新文件,不进 admin_live),不付协调成本。`apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin/{sessions_sidebar,chat_window,member_panel,debug_panel}.ex`(40-140 LOC each)。promote 到 LiveComponent 推迟到具体 surface 真需要 own state | impl |
| 106 | **Workspace Kind + Behavior lives in ezagent_core**(Phase 4b 落地 Decision #64/#70)— Workspace 是所有 plugin 用的基础概念,放 plugin 会引入循环依赖(chat plugin 用 Workspace 声明 Session 模板,但 Workspace 需要先存在)。`Ezagent.Entity.Workspace` 跟 `Ezagent.Entity.User` 平等都在 ezagent_core;`EzagentCore.Application.start` 注册 Workspace Behavior 的 9 个 action(第一次 EzagentCore 注册 Behavior,但 Workspace 是 cross-plugin 基础)。`Ezagent.Workspace.Supervisor` DynamicSupervisor 也在 EzagentCore.Application children | impl |
| 107 | **Workspace Behavior `:instantiate` 返回 children 数据,不做 side-effects**(Phase 4 D5 落地)— plugin isolation 在 boundary:ezagent_core 不知道哪个 plugin 拥有哪个 Kind 的 supervisor。`:instantiate` 返 `{:ok, slice, %{children: [{:member, URI}]}}` 纯数据;Loader(Phase 4c)walk 列表 + call `Ezagent.SpawnRegistry.spawn/1`。这是 Decision #70(Workspace 薄 Resource 形态)的运行时落地 — "薄"意味着行为是 declarative + 实际 effect 由调用者注入 | impl |
| 108 | **`Ezagent.SpawnRegistry`:URI scheme → spawn fn 的 ETS 表**(Phase 4c 新增 plugin DI 原语)— plugin Application 在 `start/2` 调 `Ezagent.SpawnRegistry.register("agent", fn uri -> ... end)`。chat plugin 注册 `agent`/`session`/`user` 三个 scheme。Loader 看 `agent://cc-builder` 时 lookup `agent` scheme → call 注册的 fn,**ezagent_core 永远不引用 `EsrPluginChat.AgentSupervisor`**。`spawn/1` 先看 `KindRegistry.lookup`(idempotent re-spawn safe)再 fall back ETS。这是 plugin isolation 北极星的 runtime DI 形态(同 #88 K-path Behavior 是 boot-time DI 形态)| impl |
| 109 | **Workspace 持久化分层:config 持久化(Store)≠ Kind state snapshot**(Phase 4 D7 落地)— Workspace Kind `persistence/0` 仍 `:ephemeral`;config(members/templates/routing_rules)经 `Ezagent.Workspace.Store` 写 SQLite `workspaces` 表(JSON-text 列,SQLite 无 native JSON column);Loader 从 DB rehydrate live Kind。per-Kind state snapshot(运行时 slice 状态)是不同概念,推 Phase 5+(SnapshotStrategy framework)。混淆这两个会让 restart 慢且脆 | impl |
| 110 | **Workspace facade dual-write 模式**(Phase 4c 落地)— `Ezagent.Workspace.add_member/2` 等 mutation 先 `Store.update_members`(durable DB)再 `dispatch(:add_member)`(live Kind)。两步**非事务**:crash 后 Loader 在下次 boot 用 DB 状态重建 live Kind,**Loader 是 resync 真相**。read 走 live Kind only(`list_members` 等)— DB 是 recovery snapshot,不是 read source。Phase 5 可能 wrap transactional path 但 v0 接受简单实现 | impl |
| 111 | **Phase 4 plugin-isolation invariant test**(Phase 4 D10 落地 — 完成 gate)— `apps/ezagent_core/test/integration/plugin_isolation_workspace_test.exs` 内联 `ProbeKind` + `ProbeBehavior`(**NOT in lib/**),运行时 `SpawnRegistry.register("probe", ...)`,持久化 Workspace declares `probe://invariant-N` member,`DynamicSupervisor.terminate_child` 模拟 restart(不是 `Process.exit` — 那会触发 `:one_for_one` 立刻 re-spawn,模拟错),`Loader.load_all/0` re-spawn probe,断言 **new pid** alive。Per memory `feedback_completion_requires_invariant_test`:Phase 4 不可单凭 tests-pass + merge 宣完成 — 这是架构 gate | impl |
| 112 | **Plugin Application 启动尾巴 call `Loader.load_all/0`**(Phase 4c boot 顺序约定)— Loader 必须 AFTER plugin 已注册 schemes 才能跑。`EsrPluginChat.Application.start` 在自身 bootstrap(register_chat_behaviors + admin User join + DefaultRules)完成、register_spawn_fns 注册三个 scheme 后,在 start callback 尾巴 call `Ezagent.Workspace.Loader.load_all/0`。当前依赖**Application 启动顺序**(chat plugin 是最后启动的 plugin)。Phase 5 可能改为显式"all-plugins-ready" gate 或 release-time bootstrap script | impl |
| 113 | **admin_live `PHASE4-SPLIT-FIRST` marker 注释 + 兑现机制**(Phase 4 工程流程)— PR #8 在 admin_live 顶部加 13-line 注释 block 声明"Phase 4 必须先拆分再加新功能";Phase 4a(PR #9)真拆;Phase 4d(PR #12)Workspace UI 不塞 admin_live 而是独立 `/admin/workspaces` route 验证 marker 起作用。模式:pre-commit marker + 后续 PR 兑现 + closeout 验证。可推广到其他"将要溢出"的模块(预备 LOC red line 触发器之外的早期预警机制)| impl |
| 114 | **Template Class behaviour + TemplateRegistry**(Phase 4-completion PR 1)— `Ezagent.Kind.Template` 3 callbacks + `Ezagent.TemplateRegistry` ETS strict-on-duplicate;`Ezagent.Workspace.add_template/3` 调 Class.validate 失败 fail-fast;Workspace `:instantiate` 现在返 `{:member, URI}` + `{:template, name, data}` 双类型 children,Loader 分别调 SpawnRegistry 或 TemplateRegistry;`Ezagent.Template.GenericSession` 在 chat plugin = 首个 concrete Class | impl |
| 115 | **Snapshot per-Kind 真 r/w + 5 strategies finalized**(Phase 4-completion PR 2)— `Ezagent.Kind.Snapshot` 真 SQLite r/w via `:erlang.term_to_binary`(lossless;JSON 丢失 MapSet/URI/DateTime);5 strategies live:`:ephemeral` / `{:snapshot, :on_change}` 同步 / `{:snapshot, :periodic, ms}` async via Writer / `:on_terminate` GenServer.terminate hook / `:external` skip。Q3 default:write 失败 log+telemetry+continue(let_it_crash 不适用 disk-full);Q5:added Behavior 时 `Map.merge(fresh, loaded)` 保 new slice fresh init。`Audit.@events` 加 `:persistence` 三件;Agent flip `:on_terminate`。Invariant gate:`snapshot_restart_test.exs` "spawn + grant + restart 后 caps 仍在" | impl |
| 116 | **CLI 自动派生 via Optimus + FacadeRegistry**(Phase 4-completion PR 3,Decision #58 落地)— 新 app `apps/ezagent_cli/`(Optimus dep 隔离 in ezagent_cli 不污染 ezagent_core)。`TreeBuilder` walk BehaviorRegistry + FacadeRegistry 构造 Optimus 树;`Coercion` interface 类型→Optimus parser;`Dispatch` parsed→Invocation+reply receive;`Formatter` stdout+exit code。`FacadeRegistry` 是 BehaviorRegistry 对称 peer(Spec 02 Q-A option c)— plugin 注册非-action ops(`workspace create`)。**Invariant gate**:inline ProbeKind/Behavior 在 test/(NOT lib/)+ BehaviorRegistry.register → `mix esr probecli do_thing` 自动 work,无 Mix.Tasks 模块 | impl |
| 117 | **Multi-user provisioning + login flow**(Phase 4-completion PR 4-5,Spec 05 Part A)— `Ezagent.Users` 独立 SQLite 表(separate from User Kind snapshot,Q-MU-2);`Ezagent.Capability.Parser` 字符串→ caps 文法;`mix ezagent.user.create` + `set_password` tasks;**controller-rendered `/login`(not LV — 避免 WS 依赖)**;`EzagentWeb.Plugs.RequireUser` gate `/admin/*`;`Ezagent.Identity.list_caps_for/1` self-grant 解 chicken-egg。`AdminLive.mount` 从 session cookie 拿 caller URI/caps;`ctx(socket)` 替代 hardcoded admin。`:unauthorized` LV flash 友好化 | impl |
| 118 | **Matcher 组合子 and/or/not**(Phase 4-completion PR 6,Decision #41 deferred 落地)— `Matcher` 加 3 AST tuple + 构造器 `all_of`/`any_of`/`negate`(`negate` 避 `Kernel.not` 碰撞)+ Evaluator 递归 + JSON serde 递归。Backward compat:leaf-only DB 不变。空 and = vacuously true,空 or = vacuously false。`import Kernel, except: [match?: 2]` 解 Elixir 1.18+ shadowing | impl |
| 119 | **CC PTY plugin(简化版 wrap shell script)+ 3 关键 fix**(Phase 4-completion PR 8/8a/8b/8c)— **第一个非-chat plugin** 验证 plugin isolation 端到端。`PtyServer` erlexec `:pty` 包 `bash cc-bridge-attach.sh`;`Ezagent.PluginCc.Template` 实现 Template Class(`"cc.pty"`)。3 fix:(a)`:stdin` 选项必须 — 否则 child stdin EOF;(b)auto-confirm dev-channels dialog — detect ANSI-stripped buffer + `:exec.send "1\r"`;(c)`:exec.winsz(os_pid, rows=40, cols=120)` — claude TUI 阻塞等 TIOCGWINSZ;(d)cc_pty Application.start tail re-run `Workspace.Loader.load_all` — chat plugin 早跑时 cc.pty Class 未注册 boot-ordering 修复模式 | impl |
| 120 | **Routing consolidation: 4 leaks fixed + CI invariant gate**(Phase 4-completion PR 9,Allen 2026-05-16 反馈落地)— (a) `$session_members` magic 受体 token + Resolver 第三参 members,DefaultRules seed `always() → ["$session_members"]` system_default 规则,**Chat.invoke 移除硬编码 fan-out — Resolver 是 SOLE 决策源**;LV `/admin/routing` 渲染 "(dynamic: members of current session)" 让 hidden fan-out 可见。(c) migration 加 `source` + `enabled` 列,`RuleStore.delete/1` 拒绝 system_default,`disable/1` 是 admin opt-out 路径,`bootstrap` 检查 `has_system_default?`(不再 "table empty")— admin 删除后 restart 不被覆盖。(d) boot-ordering pattern documented(模式来自 PR 8c)。(b) per-rule cap 推 Phase 5。**Invariant**:`routing_consolidation_invariant_test.exs` "no rules + no members → no recipients" gate,任何未来 reintroduce hidden fan-out 立 fail | impl |
| 121 | **LV `ScrollOnUpdate` JS hook + auto-scroll**(Phase 4-completion PR 9 §UI)— Phoenix.LiveView.stream 默认不 auto-scroll。新 `ScrollOnUpdate` hook in `app.js` — stream update 后**仅当用户近底部 120px 内**才 scroll(读历史不被打断)。`admin/chat_window.ex` 的 `#messages` div 加 `phx-hook="ScrollOnUpdate"` | impl |
| 122 | **ExternalMirror Domain — Publisher + Adapter + Binding 三层模型**(Stream 2 PR-EM-0..FINAL 落地,SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`)— 任何把 Session slice 变化镜像到外部系统(Feishu chat / Slack / 游戏房间 / …)的需求都走这个 Domain,**不再每个 plugin 各做一套**。三层:**Publisher**(Session Kind 实现的 `@behaviour Ezagent.ActionSet.Publisher`,`subscribe_from/3` + `snapshot/1` + `history/3` + 100 events 环形保留)→ **Adapter**(stateless 模块,`event_to_payload/1` 纯函数 + `target_ownership_check/2` bind-time 唯一允许 I/O 的 callback + `cap_subject/0` 声明 per-adapter cap 形状)→ **Binding**(stateful per-target supervised GenServer,`init/1` + `publish/2` + `terminate/2`;Grill-5 一对一绑 Adapter)。**Worker Kind** `Ezagent.Entity.ExternalMirrorWorker` 在 `RootSupervisor → PerBindingSupervisor → Kind.Server` 两层 supervision 下;`WorkerSpawn.worker_uri_for/3` 是 deterministic + session-scoped(`entity://worker/<workspace>/em_<hash12>`)。`Ezagent.ActionSet.ExternalMirror` 在 Session 上挂 `:bind` / `:unbind` / `:list_bindings` 三个 action;**`Ezagent.ExternalMirror.bind/4` 是 facade**(Check 1 session bind cap + Check 2 per-adapter cap + Check 3 `target_ownership_check` 在 `Task.Supervisor.async_nolink` 内有时限,通过 **`FacadeNonceTable`**(`:protected` ETS,32 字节 crypto.strong_rand_bytes,5s TTL,绑定到精确 `(session, adapter, target, caller)` tuple)单次原子 handoff 到 dispatch action body — pre-fix 用 `args[:_facade_checks_ok]` 布尔 flag 被 caller 控制 args 转发可绕过 Check 2/3,nonce 修复该 forgery)。Per-binding 崩溃隔离 ↓ inner `PerBindingSupervisor` 3/30s budget + outer `RootSupervisor` 100/60s budget(r4 round-3 HIGH-2 fix);Worker 幂等性 via `WorkerRegistry` `:via, Registry` 在 binding_uri 上(r5 HIGH-3 fix)。**P11 escape closed**:bindings 永远走 `Publisher.subscribe_from/3` → Worker Kind 的 `:publish` dispatch → Adapter `event_to_payload` → Binding `publish/2`,**严禁 `Phoenix.PubSub.subscribe` 直连**(invariant test gate)| impl |
| 123 | **ApiKeys Behavior 从 User Kind 翻到 Agent Kind**(PR #389,2026-05-26)— per-agent 密钥让 agent cloning / templating 合理(clone 接收空 key slot,不是 creator 的 secret);credential 绑定到实际发起 HTTP 调用的 entity。`Ezagent.Entity.User.behaviors/0` 移除 `ApiKeys`;`Ezagent.Entity.Agent.behaviors/0` + `Ezagent.Entity.CurlAgent.behaviors/0` 加 `ApiKeys`。`required_caps/0` 用 `kind: :any` 单声明覆盖多 flavor。`:api_keys` slice 加 `:creator_uri` 字段。CurlAgent `:owner_uri` slice 字段删除 — agent 读自己的 key。**Load-bearing deadlock fix**:pre-flip `CurlAgent.invoke(:receive, ...)` dispatch `identity.get_api_key` 给 `ctx.self_uri` — flip 后 key 在同一 Kind instance 上 → `GenServer.call(self)` → `:calling_self` exit / 120s timeout。结构性 fix:新 `reads_sibling_slices/0` callback(见 #124)| impl |
| 124 | **`reads_sibling_slices/0` opt-in callback**(PR #389,2026-05-26)— 新 `Ezagent.ActionSet` optional callback `reads_sibling_slices/0 :: [atom()]`(默认 `[]`)。`Ezagent.Kind.Runtime.handle_dispatch/4` 注入 `ctx[:sibling_slices]` 仅包含声明过的 slice key(不是 generic `:all_slices` 全 map 旁路)。CurlAgent `:receive` 中 `ctx[:sibling_slices][:api_keys]` O(1) hash 读取避开自分发 deadlock。**Codex CRIT 闭环**:earlier round 用 `:all_slices` 是 secret-read escape hatch,被 strict opt-in scoping 替换 | impl |
| 125 | **`Capability.normalize!/2` chokepoint + 4-tuple identity**(PR #400,2026-05-26)— `grant_cap` CLI 传 JSON map(`%{"kind"=>"session","behavior"=>"Ezagent.ActionSet.ExternalMirror",...}`)被原样塞 slice → 后续 `Capability.matches?/2` BadMap 崩。新 `Ezagent.Capability.normalize!/2` 统一处理 struct / atom-keyed / string-keyed 三种输入。**Codex round-1 HIGH 闭环 3 件**:(a)`revoke_cap` 因 fresh `granted_at` 让 `MapSet.delete` no-op → 新 `Capability.identity_key/1` + `Capability.revoke/2` 用 `(kind/behavior/instance/workspace_uri)` 4-tuple identity 匹配(忽略 provenance metadata);(b)`from_map/1` 的 silent `:any` fallback 被 strict decoders 取代(raise on missing/unknown,bootstrap-admin 例外);(c)`IdentityAdmin.invoke(:revoke_cap, ...)` 委托给 `Capability.revoke/2` 走 bootstrap-admin guard | impl |
| 126 | **PTY/Python phase state machine + LV visibility**(PR #390,2026-05-26)— `Ezagent.Domain.Pty.Server` + `Ezagent.Domain.Python.Server` 持 `:phase` 字段(`:starting` / `:running` / `:dead`),每次 phase 转变 `Phoenix.PubSub.broadcast/3` 到 `"pty:phase:" <> URI.to_string(agent_uri)`。Sandbox(cc)+ NpAgent(np)Behavior 订阅 own URI,phase 入 slice 持久化到 snapshot。LV terminal page 加 "Starting…" / "Ready" / "Dead — Restart" badge。Per Allen 2026-05-26 directive:不要 atomic ensure-alive,let PTY 自己 phase-report,best-effort,**Allen 命名三档不增中间状态**。Codex round-1 HIGH(np Lifecycle 注册对称 cc)+ 2 MED(`Domain.Agent.subprocess_phase/1` flavor-aware facade;phase consumers 加 URI guard 防 PubSub 跨 subscribe boundary)全闭环 | impl |
| 127 | **PID-file orphan reaper(`Ezagent.Runtime.PidFile`)**(PR #388,2026-05-26)— 替代 PR #385 的 `ps -axEo pid,command` 扫描 + argv signature + env var parse 路径。新 core 层模块 `Ezagent.Runtime.PidFile`:`write/3` + `remove/2` + `enumerate/1` + `process_start_seconds/1`。文件路径:`<EZAGENT_HOME>/<profile>/pty-pids/<sanitized_deployment_id>/<plugin>/<sanitized_uri>.pid`,内容 `<os_pid>\n<start_epoch_seconds>\n`。`Ezagent.Domain.Pty.Server` + `Ezagent.Domain.Python.Server` spawn 后 `PidFile.write`,`terminate/2` 中 `PidFile.remove`(brutal kill 跳 terminate → file 留盘等下次 boot reap)。`EzagentPluginCc.OrphanReaper` + `EzagentPluginNp.OrphanReaper` 重写:`PidFile.enumerate/1` 自己 deployment 的 pid-files,检 `process_start_seconds` 验 PID 复用,SIGTERM 命中。**Friendly-fire 结构性不可能**:per-deployment subdir 隔离 parallel BEAMs,一 deployment 看不到另一 deployment 的 pid-files。原 `EZAGENT_DEPLOYMENT_ID` env tag 降级为 informational(operator 用 `ps -axE` 调试用)| impl |
| 128 | **cc/np 子进程 orphan-on-restart 结构性修复**(PR #385,2026-05-26)— cc(claude TUI)/ np(Python compute)agents 双层:Agent Kind(OTP-supervised,snapshot 持久化)+ OS subprocess(erlexec `:exec.run/2`,**不跨 BEAM restart OTP-supervised**)。Brutal BEAM kill(SIGKILL/panic/SEGV)跳过 erlexec port-death cleanup,OS-level claude/python 变孤儿。**Layer 1 post_init respawn hook**:`Ezagent.ActionSet.Sandbox` slice 加 `respawn_template_data`(snapshot 持久化),`post_init/2` + `handle_continue/3` 调 plugin Template Class 的 `Ezagent.Kind.Template.ensure_subprocess_alive/2` optional callback(cc 用 `ensure_pty_server/3`,np `Ezagent.ActionSet.NpAgent` 对称在自己 Behavior 上挂 hook + `start_python/2`)。**Layer 2 OrphanReaper**(后被 PR #388 PidFile 重写)。**demand-spawn race 闭环 via `owns_this_agent?/2` workspace-segment gate**:`cc.agent.instantiate/3` 的 `:already_started` 分支当 agent_uri.workspace_segment == Workspace.Loader.workspace_uri.host 时调 `ensure_subprocess_alive_best_effort/2`(永不传播 error,Kind alive in degraded state,operator 看 LV 点 Restart)— close codex round-2 finding #1。`Ezagent.DeploymentId` 模块(node|cwd_at_boot)给 reaper friendly-fire safety(已被 PR #388 升级为结构性隔离)| impl |
| 129 | **Session URI shape 澄清**(PR #399 revert PR #397,2026-05-26)— SPEC v3 §3.6 canonical 形状:`session://<template>/<workspace>/<name>`。PR #335 workspace rename(default → system)只动 **workspace 段(第二段)**,**template 段(第一段)不变**。`session://default/system/main`:template=`"default"`(默认 session template,稳定 post-rename),workspace=`"system"`,name=`"main"` — 完全合法。PR #397 误把 template 段也改 system → `session://system/system/main`(template="system" 非合法 template 名),由 PR #399 revert。**Lesson:编辑 default_uri/0 时 docstring 里 `SPEC v3 §3.6` 注释就在隔壁;`grep -B 2` 5 秒可避 — over-correction 后被 ExternalMirrorWorker `{:error, :no_such_actor}` restart loop surface,根因实际是 Workspace.Loader 没 auto-spawn session kinds for bindings(separate follow-up)** | impl |
| 147 | **Router / Behavior / Kind self-built architecture(SPEC PR #445)— full plugin contract rewrite**(2026-05-28)— 3 个核心 primitives + 3 composition patterns + 9-effect declarative vocabulary。Plugin authors 写 `handle_<action>(args, ctx)` 返 effects,**永不**见 slice 或 snapshot。Framework 8 个 plugin-invisible 模块(Router / EventLog / SnapshotStore / StateRebuilder / SagaRunner / EventSubscriber / Caps.Engine / Kind.Host)。OQ-1 Resource URI scheme(3-segment with workspace);OQ-2 compile-time pattern enforcement;OQ-5 flat action namespace;OQ-6 Worker as `:hot_resource`;OQ-8 StateRebuilder lazy-on-first-load。详 ARCHITECTURE §6.0 + Decision #147 entry in Appendix B | impl |
| 148 | **Phase 1 ship — Router + Behavior(new) + Kind + LegacyBehaviorAdapter primitives**(PR #451)— `Ezagent.Router` ~140 LOC,`%Ezagent.Cmd{}` dispatch envelope,`use Ezagent.ActionSet` + `action/3` defmacro + `apply_effects/2` pure bucketiser。LegacyBehaviorAdapter dispatch-equivalent **NOT replay-equivalent**(r2 HIGH-2 closure)。子 PRs:#447 EventLog,#448 SnapshotStore,#449 SagaRunner,#450 Router/Behavior/Kind integration | impl |
| 149 | **Phase 1.5 / 1.5b ship — Kind.Runtime new-contract dispatch + effect executor wiring**(PR #453 + #454)— `Kind.Runtime.apply_new_contract_effects/4` 接 PURE bucketiser 跟实际 framework 操作,bucket 固定顺序 State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations。`:effect_returning` + `{:ref, name, path}` substitution 走通 | impl |
| 150 | **Phase 2 / 2.5 ship — 28+ domain + 6 core Behaviors 全部 migrate 到 new contract**(PR #462 + #463)— Chat / Identity / ApiKeys / UserCredentials / WorkspaceUserAdmin / Workspace / Pty / ExternalMirror / Feishu / Echo / NpAgent / CurlAgent / Lifecycle / Routing / Presence / Sandbox / Notifications 等 38 Behaviors 全部从 `@behaviour Ezagent.ActionSet` + `invoke/4` 切到 `use Ezagent.ActionSet` + `action/3` + `handle_<action>/2` + effects | impl |
| 151 | **Phase 3 ship — LegacyBehaviorAdapter DELETED + `invoke/4` retired to `@optional_callbacks`**(PR #464)— 物理删除 `Ezagent.LegacyBehaviorAdapter` 模块 + 所有引用;`@callback invoke/4` declaration 标 `@optional_callbacks`(仅 grep-able);Phase 1+2 grace window 关闭;任何遗漏的 legacy Behavior 见 missing-handler CompileError(SPEC §4.3 `@before_compile` invariant) | impl |
| 152 | **Phase 4 ship — Kind.Server attach metadata + read_graph cleanup + audit fix + 165 E2E tests**(PR #469 + #465-#468 + #452)— `Kind.behaviors_of/1` + `persistence_of/1` 新 helpers 优先于 `__attached_behaviors__/0`;`Audit.uri_to_str(:system)` 返 `"system://anonymous"`;30 个 E2E scenarios catalog ship in `docs/scenarios/`,165 个 passing E2E tests 覆盖 SPEC §7 全部 acceptance criteria — Phase 1-4 completion 的 actual gate per `feedback_completion_requires_invariant_test` | impl |
| 154 | **No unowned permissions — 每个 capability 的 `granted_by` 必须是一个 real entity**(SPEC `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md`,Allen 批准 2026-06-16;承 #153 manager-delegated grant)— **principle(Allen 原话)**:"every capability's `granted_by` MUST be a real entity. Auto-dispatched permissions are driven by a RULE, and whoever configured the rule is the granter of that permission. In the extreme case the granter is the `entity://system/user/admin` entity. Abstract `system://…` Catalog principals that are not real accountable entities violate this." — 即:自动派发的权限不是"无主"的,它由一条 RULE 驱动,**配置该 rule 的实体**就是该权限的 granter;极限情形下 granter 是 `entity://system/user/admin`。一个抽象的 `system://…` Catalog principal,若它不是一个可问责的真实实体(real account),却拿它当 `granted_by` 去 MINT 权限(`IdentityAdmin.grant_cap`/`revoke_cap`),就违反本原则 —— 权限变成"无主"。**与 #153 的关系**:#153 的 manager-delegated grant 正是本原则的落地机制 —— 把"orchestrator caps 由 `system://template-materialize` 代发"换成"session owner(target 的 manager)亲自 delegate",granter 从抽象 principal 变回真实 owner entity(#811 的 cap#2 + #808 的 anon-access 是头两个待转换目标)。**enforcement(本 PR)**:(1) ratchet 不变量 gate `apps/ezagent_core/test/invariants/no_unowned_system_principal_grant_test.exs` —— 显式 `@allowlist` 锁定当前所有"unowned authority"(category-B)principal,assert Catalog 的 B-set ⊆ allowlist(不允许 NEW 的 unowned principal;每落地一个转换 allowlist 只能缩,直到 0);(2) eventual 终态:`granted_by`-is-a-real-entity property —— 转换全部落地后,没有任何 cap 的 `granted_by` 指向一个非真实-entity 的 `system://` principal。**审计**:15 个 Catalog principal 的逐条 A/B 分类见 [docs/notes/2026-06-16-capbac-system-principal-audit.md](docs/notes/2026-06-16-capbac-system-principal-audit.md);本 PR 不转换任何 principal(留给后续 PR),只立 Decision + 审计 + ratchet gate(allowlist 当前 B-set 使其当下 green) | impl |
| 153 | **cap-grant authorizer 集扩张 `{self, admin}` → `{self, admin, manager-of-target}`**(SPEC `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md` §1,PR-a,Allen 批准 option A,2026-06-16)— `Ezagent.ActionSet.IdentityAdmin.check_grant_authorized/2` resolved-`%URI{}`-owner 分支新增 manager 授权:caller 持有 target instance 的 `Behavior.Manage`/`:any`-action cap(`CreatorGrant.manage_cap/4` shape)即为 manager。**delegation-bounded(codex P1,强制)**:`grant_cap` 不继承 `Role.CapMint` 的 delegation policy(不在此 runtime path),故 manager 分支额外要求 cap-to-grant 必须 `Capability.matches?` caller 自己持有的 cap(asymmetric match → 具体 cap 永不授权 wildcard 请求),否则 fail-closed `:grant_not_delegable`。**wildcard-action 仍 admin-only**(`check_action_wildcard_grant_authorized` 不变)。**audited**:`:cap_granted` event 带 `via_manage: true` provenance(记在 event payload,非 `%Capability{}` struct)。§5 prerequisite:orchestrator spawn 路径补 owner→orchestrator 的 Manage cap(`grant_owner_orchestrator_manage_cap`),使 owner 成为 orchestrator 的 manager。**§6 `Orchestrator.Caps` 迁移 DEFERRED**:非 admin owner 不持有授权 orchestrator scoped-cap #2(`agent/:any/{:spawned_by}`)所需的任何 cap(连 §5 Manage cap 也因 asymmetric match 不覆盖),owner-delegation 迁移对 cap #2 结构性不可行 → 超出 spec 的新架构决策,待 Allen 裁定(见 PR-a body) | impl |
| 155 | **4-carrier-layer taxonomy + anti-leak red lines**(SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`,承 socialware-unification `docs/together/2026-06-26/specs/socialware-unification.md`)— 每个 artifact 落在四 carrier layer 之一:**L1 Code plugin**(`apps/ezagent_plugin_*`,generic mechanism code)、**L2 Definition data**(Postgres `ConfigObject`,config-as-data:recipe / socialware-definition / responsibility `role_name` / shape config — **business semantics 只能在此层**)、**L3 Runtime state**(Postgres `kind_snapshots` per-instance slice + blob URI ref)、**L4 EZAGENT_HOME files**(host-OS 文件:creds / pid-files / logs / upload bytes)。四层是 **artifact-kind 轴**,跟 three-tier(core/domain/plugin)的 **code-dependency 轴 正交** —— 一个 plugin 可同时发 L1 code + L2 seed definitions。**六条 red line**:(1) business concepts → L2 data ONLY,never in L1 code / core / L3 schema;(2) business mechanism ≠ business semantics(mechanism 是 L1 plugin,semantics 是 L2 data);(3) 加新 socialware 不得改 `ezagent_core`;(4) **Blob NEVER inline in Postgres** —— bytes → L4(fs/object-storage),Postgres 只存 `resource://<ws>/uploads/<name>` URI ref + MAC-signed `DownloadToken`(S3-presigned-URL style;`Ezagent.Uploads` + `Ezagent.Uploads.DownloadToken` + `Ezagent.Resource.FsResolver`);(5) `socialware` 是 substrate name 不是 business concept(core 可命名 substrate table/registry seam,不得命名 business-app concepts;NP-2 lint 是 enforcement seam);(6) fixture NOT a concept(autoservice/loom 是 configured instance = L2 seed + L3 instance,不入 concept taxonomy/schema)。**concept taxonomy**(承 socialware-unification):base(基座,capability substrate,非 user-operable)/ socialware(human+program hybrid FLOW,composes ≥1 base + shape,directly user-operable)/ fixture(seeded business instance,NOT a concept)/ recipe(axis A,`Ezagent.Agent.Recipe`,`recipe:<name>` key `"recipe"`)/ responsibility(axis B,`role_name` + `{:role,name}` routing)/ definition(L2 ConfigObject)/ runtime state(L3 slice)/ blob / shape / install relation。详见 §2 术语表 + `docs/socialware-concepts.md` | impl |
| 156 | **"app" = socialware,是 config-only bundle;code 只从 plugin 进**(Allen 2026-07-03,SPEC `docs/superpowers/specs/2026-07-03-socialware-manifest-design.md` §1)— 采 VSCode 类比钉死 code/config 边界:一个 **plugin** = **code**(VSCode *extension*:behaviors / views / recipes / kinds — 新 mechanism 只能走这条 channel);一个 **app ≈ 一个 socialware(flow)**,其可发布形态是一个 **`Ezagent.Socialware.Definition`**(VSCode *extension-pack*:`extensionPack: [ids]`,声明 `uses`(plugins) + `agents` + `views` + routing,**carries zero code**)。Definition 是 L2 config bundle(承 #155 术语表 definition 条 + T2 skill "publishable unit is the socialware Definition"),不是新 Kind、不引入新 "app" concept;user 面永不见 "app" 字样,只见 named conversation(AutoService / website / kanban)。**一个 socialware 加新能力 = 加一个它 `uses` 的 plugin**(config 层不写代码)| impl |
| 157 | **SessionTemplate = new-session preset,NOT the app**(Allen 2026-07-03,SPEC 同上 §1)— `Ezagent.Entity.SessionTemplate` 的 `installs: [name]`(+ members + name)是"新建 session 时装哪些 socialware"的 **preset**,不是 app 本身。#1126 的 "app = fattened SessionTemplate" 是一次 **conflation**(把 preset 跟 publishable-unit 混为一物),**superseded-by #1136**(app = fattened socialware `Definition`)。三层关系(emacs 类比):**Definition** = 可发布 deliverable / **SessionTemplate** = 一个 session install 哪些 socialware / **session** = running instance | impl |
| 158 | **`Ezagent.ActionSet.ConfigGovernance.{Agent, Socialware}` — CR pattern 提为 subject-agnostic parent**(Allen 2026-07-03,SPEC 同上 §5;refactor 见 GitHub issue #158)— 今天的 `Ezagent.ActionSet.ConfigGovernance`(#1042)只做单 agent 的 config CR(agent-subject / self-binding),无法 publish 整个 Definition。**Refactor**:把共享 CR 机制(**stage → preview → publish-pointer-flip → rollback**)抽成 subject-agnostic 的 **`ConfigGovernance`** parent;今天的 agent 路径下沉为 **`.Agent`**(治理一个 agent 的 config);新增 **`.Socialware`**(把一整个 socialware `Definition` stage draft → flip visibility/version pointer → discoverable+installable)。复用 CR *pattern* 但 per-subject fork,不扭曲 agent 语义。追踪于 **GitHub task #158**(注:与本 GLOSSARY 决策 #158 编号巧合,非自指)| impl |
| 159 | **`config://` retired(T1);socialware 由 opaque ConfigStore subject `socialware:<name>` 寻址**(Allen 2026-07-03,SPEC 同上 §1;承 T1 `docs/together/2026-07-02/specs/T1-preprod-foundation.md`)— `config://` scheme 已 **retired**(codebase `apps/*/lib` 零引用,已核)。一个 socialware 用 opaque subject **`socialware:<name>`** 寻址(workspace 是 **单独的 field**,不拼进 subject);它是一个 **catalog / data key,NOT a routable URI scheme**(不在 6 个 Kind URI scheme 集内 —— 承 #155 术语表 L2 ConfigObject 条),只有 install 进一个 session 才变成 running actors | impl |
| 160 | **`agents[].flavor` — socialware 声明的 agent 携带 flavor,经 `Recipe.Compose` 路由**(Allen 2026-07-03,SPEC 同上 §4)— 一个 socialware Definition 的 `agents[]` entry 目标形态携带 **`flavor`**(cc / codex / py / completion,author 之选);materialization 经 flavor-generic 的 **`Ezagent.Agent.Recipe.Compose`** 路由。**Today**:session materialization 走 cc-pinned 的 `DefaultAgentSeed`(flavor 硬编码 `"cc"`),`Recipe` 刻意不含 flavor field → 目前 **hard-pinned to cc**;fix = 给 `agents[]` 加 `flavor` + 让 materialization 走 `Recipe.Compose`(caps 仍只来自 recipe,Definition 不 override) | impl |

| 161 | **declaration/content 四层词 convention:Definition / Recipe / Manifest / Registry 各占一层**(Allen 2026-07-08,起因:skill 分发设计 #1251 讨论)— **Definition** = 应用声明("这个 socialware 是什么")/ **Recipe** = 个体配方("这个 agent 怎么做出来")/ **Manifest** = 部署清单("这个部署环境装什么",$EZAGENT_HOME seed 输入)/ **Registry** = 运行时索引("按名字怎么找到",进程内 read-through)。辅助后缀:`*Store`(持久存储后端)/ `*Seed`(boot/deploy 安装通道)/ `*Resolver`(读侧 read-model)/ `*Materializer`(声明→运行时 artifact)。**新概念命名先对 §3 内部分层词表**;不做存量改名(现有模块经 grep 核对已各归其层;`Ezagent.Socialware.ConfigStore` 作 substrate seam 命名为 red-line 5 所许)。详见 §3 "内部分层词消歧" | impl |

| 162 | **cap grant = ISSUE → STORE → VERIFY(cbac-done-right Phase-3,landed main `fa72d36ba` 2026-07-12)**(承 #154 no-unowned + #153 manager-delegation)— 一个 grant 不再是"一次 issuer→grantee dispatch 直接写 grantee slice",而是三步:**ISSUE**(`Ezagent.Cap.issue/3` 载 issuer authority、跑 `authorize_grant`、stamp `granted_by`=issuer,**不转移 authority**,只产 artifact)→ **STORE**(grantee 自存:`create/1` self-store 或 `:vm_internal` `absorb_cap` cast,never issuer-driven)→ **VERIFY**(`Ezagent.Cap.verify/1` 在 ≤5 个 load/store 边界,fail-closed 查 entity-scheme provenance)。`Ezagent.Identity.Grant` 仍是唯一 grant/revoke constructor(经 `Cap.issue`);dispatch 侧 `cap_issued` runtime bypass 只由 chokepoint 在 issue 成功后 stamp。**I12 paradigm-lock**(`cap_self_store_paradigm_lock_test.exs`)禁 issuer→grantee dispatch:~16 legacy grant driver shrink-only,recipe/orchestrator/workspace 三 cutover zero-tolerance。pre-issued recipe caps 存 `RecipeCapBinding`(`issue_and_upsert/4`,persistence 从不 dispatch 给 grantee)。**scope**:single-BEAM/trusted-node,crypto=Phase-4(`verify` 查 format 非签名)。详见 §2 "ISSUE / STORE / VERIFY" 条 + `.claude/skills/ezagent-developer/references/capbac.md` §4.5(current SoT);design spec/plan 未 merge,capbac.md + invariant gates + `docs/e2e/2026-07-11/phase3-cbac-done-right/` 为权威。**(⚠ 2026-07-18 修正:末句 "crypto=Phase-4(`verify` 查 format 非签名)" 已被 Decision #164 = Path A 取代 —— per-Kind ed25519 签名 + 严格验签已落地(PR #1457),`Cap.verify/1` 已下线。ISSUE→STORE 流程不变;VERIFY 换真密码学。)** | impl |

| 163 | **终端属于创建者:PTY 的看/写/重启统一由 agent 的 MANAGE cap 携带**(Allen 2026-07-14,起因 #1294 排查)— 一个 agent 的 PTY(读输出流+回滚缓冲、写输入、重启子进程)**全部**以该 agent 的 `cap(:agent, Manage, :any, <该 agent>)` 为准 —— 也就是 `CreatorGrant.manage_cap/4` 在创建时**已经**铸给创建者的那一个。**零新 cap、零回填**。承既有惯例(`ConfigGovernance` 7 个 CR action / `ConfigEvolve` 同形,lead decision OQ-4 "the agent's MANAGE cap, no separate cap");机制上 `Kind.Runtime` 覆盖 needed-cap 的 **action** 轴但 **honour 声明的 behavior 轴**,故 `ActionSet.Pty.required_caps/0` 声明 `Manage` 即可。**动因**:Allen 2026-07-10 的决策(用户可故意创建无凭证 cc agent,自己进 PTY 打 `claude /login`)在代码里**是空的** —— 全仓库**从未**铸过 `ActionSet.Pty` cap,创建者既不能写、也不能看自己 agent 的终端,只有 admin 能。**BREAKING**:手工发放的 `Pty` cap 不再授权任何 PTY action(fail-closed)。**同批修掉一个机密性洞**:终端 READ 此前**零门禁**(4 个读出口 —— terminal 路由 state / 其 PubSub 订阅 / 会话内 `session.pty.open`(客户端可传任意 agent URI)/ `TerminalSeam`),任何登录用户可跨 workspace 围观任意 agent 终端(含 `/login` 授权码)。策略落在 `Ezagent.Domain.Pty.Access`(**被保护物旁边**,非某个调用方),4 个出口全接;`TerminalSeam` 改为**按构造自带门禁**。详见 `docs/notes/2026-07-14-pty-terminal-read-ungated.zh_cn.md` + `docs/notes/2026-07-13-agent-creator-pty-authority-gap.zh_cn.md` | impl |
| 164 | **Cap-signing Path A ship — per-Kind ed25519 签名 authority,cap born-signed + 严格验签**(PR #1457 "[Done] feat(cap): enforce per-Kind signing authority",merged 2026-07-18,commit `596bd3a1d`;承 #162 ISSUE→STORE→VERIFY,取代其 "crypto=Phase-4 pending" 前瞻句)— **#162 的 VERIFY 从 provenance-format stand-in 升级为真密码学**;`Ezagent.Cap.verify/1` **下线**。**每个 target Kind 是它自己的签名 + 验签 authority**,用**自己的 per-Kind ed25519 key**:`Ezagent.Cap.Authority`(`apps/ezagent_core/lib/ezagent/cap/authority.ex`)持 live authority 为 `Kind.Server` 私有 top-level state,durable custody 为**独立 top-level 表** `kind_cap_authorities`(`Ezagent.Ecto.KindCapAuthority` — append-only / 按 `generation` / one-active-per-URI / `private_key` redact / 无 delete API)。**key 不在 env var(旧 `EZAGENT_SIGNING_SEED_V1` 随本 PR 退役,prod+config 0 引用)也不在 `kind_snapshots`。Genesis = 单一 admin-pinned root**(`regenesis/3` 要 admin presenter)。**Born-signed**:`Cap.issue/3` 请 `Authority.sign/2` 签不可变 grant intent。**Storage filter**:`Cap.storable_for?`/`verified_set` 只让 born-signed + receiver-bound artifact 进 store,unsigned/legacy 存储时即丢(`capability.ex:282` legacy fallback 已删,codex r4 option-B)。**Strict verify**:`Ezagent.Cap.Verifier`(唯一 framework verifier)对 cap-gated action 仅当 `Authority.verify_current(cap, presenter)` 验签通过 **且** 匹配 shape 才接受,否则 `:invalid_cap_signature`/`:missing_cap`/`:presenter_required` —— **无 soft/permissive 分支**;并列一个固定 `@non_cap_actions` allowlist(各自 in-handler predicate,结构性拆分非 fallback)。**威胁模型 = Path A(reviewed-code)**:BEAM 内已恶意执行的代码 out-of-scope(load 前经 review);防 accidental forgery / review-missed 架构违规 / external-ingress caller-spoof。**签名 ≠ 撤销**(revocation 独立线)。**Path B(隔离 signer/sidecar/HSM + issuer-URL authentication)= DEFERRED**,防 in-VM 恶意代码,给未经 review 的 3rd-party plugin 在 BEAM 内跑那天用;旧 v11 "isolated central signer / 单 CapStore / one-shot re-sign" spec(2026-07-15)**就是 Path B,已被 Path A superseded** —— 勿描述为 pending/required-now。详见 §2 "Cap authority & signing(Path A)" 条 + ARCHITECTURE.md §7.8 + `.claude/skills/ezagent-developer/references/capbac.md` §4.6 | impl |

| 165 | **World UI refresh = declared surface + SliceChange projection**(PR #1497,2026-07-23)— 插件不向 World 写专用 refresh handler：它声明 surface，提供 caller-scoped `refresh_state/2` partial projection；World 的 `RefreshSurfaceRegistry` 校验并聚合声明，`WorldLive` 独占消费 `Ezagent.SliceChange`、合并 pending refresh、以 current presenter caps 构造 ctx，并发 `world:surface_state`。React 只合并 JSON-safe 局部状态。禁止 plugin-name World 分支、专用 browser refresh event、direct PubSub-to-browser。失败一律 fail-closed。详见 ARCHITECTURE.md §2.3.1 与两套 `ezagent-developer` UI contract。 | impl |

实施期决策(impl)将持续从 #114 起 append →
> **编号注**:#153 由 PR #811(`feat/54-pr-a-manager-delegated-grant`,未 merge)占用 —— 见上文 #153 entry 在该分支的版本。本 #154 在 origin/main(#152 之后)直接 append;若 #811 先 merge,表尾按既有"parallel-squash rebases tail"惯例自动顺位,无冲突。

---

## 2. 术语表

Ezagent domain 词汇,按字母顺序。

### Adapter

外部 transport 接入点。**Adapter 不允许有业务语义**——它只做两件事:解析外部输入 → 构造 `%Invocation{}`;渲染结果回外部协议。

### Base(基座,plural)

**Capability substrate** — 一个 `Behavior` 拥有 persistent state slice + 一组 dispatchable actions,提供 *general, reusable* 的能力(turn-taking 不 general,属 conversation-specific,所以 `Turn` 是 chat 的 *shape* 不是 base)。Base 被 composed INTO 一个或多个 socialware;它 **NOT directly user-operable** —— 你不"打开 orchestrator base",你打开一个 *composes* 它的 socialware。

Verified bases(all `defmodule`-confirmed on `origin/main`):

| Base | Module | 提供 |
|---|---|---|
| **orchestrator**(orchestration base)| `Ezagent.ActionSet.Template`(recipe-content carrier)+ `Orchestrator.Tools` + `SessionManager` | "base-ness" = **EXISTING combo**:recipe rides `Behavior.Template` 的 `:template` content slice(team/routing/persona/tool-catalog,经 role-as-data)+ `Orchestrator.Tools`(tool catalog)+ `SessionManager`(executor)。**无新 Behavior / 无 `Behavior.Template` refit** —— `Behavior.Template` 是 template-CONTENT storage(Session `behaviors/0` 不含它),不是 session-mounted runtime base |
| **surface**(hello/surface)| `Ezagent.ActionSet.Surface`(`apps/ezagent_plugin_hello` 贡献跑在它上的 page-builder)| render/external-surface substrate;owns `:surface` slice;immutable page versions + `:approved` pointer;`:put_version`/`:approve`/`:commit_settlement` |
| **pty** | `Ezagent.ActionSet.Pty` | terminal/PTY substrate(`apps/ezagent_domain_pty`) |
| **sandbox** | `Ezagent.ActionSet.Sandbox` | per-agent config_dir + Kind.Template plugin-extension substrate |
| **cc-headless-agent** | `Ezagent.ActionSet.CcHeadlessAgent` | cc SDK sync-result-persistence + headless-agent substrate(`apps/ezagent_domain_agent`) |

参考: ARCHITECTURE.md §3(carrier-layer + concept taxonomy),`docs/socialware-concepts.md` §0.2,Decision #155,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.1/§1

例:`ezagent_plugin_feishu` 是 Feishu adapter;`esr_adapter_cli` 是 CLI adapter;`ezagent_plugin_cc` 是 CC channel adapter(双侧组件)。

> 与 **ExternalMirror Adapter**(`Ezagent.ExternalMirror.Adapter` behaviour)区分:那是 Stream 2 PR-EM 引入的 narrower 概念 — stateless 模块 + `event_to_payload/1` + `target_ownership_check/2`,专门把 Session slice 镜像到外部系统(不是处理 inbound)。参见 GLOSSARY 后文 "ExternalMirror Adapter / Binding / Worker / FacadeNonceTable" 条目和 Decision #122。

参考: ARCHITECTURE.md §12

### Adapter Driver 关系

Adapter subprocess 由谁拉起:

- **Ezagent-driven**: Ezagent 通过 `Ezagent.ActionSet.OSProcess` 拉起 subprocess(Feishu/Slack)
- **External-driven**: subprocess 由外部 host 拉起,主动连入 Ezagent(CC Channel 由 `claude --channels` 拉起)

参考: ARCHITECTURE.md §12.4,Decision #54

### Audit Log

每条 Invocation 的执行记录,异步写入 SQLite `invocations` 表。**通过 `:telemetry` event 触发,`Ezagent.Audit.Writer` GenServer 异步 cast batch + 100ms flush**;不阻塞 invoke 路径。

参考: ARCHITECTURE.md §10.2,Decision #60

### Behavior

**INTERNAL ENGINE primitive(post-2026-05-29 Lifecycle migration)**。Kind 上的能力切片,跨 Kind 复用。`use Ezagent.ActionSet` + `action/3` + `handle_<action>/2` + effects 是 **engine 合约**,**不再是 developer surface** —— 它是 `use Ezagent.Lifecycle` 宏的 compile target(见 **Lifecycle** 条目)。Plugin / domain 作者**永不**写 `use Ezagent.ActionSet`、`state_slice/0`、`init_slice/1`、`invoke/4`;他们写 `use Ezagent.Lifecycle`。`required_caps/0` + `cap_subjects/0` + `interface/0` + `action/3` 语法 + effect 词汇全部从 Lifecycle 宏透传到 engine。Behavior(engine 词)只活在 `ezagent_core/lib/ezagent/behavior.ex`(macro)+ `kind/runtime.ex`(executor)。

`invoke/4` legacy callback:Phase 3 PR #464 已删除 dispatch 分支,`@callback invoke/4` 留作 `@optional_callbacks` 仅 grep-ability(让 stale Behavior 见 precise CompileError)。Phase C 不删它(R10-3 保护 engine callback 定义)。见 ARCHITECTURE §6.1。

参考: ARCHITECTURE.md §6 + §6.0(engine contract)+ §6.0.7(Lifecycle developer surface),Decision #2, #147-#153,SPEC `2026-05-28-router-behavior-kind-architecture.md` + `2026-05-29-lifecycle-hooks-design.md`

### Lifecycle(`use Ezagent.Lifecycle`)

**SPEC 2026-05-29 — 唯一的 developer-facing Behavior 编写方式**。把 §6.0 的 CQRS 机制(slice / invocation / snapshot / persistence-strategy / 四个 boot hooks)藏在 agent-SDK 风格的 hooks 后面。宏 compile down 到 `use Ezagent.ActionSet`(R10-3),engine 看到的形状不变。

**两容器状态模型**:`state`(PERSISTENT,framework auto-snapshot,`ctx.read.(k, default)` 读 / `{:set, k, v}` 写)+ `transients`(NEVER persisted,`ctx.transients[k]` 读 / `{:set_transient, k, v}` 写;PIDs / refs / ETS / ports / subprocess / monitor refs)。一个 transient **结构上**不可能被持久化(无序列化路径)或在重启时被遗忘(只能在 `activate/2` 建,`activate` 每次 start 跑)—— 这 by construction 杀掉 cold-restart bug class。

**五 coarse + 二 fine + 二补充 hooks**:`create/1`(首次存在,`ever_created` 列 gated)/ `activate/2`(每次 start,pre-`:ready`,重建 transients + reconcile DB state)/ `handle_<action>/2`(per declared action)/ `deactivate/2`(优雅停,`:ok`-only)/ `destroy/2`(永久删)/ `pre_handle/3` + `post_handle/4`(横切)/ `handle_signal/2`(非-action 消息,`handle_kind_message/3` 后继)/ `activated/2`(post-`:ready` reachability broadcast,`on_ready/2` 改名)。

```elixir
defmodule Ezagent.ActionSet.Chat do
  use Ezagent.Lifecycle, state_slice: :chat   # state_slice override (snapshot-compat)
  # lifecycle:state_slice_override            # ← Phase C gate sanctions only marked overrides

  action :send, args: %{message: Ezagent.Message}, returns: %{stored: :boolean},
    caps: [:send], modes: [:cast], description: "Post a message + fan out"

  # init_slice → create/1: build PERSISTENT state only (no PIDs/refs/ETS).
  def create(_args), do: {:ok, %{members: %{}, owner_uri: nil, last_seen: %{}, ...}}

  # activate/2 rebuilds TRANSIENTS every start (monitors = Process.monitor map —
  # was silently snapshotted-as-dead-refs in the old single-slice model).
  def activate(state, _ctx) do
    monitors = state.members |> Map.keys() |> rebuild_monitors()
    {:ok, %{monitors: monitors}}
  end

  def handle_send(%{message: msg}, ctx) do
    {:ok, %{stored: true},
     [{:set, :last_message_id, msg.id},
      {:notify, "session:#{ctx.self_uri}:events", {:chat_message, msg}},
      {:dispatch, %Ezagent.Cmd{target: recipient_uri, action: :receive, args: %{message: msg}, ctx: %{caller: ctx.self_uri}}}]}
  end
end
```

**§11 命名原则**(NP-1 按职责命名 / NP-2 `ezagent_core` 不得含上层概念词 / NP-3 名宽 = action 宽)+ **Phase C HARD gate** `mix ezagent.check_invariants.lifecycle`:见 **Phase C gates** 条目 + ARCHITECTURE §6.0.7 + Decision #153 + SPEC `2026-05-29-lifecycle-hooks-design.md`。命名旅程 `Lifecycle → AdminControl → TerminateWorker → Terminable`(OQ-6)即 NP 原则的活样本。

### `Behavior.required_caps/0`(PR-CC-2-v2, 2026-05-25)

每个 Behavior 的 per-action cap 声明回调,签名 `required_caps() :: %{required(action :: atom()) => Ezagent.Capability.t()}` — **每个 action 对应单个 cap 模板(不是 list)**。Dispatch **step 5.5** 通过 `Ezagent.Kind.holds_cap?/3` 把 Behavior 这边的 `required_caps()[action]` 跟 caller 持有的 caps 对上 — 这是 cap 检查的唯一 chokepoint(`cap_check_only_at_chokepoint` invariant 禁止生产代码内别处的 `Capability.matches?/2` 调用)。

不需 cap-gate 的 action(只读 inspection / `:status` probe 等)通过可选回调 `cap_exempt_actions/0 :: [atom()]` 显式声明 — 编译时 `:ezagent_plugin_check` 验证 `keys(required_caps) ∪ cap_exempt_actions == actions`。runtime invariant `dispatch_uses_required_caps_struct_test.exs` 验证 `Ezagent.Kind.Runtime` 在 step 5.5 实际 consult `behavior_module.required_caps()` 和 `Ezagent.Kind.holds_cap?`。

参考: ARCHITECTURE.md §7.1; references/architecture-invariants.md invariant 5; PR-CC-2-v2 SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`; `apps/ezagent_core/lib/ezagent/behavior.ex:323` (required_caps 回调), `behavior.ex:340` (cap_exempt_actions 可选回调)

### `Behavior.workspace_scoped?/0`(PR-CC-2-v2, 2026-05-25)

Behavior 上可选的 workspace 隔离声明,签名 `workspace_scoped?() :: boolean()`,默认 `true`(per-tenant Kind)。Dispatch **step 5.6**(在 step 5.5 cap 检查后)读这个回调:`true` → 触发 workspace 隔离检查(caller workspace == target workspace,或 4 项例外之一 — invariant 13);`false` → 跨 workspace 可调用(e.g. system-scoped 配置读取)。

跟 invariant 13(cross-workspace dispatch)是同一枚硬币的两面:invariant 13 是"什么样的 caller 能跨 workspace 调用",`workspace_scoped?/0` 是"什么样的 Behavior 允许被跨 workspace 调用"。

参考: ARCHITECTURE.md §7.6 末段; references/architecture-invariants.md invariant 13

### BehaviorRegistry

`{Kind, action}` → Behavior module 的运行时映射。Plugin 通过 `Ezagent.BehaviorRegistry.register/3` 在 Application.start/2 时注册。

参考: ARCHITECTURE.md §6.4

### BindingPolicy(`EzagentPluginFeishu.BindingPolicy`)

Phase 6 PR 15 引入。Feishu 把 `open_id` 绑到 Ezagent `user://` 时的**副作用模块**——纯存储在 `UserBinding`,side-effects(grant 默认 cap、auto-spawn user Kind、补齐 `Ezagent.Entity.User.default_caps`)在 `BindingPolicy`。

职责分离的理由:`UserBinding` 测试不该触发 dispatch;`BindingPolicy` 测试可以 stub 存储。未来多策略(per-workspace 默认、role templates)在 `apply/2` 改,不动 store。

PR 27 之后,`apply/2` 也调 `ensure_user_default_caps/2`(idempotent MapSet 语义),覆盖 pre-PR-27 已创建 user。

参考: ARCHITECTURE.md Decision #133, #134; [docs/notes/phase-6-architecture-closeout.md](docs/notes/phase-6-architecture-closeout.md)

### Blob

二进制 artifact(video/attachment/generated asset)。**Red line:blob bytes NEVER inline in Postgres**(Decision #155 red line 4)。Bytes 落在 L4(host filesystem `EZAGENT_HOME/uploads/<ws>/<name>` 或 S3-compatible object-storage);Postgres 只存 `resource://<ws>/uploads/<name>` URI ref + 一个 MAC-signed `DownloadToken`(S3-presigned-URL style bearer token)。Verified:`Ezagent.Uploads`(`apps/ezagent_core/lib/ezagent/uploads.ex`,moduledoc "Attachments are addressed as `resource://<ws>/uploads/<name>` … bytes live at `Home.path(\"uploads\")/<ws>/<name>`")+ `Ezagent.Uploads.DownloadToken`(`apps/ezagent_core/lib/ezagent/uploads/download_token.ex`,moduledoc "S3-presigned-URL style: a MAC-signed bearer token")+ `Ezagent.Resource.FsResolver`(`apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex`)。Consumers mint a token for the stored URI,never for bytes。

参考: ARCHITECTURE.md §10.5(landed Uploads/FsResolver/DownloadToken design),Decision #155,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.3/§4.5

### CapBAC

Capability-based access control。Ezagent 的权限模型——每个 Invocation 在 `ctx.caps` 携带 capabilities;dispatch step 5.5 检查 caller 持有的 caps 是否允许该 action。

参考: ARCHITECTURE.md §7,Decision #4

### Capability(`%Ezagent.Capability{}`)

权限 token,struct(不是字符串)。当前(2026-05-26)的实际字段(`apps/ezagent_core/lib/ezagent/capability.ex:28`):

```elixir
@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]
defstruct [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]

%Ezagent.Capability{
  kind:          atom() | :any,                              # 哪种 Kind 类型
  behavior:      module() | :any,                            # 哪个 Behavior (模块引用,NOT atom — 见 invariant 2)
  instance:      URI.t() | :any | scope_tuple(),             # 具体实例 / 通配 / 范围 tuple (within_session / within_workspace / spawned_by)
  workspace_uri: URI.t() | :any,                             # workspace scope (Phase 9 §13)
  granted_by:    URI.t(),                                    # 授权链(谁授的)
  granted_at:    DateTime.t()                                # 何时授的
}
```

⚠️ **没有 `action` 字段**:`matches?/2` 比较 kind+behavior+instance+workspace_uri 四个轴,跟 action **完全无关**。多 action 的 Behavior 当前(2026-05-26)无法在 cap 层面区分 action — `cap/3` 接受 action 参数但**直接丢弃**(`capability.ex:90` 形如 `def cap(kind, behavior, _action, ...)`),只是为了模板与 `required_caps/0` 形态一致。多 action Behavior 的特权 action 必须 carve 出独立 Behavior(PR #356 模式 — `WorkspaceUserAdmin.:create_user` 从 `Workspace` 拆出),否则任何持有 cap-on-Behavior 的 principal 能调用所有 action。SPEC 级 action 轴变更跟踪在 `docs/futures/todo.md` "Capability struct lacks an action axis"。

参考: ARCHITECTURE.md §7,Decision #38, #133, #137; PR-CC-2-v2 (2026-05-25);`apps/ezagent_core/lib/ezagent/capability.ex:28`(struct decl)

### `Capability.cap/3` / `Capability.cap/5`(构造帮手,PR-CC-2-v2 2026-05-25)

`Ezagent.Capability` 暴露两个构造帮手,简化 `required_caps/0` 模板 + 具体 grant 构造:

- **`cap(kind, behavior, _action)`** — 通用模板,`instance`/`workspace_uri` 留 `:any`;用于 `Behavior.required_caps/0` 这种 "我需要这种 cap" 模板。**`action` 参数虽签名要求,但被直接丢弃**(`capability.ex:90`)— 仅为可读性 + 模板对齐。
- **`cap(kind, behavior, _action, instance, workspace_uri)`** — 具体 cap;用于 grant 给具体 principal 的实际 cap 实例,可指定 `instance`(URI 或 scope tuple)+ `workspace_uri`。

两者都返 `%Ezagent.Capability{}` struct(`granted_by` / `granted_at` 由构造逻辑填)。`Capability.cap_for_action/3` 是更早的反查 helper(给定 target_uri + action → 需要的 cap 模板)。

参考: ARCHITECTURE.md §7.1; PR-CC-2-v2 (2026-05-25); `apps/ezagent_core/lib/ezagent/capability.ex:90-130`(`cap/3` + `cap/5` 实现)

### ISSUE / STORE / VERIFY(Phase-3 grant paradigm,cbac-done-right,2026-07-12 merge `fa72d36ba`)

一个 grant 不再是"一次 issuer→grantee 的 dispatch 直接写 grantee 的 `:caps` slice",而是**三个可分离步骤**。权威从 **issuer → artifact**,存储只走 **grantee 自己**(never issuer-driven)。`granted_by` = issuer。这是 **I12 paradigm-lock** 的语义。

- **ISSUE — `Ezagent.Cap.issue/3`**(`apps/ezagent_core/lib/ezagent/cap.ex`)。grantor 的步骤:载入 **issuer** 持有的 authority(dependency-inverted `:authority_loader`,config `:ezagent_core, Ezagent.Cap`),跑完整 grant 授权算法(`CapabilityRegistry.authorize_grant/3`,同 §3/§5),成功后 stamp issuer provenance `%{cap | granted_by: <issuer>, granted_at: now}`(校验 `granted_by` 是 `%URI{scheme: "entity"}`,否则 `{:error, {:granter_not_entity, _}}`)。**ISSUE 不向 grantee 转移任何 authority** —— 只产出一个带 provenance 的 *artifact*。四个授权 tag(`{:held_by}`/`{:admin}`/`{:rule}`/`{:genesis}`)不变。
- **STORE / absorb — grantee 把 artifact 存进自己的 slice**。两条 lane,都 grantee-driven:(1)`create/1` self-store —— keyed entity 在 Identity `create/1`/`activate/2` 读自己 pre-issued 的 artifacts(来自 `RecipeCapBinding`)via `Ezagent.Cap.verified_set/1`;(2)`:vm_internal` absorb —— `Ezagent.Identity.absorb_cap/2` 发一条 `:absorb_cap` `%Cmd{}`(`caller: :vm_internal, mode: :cast, reply: :ignore`),`handle_absorb_cap/2` **只接受 `:vm_internal` caller**(其他 → `{:error, :unauthorized}`),verify 后 `store_verified_cap` 写 slice。same-BEAM/same-node,无 cross-node absorb transport。
- **VERIFY — `Ezagent.Cap.verify/1`**。total + fail-closed:仅当 `%Capability{granted_by: %URI{scheme: "entity"}}` 返 true。只在 ≤5 个 reviewed load/store 边界跑(grantee `create/1`/`activate/2` slice load、identity `read_held_caps`/`list_caps_for` loader、snapshot load fallback、grant + absorb 两条写路径的 `store_verified_cap`)。Phase-3 是 **provenance-format** 检查(entity-scheme `granted_by`),是 Phase-4 签名验证的 stand-in;seam 设计成 Phase-4 只换 `verify/1` body 不动 caller。**(⚠ 已被 Path A 取代,2026-07-18 修正:`Ezagent.Cap.verify/1` 已下线;born-signed 存储过滤现走 `Cap.storable_for?`/`verified_set`,dispatch 侧密码学验签现走 `Cap.Verifier`/`Authority.verify_current` —— 见下条 "Cap authority & signing(Path A)" + Decision #164。不要再当作 "provenance-format stand-in / crypto 待做"。)**
- **`Cap.issue` chokepoint**:grant 经 `Ezagent.Identity.Grant.prepare/4` → `Cap.issue`(revoke 走 `Cap.prepare_provenance`,共享同一 provenance primitive)。dispatch 侧 `Kind.Runtime` step-5.5 首个 `cond` arm 在 `ctx.cap_issued == true` 时授权 `IdentityAdmin` `:grant_cap`(无需另一个 matching cap);`cap_issued` 只由 chokepoint 在 `Cap.issue` 成功分支 stamp(`maybe_mark_issued`),外部 ctx 永远无法携带 → N1 test `cap_issued_bypass_trust_keys_test.exs` pin 这两个 trust-key 属性。
- **`RecipeCapBinding`**(`apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex`):agent 存在**之前** pre-issued recipe caps 的 durable home。materializer 调 `issue_and_upsert/4`:先对每个 proposed cap ISSUE(`Cap.issue({:admin, issuer}, agent_uri, proposal)`),validate issued set,再整批 commit 到按 agent instance 键控、带 version + tombstone 的 binding。**persistence 从不向 grantee dispatch cap 写** —— keyed agent 之后从自己 lifecycle hook 读(create/1 self-store lane)。content-hash 幂等,内容变则 version 单调递增。
- **I12 paradigm-lock**(`cap_self_store_paradigm_lock_test.exs`):禁止新的 issuer-driven grant site;~16 个 legacy `grant_cap`/`grant_cap_via_router` site(12 文件)shrink-only ratchet(只能减);recipe/orchestrator/workspace 三条 cold-agent cutover zero-tolerance(必须 `issue_*` 后 `absorb_*`,无 `Identity.Grant`/`mode: :call`/`await_ready`)。配套 `cap_issue_chokepoint_test.exs` ratchet 所有 `%Capability{granted_by:}` constructor + `{:set, :caps}` writer。

**接受的 scope(Phase-3 历史框架)**:single-BEAM / trusted-node。与 **Decision #154**(no unowned permissions)一致:`granted_by` = issuer 一定是 real entity;Decision #162。**(⚠ 2026-07-18 修正:"crypto = Phase-4 待做 / `verify/1` 查 provenance format,非签名" 已过时 —— per-Kind ed25519 签名 + 严格验签已作为 **Path A** 落地(PR #1457);cap 现在 born-signed + strict-verify。in-VM 恶意 actor 仍是 out-of-scope,那由 deferred 的 **Path B** 覆盖。见下条 + Decision #164。)**

参考: `.claude/skills/ezagent-developer/references/capbac.md` §4.5–§4.6(current source of truth),Decision #154 #162 #164,`docs/e2e/2026-07-11/phase3-cbac-done-right/`,invariant gates `apps/ezagent_core/test/invariants/cap_{self_store_paradigm_lock,issue_chokepoint,absorb_reachability,provenance_chokepoint,verify_load_boundaries,issued_bypass_trust_keys}_test.exs`

### Cap authority & signing(Path A born-signed strict-verify,landed main PR #1457,2026-07-18)

**当前真相 —— 不要再复述 "cap 验证 permissive / dual-read 还在 / cap-signing 严格版待做 / crypto = Phase-4"。** 上条 ISSUE→STORE→VERIFY 的*流程*仍在,但 VERIFY 机制已换成真密码学,`Ezagent.Cap.verify/1`(provenance-format stand-in)**已下线**。

- **每个 target Kind 是它自己的签名 + 验签 authority**,用它**自己的 per-Kind ed25519 key**。`Ezagent.Cap.Authority`(`apps/ezagent_core/lib/ezagent/cap/authority.ex`):live authority struct 是 `Kind.Server` 私有 top-level state(`private_key` 从 `Inspect` derive 排除);durable custody 是**独立 top-level 表** `kind_cap_authorities`(`Ezagent.Ecto.KindCapAuthority`)—— append-only、按 `generation`、one-active-per-URI、`private_key` redact、无 delete API。**key 不在 env var**(旧 `EZAGENT_SIGNING_SEED_V1` master-seed 方案随 #1457 退役,prod + config 0 引用)**也不在 `kind_snapshots`**。**Genesis = 单一 admin-pinned root**(`genesis/2` 先播种 `entity://user/system/admin` authority;`regenesis/3` 要求 presenter == `admin_uri()`,否则 `:admin_required`)。
- **Born-signed at issue**:`Ezagent.Cap.issue/3` 请求 target Kind authority `Authority.sign/2` 对不可变 grant intent ed25519 签名(`key_id` = per-Kind pubkey 指纹);cap 一出生就带签名,`granted_by` 仍是 real-entity issuer。
- **Storage filter(结构性)**:`Cap.storable_for?/2` + `verified_set/2`(`cap.ex`)只让 born-signed(非空 `signature`+`key_id`)且 receiver-bound 的 artifact 进 cap store;**unsigned/legacy 存储时即丢弃**。
- **Strict verify at dispatch**:`Ezagent.Cap.Verifier`(`apps/ezagent_core/lib/ezagent/cap/verifier.ex`)是唯一 framework verifier。cap-gated action 仅当 `Authority.verify_current(cap, presenter)` 密码学验签通过 **且** 匹配 required shape 才接受;unsigned/malformed/tampered/retargeted/wrong-key → `:invalid_cap_signature`/`:missing_cap`/`:presenter_required`,**无 soft/permissive 分支**。并列有一个固定 `@non_cap_actions` allowlist(`:receive`/IdentityAdmin store ops/socialware `:snapshot`,`:history`/session admission),每个自带 in-handler predicate —— 是结构性拆分,不是 soft fallback。即 "cap-gated 严格验签 + 显式 non-cap allowlist",不是 "每个 action 都要签名 cap"。
- **legacy-unsigned fallback 已删除**(`capability.ex:282`,codex r4 option-B)。
- **威胁模型 = Path A(reviewed-code)**:BEAM 内已恶意执行的代码 **out of scope**(所有 load 的代码含 community plugin 先经 review)。防 accidental forgery / review-missed 架构违规 / external-ingress caller-spoof。**签名 ≠ 撤销**(revocation 是独立线:epoch target-generation + delete_user cascade)。
- **Path B(隔离 signer / sidecar / HSM + `Cap.issue` issuer-URL authentication)= DEFERRED/roadmapped**,给 "未经 review 的 3rd-party plugin 在 BEAM 内跑" 那天防 in-VM 恶意代码;旧 v11 "isolated central signer / 单 CapStore / one-shot re-sign" spec(2026-07-15)**就是 Path B**,已被 Path A superseded。**不要描述 Path B 为 pending/required-now。**

参考: ARCHITECTURE.md §7.8,Decision #164,`Ezagent.Cap.Verifier` + `Ezagent.Cap.Authority` moduledoc,`.claude/skills/ezagent-developer/references/capbac.md` §4.6

### Channel(Claude Code Channel)

Anthropic 给 Claude Code 的"外部事件 push to TUI"机制。**MCP 协议的一个扩展 capability**(不是独立通信协议,Decision #86 Phase 1b 实证)——一个 channel 就是个普通 MCP server,多三件事:`capabilities.experimental['claude/channel']` + `notifications/claude/channel` notification(server → claude,渲染 `<channel source="...">`)+ 标准 MCP tool(如 `reply`,claude → server)。

Ezagent 通过 `ezagent_plugin_cc`(Elixir HTTP/SSE + Python MCP server)桥接外部 CC 实例。Python 侧是普通 MCP server,走 stdio 跟 CC 通信;Elixir 侧通过 HTTP/SSE 跟 Python 通信。**不需要独立 channel-server 进程,不需要 WebSocket** — 这是 v0.3 §12.8 的认知错误,Phase 1b 纠正。

⚠️ 易混淆 — Phoenix.Channel 是 Phoenix 框架的 WebSocket 抽象,跟 CC Channel 完全是两件事(碰巧同名)。见 §3 易混淆词表。

**Meta schema(Phase 6 PR 26, Decision #132)**:`notifications/claude/channel` 的 `meta` 字段是 `Record<string, string>`(Anthropic channels-reference spec 强制)。**任何 non-string value(list / map / nested object)让 claude TUI 整条 notification silently drop**,没有错误返回——symptom 看起来跟 transport 失联一样,极难诊断(PR 14 加 list 类型 attachments key 坏了 inbound,3 周后才发现)。

结构化数据放 `content`(文本 breadcrumb 形式);可选 `meta.file_path: <abs-path>` 字符串(单文件场景,仿 cc-openclaw 约定),由 claude `Read` tool 拉取实际内容。CI gate:`apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings"。

参考: ARCHITECTURE.md §12.8(Phase 1b 后已重写),Decision #86 #132; [docs/notes/phase-6-architecture-closeout.md](docs/notes/phase-6-architecture-closeout.md) §2.3

### `Ezagent.Cmd`(dispatch envelope,post-2026-05-28)

Router 的 dispatch 入口 envelope struct(SPEC §2.1)。Adapter(LV / CLI / Channel / external mirror)构造 `%Ezagent.Cmd{target, action, args, ctx}`,handed to `Ezagent.Router.dispatch/1`。

```elixir
%Ezagent.Cmd{
  target: %URI{},        # Kind instance URI(canonicalised by Router step 1)
  action: :send,         # action atom declared on a Behavior attached to target's Kind
  args:   %{...},        # validated against Behavior.@interface/0[action].args
  ctx:    %{
    caller: %URI{} | :system,
    reply:  Ezagent.Invocation.reply_target(),
    trace_id: String.t() | nil,
    command_uuid: String.t() | nil,   # caller-supplied idempotency key
    deadline_ms: pos_integer() | nil,
    caps: MapSet.t(Capability.t()) | nil
  }
}
```

跟 legacy `%Ezagent.Invocation{}` 的区别:`Invocation` 把 action 编码在 URI query string(`target?action=behavior.action`),conflate identity(URI)跟 intent(action);`Cmd` 显式分离。Phase 1 Router 内部把 `Cmd` 翻译回 `Invocation` 走老 pipeline(additive);Phase 2+ 直接走 new-contract handler invocation。

参考: ARCHITECTURE.md §6.0.1;`apps/ezagent_core/lib/ezagent/cmd.ex`;Decision #147 #148

### ctx(Invocation context)

`%Invocation{}.ctx` 字段(legacy)/ `%Ezagent.Cmd{}.ctx` 字段(new contract)。包含:

```elixir
%{
  caller: URI.t(),                  # 发起者 principal
  caps: [Ezagent.Capability.t()],       # caller 持有的 caps
  reply: reply_target(),            # 结果路由(见 ctx.reply)
  idempotency_key: String.t() | nil,
  trace_id: String.t(),
  invocation_id: String.t(),
  ...
}
```

新合约下,framework 在 handler 调用前还会注入两个 keys:
- **`ctx[:read]`** — slice 读 function,`ctx[:read].(key, default)` 取当前 Behavior 的 slice 字段(plugin authors 不再直接拿 slice map)
- **`ctx[:self_uri]`** — 当前 Kind instance 的 URI
- **`ctx[:kind_module]`** — 当前 Kind 的 module(handlers 分支 User vs Agent 等用)
- **`ctx[:sibling_slices]`** — opt-in via `reads_sibling_slices/0`(invariant 18 不变)

参考: ARCHITECTURE.md §4 + §6.0

### default_caps(`Ezagent.Entity.User.default_caps/0`)

Phase 6 PR 27 引入。User Kind 的**结构性基线 cap 集**——返回 `[%Capability{kind: :session, behavior: :any, instance: :any, granted_by: system://bootstrap}]`。`Ezagent.Domain.Identity.Users.create/3` prepend 到 caller 提供的 caps;`EzagentPluginFeishu.BindingPolicy.apply/2` 对 pre-PR-27 user 在 bind 时 idempotent 补齐。

⚠️ `behavior: :any` **不是 idiom**——是循环依赖妥协(`ezagent_domain_identity` 不能引用 `ezagent_domain_instance_message` 的 `Ezagent.ActionSet.Chat` 模块)。能用模块引用就用模块引用,narrower scope 永远更安全。future plugin authors 不要 cargo-cult `:any`。

跟 `admin_caps()` 的区别:`admin_caps` 是 `kind=:any behavior=:any instance=:any`,只授给 `user://admin`(authorization escape hatch);`default_caps` 是 `kind=:session behavior=:any instance=:any`,每个 user 都有(只能尝试 session 行为,session 内 ACL 仍走 routing rules)。

参考: ARCHITECTURE.md §7.3, Decision #133; [docs/notes/phase-6-architecture-closeout.md](docs/notes/phase-6-architecture-closeout.md) §2.1

### Definition(config-as-data)

L2 ConfigObject —— 一个 reusable / forkable / content-addressed config bundle(recipe 或 socialware definition)。地址 `recipe:<name> / socialware:<name>`。**NOT a Kind URI**:`<kind>:<name>`(recipe:/socialware:)是 ConfigStore-internal opaque subject,不在 6 个 Kind URI scheme 集合内(`entity session template resource workspace system`,`apps/ezagent_core/lib/ezagent/plugin.ex:88` `@core_schemes`)。Editing a definition mints a new content-addressed version,不 mutate running instance。**business semantics 只能在此层出现**(Decision #155 red line 1)。

参考: ARCHITECTURE.md §9(socialware definition ≠ Template Kind),Decision #155,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.2/§1

### Dispatch

`Ezagent.Router.dispatch/1`(post-2026-05-28 SPEC PR #445)/ legacy `Ezagent.Invocation.dispatch/1` — 中心化 invocation 路由入口。所有 actor 间通信都走这条路径,**没有第二条**。新合约 13 步 flow 见 ARCHITECTURE §6.0.1;legacy 9 步 flow 见 Appendix A。Phase 1 (PR #451) Router `wraps` 老 `Invocation.dispatch` 通过 `%Cmd{}` → `%Invocation{}` 翻译,Phase 2+ 直接走 new-contract handler invocation。

参考: ARCHITECTURE.md §5 + §6.0,Decision #3 #43 #147 #148

⚠️ 不要跟 `Phoenix.Router.dispatch`(HTTP path 路由)混。

### DLQ(Dead Letter Queue)

存放失败 invocation + unroutable message 的 SQLite 表。**`unroutable`** 子类:零匹配路由的 message。

参考: ARCHITECTURE.md §5.5.5,Decision #68

### Effect(post-2026-05-28 — handler 返值的 effect vocabulary)

新合约 `handle_<action>/2` 返 `{:ok, result, [effect]} | {:ok, result} | {:error, reason}`,其中 `effect` 是 9 种 declarative tuple 之一(SPEC §4.4 normative):

| Effect tuple | 用途 |
|---|---|
| `{:set, key, value}` | mutate this Kind's slice — framework 通过 SnapshotStore commit |
| `{:emit, event_name, payload}` | append to EventLog(audit + EventSubscriber consumers) |
| `{:dispatch, %Cmd{}}` | cross-Kind dispatch — framework 重入 Router |
| `{:notify, topic, payload}` | `Phoenix.PubSub.broadcast` fire-and-forget |
| `{:effect, mfa_or_fun, args}` | fire-and-forget side-effect(caller wraps try/rescue) |
| `{:effect_returning, mfa_or_fun, args, bind_as: :name}` | value-returning side-effect;result via `{:ref, :name, [path]}` in later effects |
| `{:saga, %SagaRunner.Saga{}}` | hand a linear saga to SagaRunner |
| `{:terminate, :self | URI.t()}` | schedule Kind termination AFTER reply lands |
| `{:halt, reason}` | short-circuit — remaining effects skipped, SnapshotStore never sees would-be new slice |

**Ordering normative**(SPEC §4.4): within each phase effects fire in declared order. Across phases the buckets execute in fixed `Kind.Runtime` order: **State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations**。

**Plugin author 不直接调** `Phoenix.PubSub.broadcast` / `Ezagent.Router.dispatch` / `Ezagent.EventLog.append` / `Ezagent.Kind.terminate` — 通过 effects 间接表达;framework 应用。SPEC §11 grep gate 强制。

参考: ARCHITECTURE.md §6.0.2;`Ezagent.ActionSet.apply_effects/2`;Decision #147

### Entity

Kind 三子类之一。**Principal**——发起 Invocation,持有 caps。例:`agent://...` / `user://...`。

参考: ARCHITECTURE.md §3.1,Decision #7

### `Ezagent.EventLog`(framework-internal,post-2026-05-28)

Append-only 事件存储(SPEC §5.1)。包 existing `invocations` 表(migration `20260515160000_phase1_audit_dlq_snapshots.exs` 重建于 `20260601000000_phase9_pr6_workspace_uri_columns.exs`)。Phase 1B(PR #447)introduce synchronous append + replay-stream API,Router 在处理 `{:emit, event_name, payload}` effect 时调 `append/4`;`Ezagent.Kind.StateRebuilder` 在 Phase 2+ 走 `stream_by_aggregate/2` 跟 snapshot fold。

**Plugin code MUST NOT import `Ezagent.EventLog`** —— SPEC §11 grep gate fail CI for any `Ezagent.Plugin.*` / `ezagent_plugin_*` 引用。Plugin handlers 声明 emit via `{:emit, _, _}` effect;framework calls append。读 events for replay 走 `StateRebuilder`,not plugin code。

Coexistence with `Ezagent.Audit.Writer`:Writer 通过 telemetry handler 异步 batch 写 `invocations` 表;EventLog.append 是 Router 的同步 emit-effect 写路径。两者目标同一表 — Phase 3 cleanup 计划移除 telemetry-derived rows for new-contract Behaviors。

参考: ARCHITECTURE.md §6.0.5;`apps/ezagent_core/lib/ezagent/event_log.ex` moduledoc;Decision #147 #148

### `Ezagent.EventSubscriber`(framework-internal,post-2026-05-28)

Declarative event-driven cross-Kind reactions(SPEC §5.5)。`use Ezagent.EventSubscriber` 提供 `subscribe to: ..., only: [...]` 宏 + `@behaviour` callback contract(`interested?/1` + `handle_event/2`,后者返同 Behavior effect 词汇)。Framework 在 boot 收集所有 declared subscriber + EventLog 写 row 时 fan-out 到 subscribed scope 的 subscribers。

Subscription scopes:`:all` / `{:aggregate, uri}` / `{:workspace, uri}`。

**Subscriber 不直接调** PubSub / dispatch / EventLog —— `handle_event/2` 返 effects,framework 应用 through Router pipeline。这是 SPEC §10 (f) invariant 16 的归并:bindings/subscribers 一律 effect-based 不直接 PubSub.subscribe。

参考: ARCHITECTURE.md §6.0.5;`apps/ezagent_core/lib/ezagent/event_subscriber.ex` moduledoc;Decision #147

### ExternalMirror Adapter(`Ezagent.ExternalMirror.Adapter` behaviour)

ExternalMirror Domain 三层模型的中间层 — **stateless 模块**(类比 protocol implementation,无 GenServer 状态)。Plugin author 实现 7 个 callback:`adapter_id/0` + `display_name/0` + `description/0` + `binding_module/0`(Grill-5 bidirectional 声明)+ `cap_subject/0`(per-adapter cap 形状,Allow Behavior 模块名)+ `target_ownership_check/2`(**唯一允许 I/O 的 callback** — bind-time 检查 caller 是不是 target 的成员,Feishu = Lark API 调用)+ `event_to_payload/1`(**pure** — Publisher.Event → wire payload,在 Worker Kind quantum 内跑,任何 I/O 都会阻塞 per-binding scheduler)。

⚠️ 与 Decision #13 的"transport adapter"(Feishu/Slack/CC channel inbound)不同 — 那是 inbound 接入点;ExternalMirror Adapter 是 outbound 镜像点(Session slice → external system)。

参考: SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §2.2 / §5;Decision #122

### ExternalMirror Binding(`Ezagent.ExternalMirror.Binding` behaviour)

ExternalMirror Domain 三层模型的底层 — **stateful per-target supervised GenServer**。Plugin author 实现:`adapter_module/0`(Grill-5 反向 declaration)+ `init/1`(setup transport state — open WS,fetch token,etc)+ `publish/2`(payload → external system 字节;**所有 external I/O 在这里**)+ `terminate/2`(graceful cleanup,optional)。

Worker Kind(`Ezagent.Entity.ExternalMirrorWorker`)hosts 一个 Binding per `(session, adapter, target)` triple,在 `PerBindingSupervisor`(`:permanent` restart strategy,3/30s budget)下运行。Per-binding crash 隔离:一个 binding 反复崩不影响其他 binding 或 Session Kind 本身。

参考: SPEC §2.3 / §6;Decision #122

### ExternalMirror Worker / WorkerSpawn

`Ezagent.Entity.ExternalMirrorWorker` 是 ExternalMirror Domain 的 per-binding Kind 实例。**URI shape**:`entity://worker/<workspace>/em_<hash12>`(`hash12` = sha256("<session>/<adapter>/<target>") 头 12 位,session-scoped 防 cross-workspace 碰撞)。Worker 通过 `Kind.spawn_strategy/0` callback 委托到 `Ezagent.ExternalMirror.WorkerSpawn.spawn_kind_server/1`,把 Kind.Server 包在两层 supervisor topology(`RootSupervisor` DynamicSupervisor 100/60s budget → `PerBindingSupervisor` Supervisor 3/30s budget → `Kind.Server`)。`WorkerSpawn.worker_uri_for/3` 是 **deterministic** + **session-scoped**(同 triple 永远算出同 URI,restart adoption + 幂等性 spawn 都依赖此性质)。`WorkerRegistry`(`:via, Registry` keyed by binding_uri)保证并发 spawn 同 triple 只一个赢家。

参考: SPEC §6.3 / §7.2;Decision #122

### FacadeNonceTable(`Ezagent.ExternalMirror.FacadeNonceTable`)

**`:protected, :named_table` ETS** + 拥有方 GenServer,用 32 字节 `:crypto.strong_rand_bytes` nonce 实现 `Ezagent.ExternalMirror.bind/4` facade → `Behavior.ExternalMirror.invoke(:bind, _, _, _)` action body 的 **forgery-proof handoff**。Nonce 绑定到精确 `(session_uri, adapter_id, target_id, caller_uri)` tuple,5s TTL(`@default_ttl_ms`),consume 原子单次(replay-protected via `:ets.delete` before verify)。

**Why this exists**(PR-EM-3 codex r3 CRIT 修):pre-fix 用 `args[:_facade_checks_ok] = true` 标 facade Checks 2+3 已过 — 但 `args` 是 caller 控的 `Invocation.dispatch/1` 输入,任何 in-VM caller 持 session `:bind` cap 都能直接 dispatch 带 flag 绕过 Checks。nonce 是结构性修复:`:protected` ETS 只 GenServer owner 能写;32 字节 RNG 不可猜;tuple-绑定 + 单次 consume 防 replay/swap。

参考: SPEC §4.1 r3 CRIT;PR-EM-3 round-3;Decision #122

### Fixture

一个 socialware 的 seeded instance/use,**为某个具体业务配置**。**Fixture NOT a concept and must NOT enter the concept/schema layer**(Decision #155 red line 6)。`autoservice` = chat 配置成 customer-service 业务(project name only);`loom` / 命名部署同理。一个 fixture 是 **L2 seed definition + L3 running instance** 的组合,不是新 L1 type 或 schema。autoservice 在 main 上是纯 data —— 一个 `soul_md` markdown body 被 generic `Ezagent.Socialware.ConfigProjection.render_soul/1` verbatim 投影(`apps/ezagent_domain_identity/lib/ezagent/socialware/config_projection.ex`);**无 `defmodule.*Autoservice` 业务逻辑模块**。

⚠️ **跟 ExUnit test fixture 高碰撞风险** —— 见 §3 消歧表。Ezagent "fixture" = seeded business instance,NOT a test fixture。

参考: ARCHITECTURE.md §3,Decision #155,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.2/§1/§4.3,`docs/socialware-concepts.md` §0.2

### ExternalMirror AdapterRegistry / BindingRegistry

两张 ETS 表 — `:set` keyed by `adapter_id`(string)— 分别记录 adapter_id → adapter_module 和 adapter_id → binding_module。`:ets.insert_new/2` 原子 + 显式 `assert_behaviour!` + `assert_required_callbacks!` 双层防御(compile-time `:ezagent_plugin_check` Grill-5 gate 是主防,运行时校验是 backstop 防 hot install / 直 call 绕过)。

**两 registry 协同**:`AdapterInstall.maybe_install/1`(从 AdapterRegistry 触发)+ `AdapterInstall.maybe_install_by_adapter_id/1`(从 BindingRegistry 触发)对称 pair,确保 `install/1`(per-adapter cap subject 注册 + 持久 binding row 的 Worker reconcile)**只在两个 registry 都有该 adapter_id 时 fire 一次**(r5 HIGH-A fix)— 防 install 在 BindingRegistry 空时跑导致 spawned Worker 的 `:publish` dispatch KeyError on binding lookup。

参考: SPEC §5.2;Decision #122

### Publisher behaviour(`Ezagent.ActionSet.Publisher`)

ExternalMirror Domain 三层模型顶层 — Session Kind 实现的 4-callback contract(`subscribe_from/3` + `snapshot/1` + `history/3` + 100-event 环形保留)。Subscriber(Worker Kind 是唯一 production consumer)拿到一个 ordered stream of slice changes,可以 from `:latest`(restart 默认)/ from cursor / from snapshot。**比 Phoenix.PubSub 直接 broadcast 更强**:retention 让 restart 期间漏过的 events 可补;subscriber 知道自己 lag 多远;Session GenServer 本身控制 retention policy。

**P11 escape closed**:bindings 永远不能 `Phoenix.PubSub.subscribe` 直连 — 必须走 `Publisher.subscribe_from/3` → Worker Kind 的 `:publish` dispatch path,这样 CapBAC step 5.5 enforce per-Worker cap + per-binding PerBindingSupervisor 隔离 + Adapter `event_to_payload` 在 Worker quantum 内 pure。Invariant test (PR-EM-FINAL `no_pubsub_bypass_in_external_mirror_test`) grep gate 锁死。

参考: SPEC §2.1 / §10 (f);Decision #122

### EZAGENT_HOME

Runtime persistence root —— `~/.ezagent/<profile>/` by default,overridable via `EZAGENT_HOME` env。包含:
- `credentials/` — Feishu app key、CC channel tokens 等(chmod 600)
- `db/` — SQLite location(post-Phase-5 迁移目标;当前仍在 repo root)
- `snapshots/` / `logs/` / `plugins/`
- `runtime/cookie` — distributed Erlang cookie(Ezagent.Runtime 自动 mint)

Profile model: 多 profile 同 host(`default` / `staging` / `personal`)。Init: `mix ezagent.home.init`;Migration from old esrd: `mix ezagent.home.import_from_esrd_dev`.

参考: docs/phase-specs/phase5/EZAGENT_HOME.md,Decision #130

### Ezagent.Runtime

模块管理 distributed Erlang node name + cookie。Runtime 启动时(EzagentCore.Application.start)调 `configure_for_runtime!/0` → `:net_kernel.start([ezagent_runtime@127.0.0.1, :longnames])`。CLI(mix esr)启动时调 `connect_as_cli/0` → Node.connect + `:rpc.call(EzagentCli.Exec, :exec, [argv])`。

⚠️ **CLI ↔ runtime 单机假设**:CLI 永远只跟 local runtime 通信;远程操作走 runtime↔runtime federation(Decision #48 形态 A)。

参考: ARCHITECTURE.md Decision #130, apps/ezagent_core/lib/esr/runtime.ex

### `@interface`

Behavior 声明的 action schema(args / returns / errors / modes)。**Single Source of Truth**:所有 UI(LiveView slash command / CLI / HTTP / MCP)从 `@interface` 自动派生,**不写两遍**。

参考: ARCHITECTURE.md §6.2,Decision #8

### Idempotency

`Ezagent.Idempotency` 模块 — bounded ETS LRU,去重重复 invocation(webhook 重试场景)。`ctx.idempotency_key` 设置后,dispatch step 2.7 自动检查 + record。

**v0 语义:收到即记,不是成功才记**(Decision #76)。失败 invocation 走 DLQ 兜底。

参考: ARCHITECTURE.md §5.7.3

### Install(install relation)

"session S 装了 socialware W" 的关系。**两物理部分**(landed P4,replace 了老 `:public_view` boolean 的两个 job):

1. **(identity)per-install record** —— 一个 `ConfigObject`(`subject = session_uri`,`key = "install:" <> socialware-ref`,`body = seed/override config`)。Verified:`Ezagent.Socialware.Installation`(`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`,`@install_key_prefix "install:"`,`@install_layer "session"`)。
2. **(behavior)socialware 的 bases+shape 挂进 session 的 `:kind_base` union** —— 经 declaration-free mount path(`Ezagent.Kind.mount/3` + `effective_set/2` `extra_part`)。

老的 `:public_view` SessionTemplate boolean field 已删除(session_template.ex 无 `:public_view`);其两个 job 分到 (1) install record(identity)+ (2) socialware-def `visibility_policy.web_anon_access`(anon gate)。`Ezagent.Socialware.PublicView`(`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex`)保留为 **compat facade**,delegate 到 `Ezagent.Socialware.Installation.web_anon_access?/1`。

参考: ARCHITECTURE.md §9,Decision #155,SPEC `docs/together/2026-06-26/specs/socialware-unification.md` §2.4,`docs/socialware-concepts.md` §0.3

### Invocation(`%Ezagent.Invocation{}`)

Ezagent actor 间通信的 envelope:

```elixir
%Ezagent.Invocation{
  target: URI.t(),         # 谁来处理(Kind 实例 URI + behavior/action 后缀)
  args: map(),
  mode: :call | :cast | :call_stream | :subscribe | :introspect,
  ctx: map()
}
```

参考: ARCHITECTURE.md §4,Decision #3 #5

### `handle_<action>(args, ctx)` — new-contract Behavior handler(post-2026-05-28)

Plugin author 的核心写入面。每个用 `action :foo, ...` 宏声明的 action MUST 有对应 `def handle_foo(args, ctx)` clause(`@before_compile` invariant — 缺失 raise CompileError)。

```elixir
def handle_send(%{message: msg}, ctx) do
  # args 已 validated against action's :args schema
  # ctx 含 framework-injected: :read / :self_uri / :kind_module / :caller / :reply / :sibling_slices(opt-in)
  {:ok, %{stored: true},                                  # result(per action's :returns schema)
   [
     {:set, :last_message_id, msg.id},                    # slice mutation effect
     {:emit, :message_sent, %{recipient: ...}},           # EventLog append effect
     {:notify, "session:#{ctx[:self_uri]}:events", _},    # PubSub broadcast effect
     {:dispatch, %Ezagent.Cmd{target: ..., ...}}          # cross-Kind dispatch effect
   ]}
end
```

返契约:`{:ok, result, [effect]} | {:ok, result} | {:error, reason}`。`:ok` 走正常 effect 应用 + reply 路径;`:error` 短路,**不应用任何 effect**,error propagate up through Router。

参考: ARCHITECTURE.md §6.0.2 + §6.0.3;`apps/ezagent_core/lib/ezagent/behavior.ex` `__before_compile__`;Decision #147 #150

### Kind

Ezagent 所有可寻址实体的"class"。每个 Kind 在 `Ezagent.<Category>.<KindType>` 模块定义。Kind 实例由 URI 标识。

三子类:**Session** / **Entity** / **Resource**(Decision #7)。

每个 Kind 实现 `type_name/0`、`behaviors/0`、`persistence/0`;`holds_cap?/2` 是**可选 callback**(PR-CC-2-v2, 2026-05-25 — 未导出时 dispatcher 用 `Ezagent.Kind.default_holds_cap?/2`)。

参考: ARCHITECTURE.md §3,Decision #1,PR-CC-2-v2

### `Kind.holds_cap?/2`(PR-CC-2-v2 chokepoint 可选回调, 2026-05-25)

Kind-level **可选 callback**(`@optional_callbacks holds_cap?: 2`),dispatch step 5.5 cap 检查路径。签名:

```elixir
@callback holds_cap?(entity_uri :: URI.t() | String.t(),
                     needed :: Ezagent.Capability.t()) :: boolean()
```

Kind 未导出该回调时,dispatcher 用 `Ezagent.Kind.default_holds_cap?/2` — 通过 `Ezagent.Identity.list_caps_for(entity_uri)` 读 entity 持有的 cap MapSet,然后 `Enum.any?(caps, &Capability.matches?(&1, needed))`。Kind 重写回调可加 Kind 特定 bypass(e.g. `:system` 调用方直接返 `true`)。

调度入口是 `Ezagent.Kind.holds_cap?/3`(三参数:entity_uri + kind_module + needed_cap),内部 dispatch 到 Kind 的 callback 或 `default_holds_cap?/2`。invariant `dispatch_uses_required_caps_struct_test.exs` 验证 `Ezagent.Kind.Runtime` 在 step 5.5 实际调用 `Ezagent.Kind.holds_cap?` 和 `behavior_module.required_caps()`。

这是 cap 检查的**唯一**生产入口 — `cap_check_only_at_chokepoint_test.exs` invariant 禁止 LV / controller / Behavior body 等别处调用 `Capability.matches?/2` (chokepoint 定义自身除外)。LV 的 "前置 cap 检查"(为了藏按钮)只允许作为 hint,**不能**是权威源。

参考: ARCHITECTURE.md §7.1 chokepoint 边界关切; references/architecture-invariants.md invariant 2/5; PR-CC-2-v2 SPEC; `apps/ezagent_core/lib/ezagent/kind.ex:172` (callback decl), `kind.ex:197` (default impl)

### KindRegistry

URI → pid 的运行时映射 + type_name → module 的间接层。`Ezagent.KindRegistry.put_new/2` 保证唯一性(撞 key reject)。

参考: ARCHITECTURE.md §5.4

### Matcher

Routing rule 的 predicate AST。组合子(`always` / `and` / `or` / `not`)+ Message-field matchers(`mention` / `from` / `text_contains` 等)。

Matcher 在 core,**因为读 core 数据 `%Message{}`**(Decision #70)。

参考: ARCHITECTURE.md §5.5

### Message(`%Ezagent.Message{}`)

Ezagent Entity-Entity 通信的 envelope(Chat 业务层):

```elixir
%Ezagent.Message{
  id:          String.t(),              # plain UUID (NO `message://` prefix; PR #149)
  sender:      URI.t(),
  mentions:    [URI.t()],
  body:        %{text: String.t(), attachments: [URI.t()]},
  ref_id:      String.t() | nil,        # ^reply-to 另一条 message id
  inserted_at: DateTime.t(),
  visibility:  :external_visible | :internal
}
```

**`visibility` rename(landed)**:旧 `:customer_visible | :operator_only` 已 rename 为 `:external_visible | :internal`(migration `20260628001000_rename_operator_only_visibility_to_internal.exs`;verified `apps/ezagent_core/lib/ezagent/message.ex:20,119-120`)。`:internal` = all-info superset(held turn output、operator/management unfiltered read);`:external_visible` = audience-visible。Per-message visibility 仍是 real revocation primitive(`external_feed.ex`)。

Message 是 core 概念(Decision #26),不是 chat plugin 专属。

参考: ARCHITECTURE.md §3.5 + §10.4

### MessageStore

`Ezagent.MessageStore` — Message 持久化 + query。`append/2` + `query/1`(7 维度:session_uri / mentioning / from / ref_chain / after_ts / before_ts / limit + order)。

参考: ARCHITECTURE.md §10.4

### Mode

Invocation 的 5 个 mode(Decision #5 #39):

| Mode | 语义 |
|---|---|
| `:call` | 同步,caller 等结果;to not-ready 必须 fail-fast |
| `:cast` | 异步 fire-and-forget;to not-ready 进 PendingDelivery buffer |
| `:call_stream` | 同步流式,caller 收 Stream.t() |
| `:subscribe` | 订阅 PubSub topic |
| `:introspect` | 读 Kind 内部状态,read-only |

### PendingDelivery

`Ezagent.PendingDelivery` — actor not-ready 窗口的 buffer。`:cast` to not-ready 进 buffer,ready 时 flush;`:call` to not-ready fail-fast 不 buffer(Decision #67)。

参考: ARCHITECTURE.md §5.7

### Phoenix.PubSub

actor 间 broadcast 总线。用于**不确定旁观者**(view 渲染、telemetry),**不是 inbound message 投递**(Decision #75 硬不变式)。

⚠️ Inbound message 永远走 `dispatch/1`,绝不裸 `PubSub.broadcast` 到 inbound topic。

参考: ARCHITECTURE.md §5.7.6

### Plugin

OTP application 形式的 Ezagent 扩展(Decision #17)。Plugin 注册自己的 Kind / Behavior / RoutingRegistry table。

判定原则(Decision #71):
- 读 core 数据 → core
- 读 plugin 专属 payload → plugin
- 业务概念(Chat / Workspace / Identity) → plugin
- 外部协议绑定 → plugin

参考: ARCHITECTURE.md §2.2 / §8

### Plugin 命名形态

- `:ezagent_behavior_<name>` — 单 Behavior plugin
- `:ezagent_adapter_<name>` — 单侧 transport adapter
- `:ezagent_plugin_<name>` — 复合 plugin
- `:ezagent_web_<name>` — Phoenix 入口 plugin

参考: ARCHITECTURE.md §13

### Principal

发起 Invocation 的主体。在 Ezagent 里 = Entity Kind 的实例(`agent://...` / `user://...`)。

### ReadyGate

`Ezagent.ReadyGate` — ETS 三态 ready 表(`:ready` / `:not_ready` / `:unknown`)。`use Ezagent.Kind` 宏在 GenServer init 完成后 announce_ready;`dispatch/1` 检查 ReadyGate 状态决定走哪条路径(直送 vs PendingDelivery vs fail-fast)。

参考: ARCHITECTURE.md §5.7,Decision #66

### Resource

Kind 三子类之一。**被操作,无 cap**。例:`workspace://...` / `resource://folder/...`。

"Shared referent needs identity"(Decision #63)— 被多方按身份引用的命名锚点需要独立身份,是 Resource 存在的根。

参考: ARCHITECTURE.md §3.1

### Receiver Kind

Plugin pattern for any Kind that consumes session messages and writes externally (Feishu, Slack, Discord, email, webhook, ...). Implements `Ezagent.ActionSet.Chat` (or equivalent) `:receive` action; bound to sessions via routing rules. External API call happens inside `invoke(:receive, ...)`,所以 dispatch + CapBAC + audit + idempotency 全部都过。

**Forbidden anti-pattern**: plugin GenServer that `Phoenix.PubSub.subscribe`s to `esr:session:*:events` and writes externally in `handle_info`. Bypasses dispatch, breaks `audit_row_count == external_side_effect_count` invariant. CI gate: `apps/ezagent_core/test/invariants/receiver_kind_pattern_test.exs`.

Reference impl: `apps/ezagent_plugin_feishu/`(`Ezagent.Entity.FeishuChat` + `EzagentPluginFeishu.Behavior.FeishuReceive`)。

参考: ARCHITECTURE.md Decision #127, memory `feedback_plugin_external_integration_is_receiver_kind`, `docs/notes/plugin-receiver-kind-contract.md`

### Recipe(axis A)

**Flavor-agnostic sandbox-content recipe** —— 一个 role 跑的 config-as-data。Module `Ezagent.Agent.Recipe`(`apps/ezagent_core/lib/ezagent/agent/recipe.ex:1`,moduledoc 注明 "symbol rename #127: `Ezagent.Role` → `Ezagent.Agent.Recipe`" — 老的 `Ezagent.Role` 已不存在,grep `defmodule Ezagent.Role` 全 codebase 空)。存为 ConfigObject:`subject_uri = recipe:<name>`,`key = "recipe"`,由 `Ezagent.Agent.RecipeRegistry`(`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex:8-9`,moduledoc "stored UNIFORMLY as a `ConfigObject`: `subject_uri = recipe:<name>`, `key = \"recipe\"`")read-through resolve。Recipe 承载 team / persona / tool-catalog / prompt —— **business semantics live here**。

**axis A vs axis B(#1059 / Decision #155)**:recipe(A)= "what an *agent* is built from"(build-time,agent-only);responsibility(B)= "what *function a principal* serves in a session"(runtime,cross-principal)。一个 member 可以是 built from `bot` recipe 且 carrying `bot` responsibility —— 两个 name 不必匹配。

参考: ARCHITECTURE.md §9,Decision #155,`docs/socialware-concepts.md` §0.5,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.2/§1/§4.7

### Responsibility(axis B; `role_name`)

一个 team member 填的 **responsibility slot**(`bot`/`reviewer`/`orchestrator`/`supervisor`),经 `{:role, name}` routing。**"role" 一词在 Ezagent 内 ONLY 留在这个 responsibility 意义** —— `role_name` 是 responsibility identifier;recipe 是该 role 跑的 *content*(由 `lookup_role_recipe/1` 查,`apps/ezagent_domain_workspace/.../role_step.ex`)。Lingering helper name `lookup_role_recipe` = "look up the recipe for this role name" —— consistent,但未来 cleanup 可 rename 为 `lookup_recipe_for_responsibility` 去掉表层 overlap。

Verified:`{:role, name}` routing(`receiver.ex`、`resolver.ex`)、`role_name` on membership(`agent.ex`、`role_name_conflict/3`)。kanban 今天 **不** 用 `role_name` / `{:role,name}` routing —— 只 recipe + passive + per-instance mount(responsibility/routing layer 是 target,gap by §3 of socialware-unification SPEC)。

参考: ARCHITECTURE.md §9,Decision #155,`docs/socialware-concepts.md` §3,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.2/§1/§4.7

### RoutingAdmin

Synthetic singleton Kind(`routing-admin://default`,Phase 5 PR 4 落地 Decision #125)— 不是真实业务实体,而是把 RoutingRegistry 的 add/delete/disable/enable 操作包成 Behavior(`Ezagent.ActionSet.RoutingAdmin`),从而让 routing 规则修改也走 `Invocation.dispatch` → 命中 CapBAC step 5.5。non-admin 没有 `routing_admin` cap 调用 → `:unauthorized` + audit row。

⚠️ 是 "**operation-as-Kind**" 模式实例 — 当某类高权限操作没有自然 owner Kind 时,合成一个 singleton 把它们集中到一处 cap-gate。RoutingLive(`/admin/routing`)dispatches 经此走;CLI mix task 也走同路径。

参考: ARCHITECTURE.md Decision #125,SPEC Phase 5 P5-D6

### Routing matcher: in_session

`{:in_session, "session://X"}` — gates a routing rule to messages **originating in a specific session**。新 matcher 加于 post-Phase-5 Plan B(Decision #128)。其他 matcher(mention/from/text_contains/text_matches/always/...) 都看消息内容,只有 `in_session` 看 `msg.session_uri` 字段。**必须配合 stored_msg fix**(Decision #129)否则 always false。

典型用法:Feishu binding 加规则 `in_session(session://main) → [feishu://oc_xxx]`,确保只 session://main 的消息转 Feishu,不污染其他 session。

参考: ARCHITECTURE.md Decision #128, Matcher.ex `in_session/1` 构造器

### RoutingRegistry

外部 key → URI(s) 的运行时映射。Plugin 自声明 table(`declare_table/3`,含 `duplicate_keys: boolean` + 可选 `reverse_index`)。

- Unique-key table 用 `put_new`(撞 key reject)
- Duplicate-key table 用 `put`(append 语义)

参考: ARCHITECTURE.md §5.4,Decision #65

### `Ezagent.Router`(post-2026-05-28 dispatch primitive)

SPEC PR #445 §2.1 的 dispatch primitive。Take `%Ezagent.Cmd{target, action, args, ctx}` envelope,返 `{:ok, result} | :ok | {:error, dispatch_error}`,内部完成 URI 解析、cap 检查、idempotency、workspace 隔离、audit 写、Behavior handler 路由、effect 应用、result post-processing。

Phase 1(PR #451)Router `wraps` 老 `Ezagent.Invocation.dispatch/1` + `Kind.Runtime.handle_dispatch/4` 通过 `Cmd → Invocation` 翻译,additive 不动既有路径;Phase 2+ direct handler invocation through `Kind.Host.handle_call/cast`,绕开 legacy `invoke/4` shim for new-style Behaviors。

13-step dispatch flow 见 ARCHITECTURE §6.0.1;module moduledoc 是 normative。

公开 API:
- `dispatch(%Cmd{})` — 标准 dispatch
- `dispatch_saga(saga, ctx)` — hand a `%Ezagent.SagaRunner.Saga{}` to SagaRunner

参考: ARCHITECTURE.md §6.0.1;`apps/ezagent_core/lib/ezagent/router.ex` moduledoc;SPEC PR #445 §2.1;Decision #147 #148

### Runtime state(slice)

L3 per-instance dynamic slice of a Kind's Behavior state —— persisted in `kind_snapshots`,rehydrate on restart。The live, mutable, instance-specific state(kanban task list contents、conversation messages、turn state、membership、board node positions、settlement state)。Verified substrate:`Ezagent.ActionSet.KindBase`(`:kind_base` slice,`apps/ezagent_core/lib/ezagent/behavior/kind_base.ex`)、`Ezagent.MessageStore`(`apps/ezagent_core/lib/ezagent/message_store.ex`)、`Ezagent.Kind.Snapshot`(`apps/ezagent_core/lib/ezagent/kind/snapshot.ex`)。**Cannot hold**:reusable definitions(recipe 不 per-instance 复制,由 URI ref 从 L2 引);business semantics in schema form(`kind_snapshots` 是所有 Kind 共用的一张表,kanban task 是 slice value,不是 `kanban_tasks` 表)。

参考: ARCHITECTURE.md §10.3,Decision #155,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §0.3/§1

### `Ezagent.SagaRunner`(framework-internal,post-2026-05-28)

Stateless linear saga 原语(SPEC §5.4)。当 Behavior handler 返 `{:saga, %Ezagent.SagaRunner.Saga{}}` effect,framework 把 saga handle 给 SagaRunner 执行 forward + compensate steps。

**Compensation 是 best-effort partial restore,NOT atomic rollback**(SPEC r2 codex HIGH-5 closure):
- pure-state mutations(slice changes)IS 可逆 IFF compensate function snapshot-before-forward + restore-on-rollback
- already-sent PubSub broadcasts、already-dispatched cross-Kind messages、already-fired external IO(HTTP / file)、already-terminated Kinds **不可逆**;compensate 可以尝试 counter-action(DELETE 文件 / POST "rollback")但原 side effect 已经发生
- 如 compensate 自身失败,saga 写 operator-repair marker(UUID + log line at `:error` level)+ abort compensation walk + error tuple 含 successfully-compensated steps list + failed-compensation step

Plugin authors 写 saga 时 **MUST** design steps assuming partial-failure recovery may require operator intervention。Saga 设计模式见 SPEC §5.4 + Ezagent.SagaRunner moduledoc。

参考: ARCHITECTURE.md §6.0.5;`apps/ezagent_core/lib/ezagent/saga_runner.ex`;Decision #147 #148

### `Ezagent.SnapshotStore`(framework-internal,post-2026-05-28)

Per-Kind state snapshot store(SPEC §5.2)。包 existing `kind_snapshots` 表,API 是 plugin-invisible 4 个函数:`latest/1` + `write/3` + `delete/1` + `count/0`。

**Snapshot policy is framework-decided**(r2 codex HIGH-3 closure):per-Behavior `persistence/0` enum 不再存在 for new-contract Kinds。policy 集中在 SnapshotStore 一个模块的决策树:
- **every N events**(default 100,configurable `:ezagent_core, :snapshot_every_n_events`)
- **on graceful terminate**(Kind.Host terminate hook 最后 final write)

Phase 1 coexistence with legacy `Ezagent.Kind.Snapshot`:legacy module 继续 production write path until Phase 2 migrations cut Kinds over to Behavior-emitted effects;SnapshotStore 是 Phase 2+ 写路径,Phase 1 stake-in-the-ground for StateRebuilder + EventLog 依赖。两者 read/write 同一表 `kind_snapshots`,但不竞争 — legacy writers 写 per Kind 声明的 `persistence/0`,SnapshotStore 写 per framework-decided 策略。Phase 2 migrated Kind 不再声明 `persistence/0`,只一个 writer 触每行。

**Plugin code MUST NOT import** — SPEC §11 grep gate。

参考: ARCHITECTURE.md §6.0.5;`apps/ezagent_core/lib/ezagent/snapshot_store.ex`;Decision #147 #150

### `Ezagent.Kind.StateRebuilder`(framework-internal,post-2026-05-28)

Rebuild Kind 的 in-memory state from persisted snapshot(Phase 1)+ (Phase 2+) fold subsequent events on top(SPEC §5.3)。

**Lazy-on-first-load**(OQ-8 decision):rebuild 发生在 Router dispatch 到 KindRegistry 未有的 entity URI 时,**NOT** at application boot。Router lookup 失败 → spawn Kind via `Kind.spawn/2`;`Kind.Host.init/1` calls StateRebuilder。

Kind module 可选 implement `rebuild_from_snapshot/1`(REQUIRED for custom semantics — 否则 default path 使用 snapshot.state 直接)+ `rebuild_from_events/2`(OPTIONAL — Phase 2+ events-as-source-of-truth 用)。

Generalises per-domain `BootReconciler` pattern(today only `Ezagent.ExternalMirror.BootReconciler` — stays as-is Phase 1,Phase 2+ refactors to delegate)。

**Plugin code MUST NOT import** — SPEC §11 grep gate。

参考: ARCHITECTURE.md §6.0.5;`apps/ezagent_core/lib/ezagent/kind/state_rebuilder.ex`;Decision #147 #150

### `Ezagent.LegacyBehaviorAdapter` — DELETED(Phase 3 PR #464,2026-05-28)

**Historical entry — for git archaeology only.**

Existed in Phase 1(PR #451)+ Phase 2(PR #462)as a dispatch-equivalent(**NOT replay-equivalent**,SPEC r2 codex HIGH-2 closure)bridge from new `Cmd` / handler-effects pipeline to legacy `invoke/4` Behaviors。Phase 3(PR #464)deleted the adapter + retired `invoke/4` to `@optional_callbacks` once every concrete Behavior had migrated to new contract(Phase 2 + 2.5)。

The `@callback invoke/4` declaration is kept in `Ezagent.ActionSet` only so a stale Behavior referencing it surfaces a precise CompileError rather than silent dispatch failure。**No runtime path consults `invoke/4` post-Phase 3。**

任何 tutorial / blog post / forensic note 引用 `Behavior.invoke/4` 作为 dispatch 入口 = 2026-05-28 之前写的 + stale。

参考: ARCHITECTURE.md §6.0.6 + §6.1;Decision #148 #151

### Refresh Surface

World 中一个可独立重建的 renderer 状态投影。它由插件页面的
`refresh_state/2`，或 `Ezagent.World.UiSurfaceProvider.refresh_surfaces/0`
声明的 standalone surface 提供；声明包含 renderer `component`、当前 URI 的
`target` 和 `state_builder`。`RefreshSurfaceRegistry` 统一校验、聚合并按
component 查找，非法项不进入运行时。

刷新不是完整页面重载：`state_builder.refresh_state(uri, ctx)` 必须返回当前
presenter 可见、JSON-safe 的 partial state。World 把它封装为
`world:surface_state`，React 对目标 surface 做 shallow merge。

参考: ARCHITECTURE.md §2.3.1，`Ezagent.World.RefreshSurfaceRegistry`，Decision #165

### Session

Kind 三子类之一。**Routing context owner**——IRC 的 channel 类比;RoutingRules 挂在 Session 上;消息 dispatch 时 Session 决定 N 个 receiver。

⚠️ 不是 Phoenix session(cookie / web session)。

参考: ARCHITECTURE.md §3.1,Decision #9

### Shape

一个 socialware 的 **flow-specific behavior(s) + recipe**,把 composed bases 变成 *particular* flow。chat 的 shape = **conversation turn protocol** —— `Ezagent.ActionSet.Turn`(`apps/ezagent_plugin_*` 内,moduledoc "Socialware orchestration state machine. Owns the `:turns` slice")。`Turn` **NOT a base**:它 specific to conversation flow(kanban 没 turn),所以是 chat 的 shape,不是 general capability substrate。kanban 的 shape = **board/task protocol** —— `Ezagent.ActionSet.Kanban`(node/stage/claim/status/artifact actions)。**Base 是 general;shape 是 flow-specific**。两个 socialware compose *相同* bases 但 shape 不同(chat vs 一个假想的 "board-chat" 都 compose orchestrator+surface 但 shape 不同)。

参考: ARCHITECTURE.md §3,Decision #155,`docs/socialware-concepts.md` §0.4,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §1

### Slice(state_slice)

每个 Behavior 拥有的 state 切片,在 Kind 模块的 state map 里独立 key。Behavior 只能读写自己声明的 slice(Decision #16)。

**Post-2026-05-28(Phase 2 migration)**:slice 是 **framework-internal** —— plugin authors 不再直接接触。读取通过 `ctx[:read].(key, default)`(framework 在 handler 前注入 read function);写入通过返回 `{:set, key, value}` effect(framework 在 `apply_effects/2` bucketise 后 commit 到 snapshot)。pre-Phase-2 的 `invoke(action, slice, args, ctx)` 第三参 `slice` map 现在是 `@optional_callbacks` 唯一可见路径,production 代码不走该路径。

跨 Behavior slice 读取(sibling slice)仍是 opt-in via `reads_sibling_slices/0` callback(Decision #124 / invariant 18 不变)。

```elixir
# Kind GenServer state(framework 内部 — plugin 作者不见):
%{
  uri: ...,
  caps: ...,        # Identity Behavior slice
  chat: ...,        # Chat Behavior slice
  routing: ...,     # SessionRouting Behavior slice
}

# Plugin author 看到的接口:
def handle_send(args, ctx) do
  current = ctx[:read].(:send_cursor, 0)
  {:ok, %{}, [{:set, :send_cursor, current + 1}]}
end
```

参考: ARCHITECTURE.md §6.0(new contract slice access);Decision #16, #150

### SliceChange

已提交 Kind slice 变化的通用通知。对 World UI 而言，它不是插件到浏览器的
专用事件：`WorldLive` 是唯一的刷新消费者，按当前声明的 refresh surface 和
目标 URI 调度投影，再通过 `world:surface_state` 交给 React。未挂载 surface、
非法声明或 provider error 都 fail-closed，不能以直接 PubSub-to-browser
广播绕过 caller-scoped projection。

参考: ARCHITECTURE.md §2.3.1，Decision #165

### Snapshot

Kind state 的 SQLite 持久化(`kind_snapshots` 表)。

**Pre-2026-05-28(legacy `Kind.persistence/0` enum)**:5 种策略 — `:on_change` / `{:snapshot, :periodic, ms}` / `:on_terminate` / `:ephemeral` / `:external`,plugin author 在 `Kind.persistence/0` 选(Decision #27)。

**Post-2026-05-28(Phase 2.5+ via SPEC §5.2)**:snapshot policy is **framework-decided** — plugin authors 不再 tune。policy 集中在 `Ezagent.SnapshotStore` 一个 module 决策树:
- **Snapshot every N events**(default `100`,configurable via app env `:ezagent_core, :snapshot_every_n_events`)— framework EventLog 每 aggregate URI 增 event counter,到 N 时 framework call `SnapshotStore.write/3` with current Kind state
- **Snapshot on graceful terminate** — framework `Kind.Host.terminate/2` 在 process exit 前 final write

没有 `:on_change` / `:on_terminate` / per-pattern enum。新 Kinds 走 framework-decided 路径(codex r2 HIGH-3 closure:"framework decides policy, plugin authors pick the pattern")。legacy `persistence/0` callback 在 `Ezagent.Kind` 仍是 `@callback`,Phase 2 + 2.5 migrated Behaviors 的 Kind 仍 declare(coexistence)。Phase 2+ 新 Kinds 不再 declare —— SnapshotStore + StateRebuilder 接管。

参考: ARCHITECTURE.md §10.1 + §6.0.5;Decision #27, #115, #147(SPEC §5.2);`Ezagent.SnapshotStore` moduledoc

### Socialware

**Human+program hybrid FLOW** —— composes ≥1 **base** + 一个 **shape**,directly user-operable。名字是 deliberate:socialware 被 *operated* —— 一个 human(operator/supervisor)跟一个或多个 agent 在一个 shared、observed 的 turn surface 内协作,human 可以 hold / settle / approve / take over program output 在它到达 external audience 之前。Pure "app" 隐藏 internals 无人值守;socialware **exposes its internals to a responsible human 且把 human gating 变成 first-class**。这是它叫 "socialware" 而非 "app" 的整理由。

Two verified instances(both `defmodule`-confirmed on `origin/main`):**chat** = world Conversation surface(`Ezagent.World.ConversationActions` + `ConversationData` + `Conversation.tsx`;generic,**NO business semantics**;composes orchestrator base + surface base + conversation shape `Behavior.Turn`)+ **kanban** = board WITH task semantics(task semantics 经 recipe/responsibility + routing 表达;mechanism 是 `Behavior.Kanban` L1 code;**今天 kanban 是 recipe-only,无 `role_name`/`{:role,name}` routing** —— 见 Responsibility 条目)。

参考: ARCHITECTURE.md §1 + §3,Decision #155,`docs/socialware-concepts.md` §0.1/§0.2,SPEC `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` §1

### Stub(authz stub)

Phase 1-3c 的 `authz_check/2` 显式 permissive 实现:**永远 grant,emit `:stub_grant` telemetry**。带 `PHASE-3D-STUB: DO NOT REMOVE` 注释。Phase 3d 起 in-place 替换为真实 cap 检查 + `:granted`/`:denied` telemetry(Decision #82)。

### Template — Class

模块级 Template,开发者写。实现 `@behaviour Ezagent.Kind.Template`(`validate/1` + `instantiate/2` 等 callback)。决定"这类东西如何 instantiate"。

例:`Ezagent.Session.Feishu2CC.Template` 是 Feishu↔CC session 的 Template Class。

参考: ARCHITECTURE.md §9.1,Decision #64

### Template — Instance

运行时 Resource Kind 实例,**用户创建**(不是开发者写)。携带具体预设值(folder/agent/settings/env)。被 `/session:new` 引用,merge 进 instantiate 流程。

例:`workspace://esr-dev` 是 Workspace Template Instance 实例;`esr-dev` 是用户起的名字。

`/session:new` 走流程:拿 Workspace state → 调 `TargetSessionClass.validate/1` 检查 → 调 `TargetSessionClass.instantiate/2` 起 session。

参考: ARCHITECTURE.md §9.2,Decision #64

### Type Name(`type_name` / `kind_type`)

Kind 类型的稳定 ID(不是模块名字符串)。`use Ezagent.Kind, type_name: :agent` 声明;`kind_snapshots.kind_type` 字段存这个;`Ezagent.KindRegistry` 维护 `type_name → module` 映射。

模块改名时 mapping 改一处,snapshot 不动。

参考: ARCHITECTURE.md §1.2 差异 2,Decision #62

### Unroutable

零匹配路由的 message — routing 算出 0 个 receiver。**必须 telemetry + DLQ unroutable**,不能静默(Decision #68)。

### URI

Ezagent 寻址 scheme。格式: `<scheme>://<segment>/<...>/behavior/<behavior_name>/<action>`(后半段可选,仅 Invocation target 用)。

例:
- `agent://allen-小满` — Entity 实例
- `session://feishu-cc/cc-7f3a` — Session 实例
- `workspace://esr-dev` — Resource 实例
- `agent://arch-a/behavior/chat/receive` — Invocation target

参考: ARCHITECTURE.md §3.4,Decision #6

### `user://admin` → `entity://user/system/admin`(SPEC v3 canonical)

Bootstrap principal,系统首次启动自动创建,持 all-caps。**不可 revoke**(结构性 invariant 在 `Ezagent.Capability.revoke/2` 集中检查)。SPEC v3 (Phase 9) 之后 URI 形态从 2-segment `user://admin` 变成 3-segment `entity://user/system/admin`;legacy URI 不再 parse。

PR-CC-1 (2026-05-25) 之后该 URI 注册在 `Ezagent.SystemPrincipal.Catalog`(见下),不再通过 inline `URI.parse` 合成。`Identity.admin?/1` 仍只对 `Catalog.admin_uri()` 返 true — 它是唯一的 bootstrap admin singleton。

参考: ARCHITECTURE.md §7.6,Decision #81;PR-CC-1 (2026-05-25)

### `Ezagent.SystemPrincipal.Catalog`(PR-CC-1, 2026-05-25)

`ezagent_core` 内 **14 个 `system://` dispatch principal URI** 的封闭 allowlist 模块(`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`),每个 URI 配套该 principal 持有的 cap 集 + 用途描述。取代 PR-CC-1 之前散布在 Behavior body 里的 ambient authority 模式(系统内部 dispatch 通过假装是 `User.admin_uri()` 拿到通配 cap)。

当前 14 个 system principal 包括:`system://bootstrap`、`system://boot-reconciler`、`system://adapter-install`、`system://chat-router`、`system://chat-reply`、`system://worker-publish`、`system://template-materialize`、`system://orchestrator-tools`、`system://session-internal`、`system://agent-internal`、`system://workspace-loader`、`system://lv-anon-mount`、`system://lv-loader`、`system://test-bootstrap`(参见 `catalog.ex:116` entries/0)。

```elixir
defmodule Ezagent.SystemPrincipal.Catalog do
  def entries, do: [
    {"system://bootstrap", [bootstrap_wildcard()]},
    {"system://boot-reconciler", [Capability.cap(:session, ExternalMirror, :any)]},
    # ... 12 more
  ]
  def member?(uri), do: # is uri in entries?
  def caps_for!(uri), do: # cap list, raises if not in catalog
  def uris, do: # list of all catalog URIs
end
```

`Ezagent.SystemPrincipal` 模块(catalog 的 runtime 封装,`apps/ezagent_core/lib/ezagent/system_principal.ex`)暴露 `ensure/1`(幂等 spawn principal Entity 让 dispatch 看到正确 cap 集)和 `caps/1`(legacy 兼容入口,PR-CC-2b 之后会被 cap-snapshot 契约替代)。

**结构性不变式**:`no_wildcard_system_principals_test.exs` invariant — 生产代码内 grep 禁止 `URI.parse("system://...")` 这种内联合成(Catalog / SystemPrincipal 模块自身除外)。所有需要系统身份的内部调用必须通过 `SystemPrincipal.ensure/1` + `Catalog.caps_for!/1` 获取。

跟 `entity://user/system/admin` 的关系:User Kind admin singleton(`Identity.admin?/1` 唯一返 true 的 URI)是**用户身份**;Catalog 中的 `system://<name>` 是**系统 dispatch principal 身份** — 同一系统两种 principal,前者由 bootstrap 创建,后者由 PR-CC-1 引入封闭化散见的"假装管理员"模式。两者都不可 revoke,但路径不同。

参考: ARCHITECTURE.md §7.6;PR-CC-1 SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md`;`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` + `system_principal.ex`

### `lv_cli_parity` invariant(PR-CC-2-v2, 2026-05-25)

`apps/ezagent_core/test/invariants/lv_cli_parity_test.exs` 扫描所有 LV 模块的 `handle_event/3` clauses,对每个 event 通过显式映射表 `@event_to_cli` 归类到 4 个分类之一:

- **`:cli`** — 有对应 `mix esr <kind> <action>` 或 legacy `mix ezagent.*` 任务(operator-facing 命令);
- **`:ui_only`** — 纯 UI state(filter / toggle / switch view / pagination)—— 设计上免除 CLI parity;
- **`:pty_stream`** — terminal byte 输入 / resize(`Behavior.Pty`)—— LV 走 keystroke 流式,CLI parity 是单向 (`mix esr agent write` 可种 PTY 输入,但用 one-shot mix task 操作 TUI 不实际);
- **`:deferred`** — 已知 gap,该行携带 `docs/futures/todo.md` bullet 路径,后续 PR 可定位关闭(`feedback_dont_defer_what_is_solvable_now` 要求 deferred entry 解释为什么不能 in-PR 关闭)。

新加 LV `handle_event("foo", ...)` clause 不加 `@event_to_cli` 行 → test 失败列出 `"foo"` 未映射。这是 architectural goal 的 invariant 守门 — 而**不是**"每个 event 必须有 mix esr 命令"的强约束;UI-only 操作 / PTY 流式 / 已记录 deferred 都允许通过。

为什么:Allen 的 production-usability 选择标准 (P4) — LV 是给人用的,CLI 是给运维 / 脚本用的;LV 加 event 时必须明确 CLI parity 状态 — 实现 / 豁免 / deferred 三选一,不能默认遗忘。

参考: P4; PR-CC-2-v2 SPEC; `apps/ezagent_core/test/invariants/lv_cli_parity_test.exs:29-90`(分类 + 映射表)

### View

`Ezagent.View` behaviour — outbound 渲染抽象。每个 transport(LiveView / CLI / Feishu / Slack)实现自己的 `Ezagent.View.render/2`,把 Invocation 渲染成本 transport 的输出格式。

参考: ARCHITECTURE.md §12.7

### Workspace

Template Instance 的代表性例子。**薄 Resource Kind**——state 是 folder/agent/settings/env 预设 bundle;持有命名身份(`workspace://esr-dev`);被 session/user/repo/plugin-config 多方按 URI 引用。

参考: ARCHITECTURE.md §3.1.1,Decision #63

### `Ezagent.WorkspaceRegistry`(Phase 7 PR 31,Phase 9 PR-7 降级)

第 5 个 ETS Registry,在 Kind/Behavior/Routing/Spawn/Template Registry 之外补的 session→workspace 反向 lookup。**Phase 7-8c 时**:authoritative source of truth ——Workspace.Loader.invoke_template 在 spawn session 后 `bind(session_uri, workspace_uri)`;dispatch 通过 `lookup(session_uri)` 拿到 workspace_uri 传给 `Resolver.resolve/4`。**Phase 9 PR-7 之后(SPEC v3 §3.6 URI scheme 统一)**:**降级为 consistency cache**。所有 per-tenant URI(session/template/resource 都加了 workspace 段)now carry workspace structurally;`Capability.workspace_of/1` 直接从 URI 字符串 O(1) 提取,no ETS lookup。WorkspaceRegistry binding **必须等于** session URI 的 workspace 段(invariant test `all_per_tenant_uris_have_workspace_test.exs` "registry binding matches URI workspace segment" 守住)。

参考: ARCHITECTURE.md Decision #135 + #145,IMPL-7-1 in docs/phase-specs/phase7/DECISIONS.md,SPEC v3 §3.6

### Deployment unit(部署单元)— Phase 9 framing

Workspace 的**正式名**。Phase 9 之前 workspace 是"配置 bundle(members + session_templates + routing_rules)";Phase 9 之后是完整 deployment unit,4 个隔离维度结构性保证:(1) entity URI 携带 workspace 段;(2) Capability 携带 `workspace_uri`;(3) Dispatch step 5.6 强制 caller/target workspace 一致(除非有 cross-workspace cap 或 system 成员身份);(4) per-tenant 表 `workspace_uri` NOT NULL 列。Multi-host SaaS 部署只是把不同 workspace 跑在不同主机上 —— 架构已经 ready。"deployment unit" 是首选术语;"tenant" 太 SaaS-y、"namespace" 太 Kubernetes-y。

参考: `docs/notes/workspace-as-deployment-unit.md`,ARCHITECTURE.md Decision #145

### `workspace://system` workspace + Keycloak realm-admin 模型(Phase 9 PR-8)

Phase 9 §13 的结构特例:`workspace://system` 是**真实** workspace 但 `visible: false`(不在普通 workspace 选择器显示)。Bootstrap admin(`entity://user/system/admin`,Phase 8c 之前是 `entity://user/default/admin`)是 system workspace 成员。System 成员通过**成员身份**(not 显式 cap grant)持跨 workspace 权限 —— `Capability.cross_workspace?/2` arity-2 检 `caller_workspace == "workspace://system"`,true 则 step 5.6 通过。**Workspace 选择器分支**(SPEC §6.4 amendment 3):system 成员 click 其它 workspace = 上下文切换(no logout,`:current_workspace_uri` 变 `:current_entity_uri` 不变);普通 user click 锁定的 workspace = 拒绝 + "Sign in to <ws>" 提示页(显式选 logout 才登出,不静默)。比 Keycloak 多一个 "Operate on as system/admin" UI 标签,但本质相同 —— master-realm 管理员可以管理子 realm 而保持自己身份。

参考: ARCHITECTURE.md Decision #145,SPEC v3 §13(`docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md`)

### 3-segment URI(SPEC v3,Phase 9 PR-2 + PR-7)

Phase 9 之前所有 URI 都是 2-segment authority(`<scheme>://<type>/<name>`,Phase 7 PR 31 SPEC v2)。Phase 9 之后所有 per-tenant scheme(`entity://`, `session://`, `template://`, `resource://`)升级到 3-segment:`<scheme>://<type>/<workspace>/<name>`。`workspace://<name>` 和 `system://<type>/<name>` 不变(workspace 是 tenant root 本身,system 是 cross-cutting)。**为什么(Option A)**:URI 自描述,不需要 out-of-band lookup;auth token 携带完整身份;同 handle 在两个 workspace 就是两个独立 entity(隔离干净);cap matching O(1) 从字符串提取。**不做** Option B(envelope 携带 workspace),因为 ambient context 容易忘 + 数据泄露风险。`Ezagent.URI.new!/1` parse-time 拒绝 2-segment per-tenant URI(`ArgumentError: <scheme> URI must include workspace segment`)。

参考: ARCHITECTURE.md Decision #145,SPEC v3 §3,`docs/notes/uri-design.md` §5.15

### Cross-workspace cap / Cross-workspace dispatch(Phase 9 PR-4 + PR-8)

`Capability.workspace_uri == :any` 即 cross-workspace cap —— 持有者可以 dispatch 到任意 workspace。Bootstrap admin cap 默认是这个形态(`kind: :any, behavior: :any, instance: :any, workspace_uri: :any`)。**Cross-workspace dispatch enforcement** 在 `Ezagent.Kind.Runtime.handle_dispatch/4` 的 step 5.6(在 CapBAC step 5.5 之后):caller workspace == target workspace OR 任意 cap with `workspace_uri: :any` OR caller 是 `workspace://system` 成员(Keycloak realm-admin)。拒绝时返 `:cross_workspace_denied`(distinct from `:unauthorized`,inbound transport 用不同 emoji 区分:`THUMBSDOWN` vs `NO`)。**Gate-verified**:临时禁 5.6 → 2/6 invariant test 失败,真 gate。

参考: ARCHITECTURE.md Decision #145,SPEC v3 §5 + §13.3,invariant test `cross_workspace_isolation_test.exs`

### AgentTemplate(Phase 7 PR 37)

Template Class 之一,在 `Ezagent.Kind.Template` umbrella(ezagent_core)下。Slice 是**指向 sandbox 目录的指针 + cap policy**(`working_directory` / `claude_config_dir` / 可选 `settings_path` / 可选 `mcp_config_path` / `default_caps`),**不**模型 prompt/model/tools——那些在 sandbox 内的 `.claude/settings.json` 等文件里。URI `template://agent/<name>`,no version suffix(AgentTemplate 是人工编辑、非版本化的;Phase 8+ 才考虑 blueprint synthesis)。`Ezagent.Entity.Agent.spawn/4`(PR 40)按 template 实例化 worker agent。

⚠️ 别跟 `Ezagent.Kind.Template`(umbrella behaviour)或 `SessionTemplate` 混。AgentTemplate 是 **一种** Template Class;Template umbrella 包括 GenericSession/CcChannelInstance/AgentTemplate/SessionTemplate 等。

参考: ARCHITECTURE.md Decision #136,SPEC §AgentTemplate

### SessionTemplate(Phase 7 PR 38)

Template Class 之一,表示**一个团队的形状**——agent_slots(命名位置 + 各自的 AgentTemplate URI)+ routing_rules(slot-name 引用,实例化时 resolve)+ orchestrator_template_uri + default_workspace_uri + parent_template_uri(fork lineage)+ version_hash + 可选 version_tag。URI `template://session/<name>@<hash>`(git-style content-addressable)。**Instantiate** 通过 `Ezagent.Entity.Session.spawn_from_template/2`(the Generator),产新 session URI + 内嵌 orchestrator + worker agents。**Fork** 通过 `Ezagent.Entity.SessionTemplate.fork(parent_uri@hash, new_name)` 创建新 template row 并立即实例化。

参考: ARCHITECTURE.md Decision #136, #143,SPEC §SessionTemplate

### Generator(Phase 7)

非 agent——是**创建 session 的程序**。具体入口 `Ezagent.Entity.Session.spawn_from_template(session_template_uri, owner)`,读 SessionTemplate 配置 → 新 session URI → spawn orchestrator agent(scope-bounded delegation caps)+ 各 worker agent → 装 routing rules → 初始化 working-copy template state。每个新 session 自带它的 orchestrator 实例。

⚠️ 别跟 **Orchestrator** 混。Generator 一次性跑(创建 session);Orchestrator 是 session-internal 长寿 LLM-driven agent,管 session lifetime 内的 template refinement。Allen 2026-05-18:"创建一个新 session(自带 orchestrator)的一段程序是 generator"。

参考: ARCHITECTURE.md Decision #136,SPEC §Generator

### Orchestrator(Phase 7,大写以区别于通用名词)

每个 session **内** 一个的 LLM-driven manager agent,从 SessionTemplate 的 orchestrator_template_uri 实例化。持有 6 个 MCP 工具(`add_agent_slot` / `remove_agent_slot` / `update_agent_template` / `write_matcher` / `update_template` / `save_template_as` / `list_templates`),通过标准 `Ezagent.Invocation.dispatch/1` 调用 Ezagent action,scope-bounded delegation cap(`{:within_session, S}` + `{:spawned_by, orchestrator_uri}`)守护它只能在自己 session/lineage 内行使权力。**不能 fork**——fork 是 SessionTemplate registry 操作,orchestrator 只能 `update_template`(原地 commit 新 hash)或 `save_template_as(new_name)`(另存)。

参考: ARCHITECTURE.md Decision #136, #137,SPEC §Orchestrator,D7-1 / D7-3 / D7-10

### Scoped Delegation(v1,Phase 7 PR 42)

`Ezagent.Capability.instance` 字段新增两个 tuple shape:`{:within_session, %URI{}}` 和 `{:spawned_by, %URI{}}`。Phase 7 闭幕 = Ezagent v1 release,正式退役 v0 "no delegation" baseline(ARCHITECTURE §17.6)。CapBAC step 5.5 的 `instance_match?/2` 处理 tuple:within_session 用 URI 字符串前缀(带 `/` 边界)匹配;spawned_by 用 lineage 注册表 lookup(PR 42 ship 占位,PR 40 接 Agent.spawned_by slice + lookup)。**关键性质:scope tuple 只收窄,不放宽**——`{:within_session, A}` 不会让 cap 跨到 session B。`:any` 仍然是唯一通配符。

参考: ARCHITECTURE.md Decision #137, §17.6, §7.3, §7.5;capability_test.exs "scope-bounded instance tuples"

### Template version hash(Phase 7 D7-10)

Git-style 不可变内容寻址 + 可变 tag overlay。每个 SessionTemplate row 的 URI 是 `template://session/<name>@<version_hash>`,hash = SHA-256 over slice content(canonical encode,排除 timestamps + created_by);**hash 一旦写就不可变**(content-addressable),orchestrator `update_template` 产新 row 新 hash 不覆盖老。tags 在另一个 `template_tags` registry 存 `(name, tag) → version_hash` 可重新指向。已实例化 session snapshot the resolved hash at instantiate time 不受后续 update 或 tag move 影响。

参考: ARCHITECTURE.md Decision #143,SPEC §Template version semantics

### `template:read` / `template:write` / `template:instantiate`(Phase 7)

三种 template-scoped cap kinds,精细控制 SessionTemplate 操作:
- `template:read`:orchestrator 的 `list_templates` 工具看到哪些 candidate
- `template:write`:orchestrator 的 `update_template`(merge back parent)需要 parent 的 name-scoped write cap;`save_template_as` 不需要(创建新 template 用通用 template-creation cap)
- `template:instantiate`:`Ezagent.Entity.Session.spawn_from_template/2`(Generator)的 CapBAC gate;默认 grant 给任何拥有该 template read cap 的 user

参考: ARCHITECTURE.md Decision #136, §7.3

### `mix ezagent.bootstrap`(Phase 7 PR 33)

一键安装命令,把现存的 `ezagent.home.init` + `deps.get` + `ezagent.home.adopt_db` + `ecto.create+migrate` + 健康检查包成 single mix task。canonical install entry for dev team's "quasi-production" deployments。Idempotent(已 bootstrapped 重跑 no-op,CI gate 用)。**没做的:** 不启 phx.server(install ≠ runtime;打印启动命令于结尾);不 mint operator secrets;不跑 plugin-specific seed。

参考: ARCHITECTURE.md Decision #139,SPEC §7-1 + D7-5/D7-9

### `mix ezagent.plugin.install <path>`(Phase 7 PR 36)

Runtime 热装 OTP plugin 进运行中的 Ezagent,无需重启 phx.server。机制:`:code.add_path(ebin)` + `:application.load(.app)` + `:application.ensure_all_started(app)`,plugin 自己的 `Application.start/2` 在 ensure_all_started 时跑(BehaviorRegistry.register / TemplateRegistry.register 等 hooks 不变)。**Mix.env() 陷阱**:plugin 的 Application.start 用 `Mix.env()` 拿到的是 build-time env;推荐 `System.get_env("MIX_ENV")`。**不做 plugin uninstall**:活的 Kind instance lifecycle 管理复杂,留 dev team v1.x+。

参考: ARCHITECTURE.md Decision #142,SPEC §7-1 + D7-8

### `CLAUDE_CONFIG_DIR` per-agent isolation(Phase 7,AgentTemplate)

Claude Code 2.1.143 环境变量,relocate 整个 `.claude/` 状态目录(credentials + OAuth + MCP cache + plugin/skill cache + session history)。AgentTemplate.claude_config_dir 字段值会被 set 成这个 env var,实现 per-agent 完整隔离。**macOS caveat**:credentials 在 macOS 上走 Keychain 不走 file,`CLAUDE_CONFIG_DIR` 不动 Keychain → 多 agent 同 OS user 共享 Keychain 凭证。Mitigation:`api_key_helper` 字段配每 template 自己的 helper 脚本,或分 OS user,或 production 用 Linux(完全 work)。

参考: ARCHITECTURE.md Decision #136,SPEC §AgentTemplate macOS Keychain caveat

### `Agent.spawned_by` lineage(Phase 7 PR 40,与 PR 42 配合)

Agent Kind slice 新增字段,记录这个 Agent 是被谁 spawn 出来的(URI)。`Ezagent.Entity.Agent.spawn/4` 的 `granted_by` 参数同时充当 lineage anchor + cap-grant attribution。配合 PR 42 的 `{:spawned_by, principal_uri}` cap shape,实现 "orchestrator 只能 grant cap 给自己 spawn 的 worker agent" 这种 lineage-bounded delegation。Migration:pre-Phase-7 Agent snapshot 加载时 `spawned_by: nil`,行为跟 today 一致(无 spawned_by 限制的 cap 不会匹配它们)。

参考: ARCHITECTURE.md Decision #137,SPEC §7-2 + §7-3 (b)

### `Capability.matches?/2` tuple-shape 扩展(Phase 7 PR 42)

`instance` 字段从 `URI.t() | :any` 扩到 `URI.t() | :any | scope_tuple()`,新增 tuple shapes 在 `Ezagent.Capability` 的 `instance_match?/2` 处理。**关键设计**:不在 CapBAC step 5.5 里 dispatch lookup 来 resolve scope context(会无限递归);用一个独立的 ETS 注册表(workspace_uri lookup 已经是 WorkspaceRegistry,spawn lineage 是 PR 40 加的新 registry)。CapBAC step 5.5 只做 O(1) ETS 读,无 dispatch。

参考: ARCHITECTURE.md Decision #137,SPEC §7-3 (a)

### Working-copy template state(Phase 7 PR 44)

每个 running session 的 Chat slice 新增 `template_working_copy` 字段,实时记录 session 内部模板演化(orchestrator 的 add_agent_slot / write_matcher 等工具更新这里,不直接动 SessionTemplate row)。`save_template` / `update_template` 时读这里写回 registry。**Persistence flip**:Session Kind 之前是 `:ephemeral`,Phase 7 改为 `{:snapshot, :on_change}` 让 working-copy 重启不丢。

参考: ARCHITECTURE.md Decision #136, #141,SPEC §7-3 "Working-copy session slice"

### Template fork lineage(Phase 7 PR 38)

SessionTemplate row 的 `parent_template_uri` 字段。Fork 时 child 指向 parent 的特定 version_hash;merge-back(orchestrator `update_template`)写 parent 的 name + 新 hash,旧 hash 行不动。Lineage 是树形(child 可再 fork → grandchild),不做 merge graph。CI gate `template_fork_lineage_test.exs` 锁 fork 必带 parent + 老版不变。

参考: ARCHITECTURE.md Decision #141, #143,SPEC §Fork vs update semantics

### BindingPolicy(`EzagentPluginFeishu`)

(Phase 6 PR 15 + PR 27 — 这里 cross-link 完整定义已在 GLOSSARY 早前位置;Phase 7 docs 跨条目重复引用时直接说 "BindingPolicy")

---

## 3. 易混淆词消歧

Ezagent domain 词跟外部世界(Phoenix / Elixir / 通用计算机科学)同名碰撞。**写文档/代码碰到这些词,必须按 convention 消歧**。

### 消歧 convention

1. **首次出现必须明确**:第一次提到易混淆词时,写全(例:"CC Channel(MCP 协议)"或"Phoenix.Channel(WS 抽象)")
2. **代码 module name 跟着区分**:`Ezagent.Channel` 是 Ezagent 内部概念,`Phoenix.Channel` 永远带 namespace
3. **如果上下文已经明确,可以省 prefix**:在 `lib/ezagent_plugin_cc/` 目录下 "channel" 默认指 CC Channel,这时不需要 disambiguate

### 易混淆词表

| 词 | Ezagent 意义 | 外部世界意义 | 消歧写法 |
|---|---|---|---|
| **channel** | Claude Code Channel(MCP 协议扩展:`claude/channel` capability + 一个 notification method + tools) | Phoenix.Channel(Phoenix WS 框架抽象) / OTP channel(无此概念) | "CC Channel" / "Phoenix.Channel";两个完全无关,碰巧同名 |
| **session** | Ezagent Session(routing context owner,Kind 子类) | Phoenix session(cookie/web session) / HTTP session | "Ezagent Session" / "Phoenix session" |
| **registry** | KindRegistry(URI→pid) / RoutingRegistry(external_key→URI) | Elixir Registry(底层 module) | 显式指 "KindRegistry" 或 "RoutingRegistry";"Elixir Registry" |
| **behavior** | Ezagent.ActionSet(action 处理者,自定义概念) | Elixir behaviour(callback 契约,语言级) | Ezagent 用 "Behavior" 大写 B;Elixir 用 "behaviour" 小写 b(British spelling) |
| **template** | Template Class(模块级)/ Template Instance(运行时 Resource) | Phoenix template(.heex 文件) | "Template Class" / "Template Instance" / "Phoenix template" |
| **plugin** | OTP app 形式的 Ezagent 扩展 | Mix.Project plugin(`mix archive`)/ Elixir plugin(完全不同) | Ezagent 用 `esr_plugin_*` namespace 前缀 |
| **dispatch** | `Ezagent.Invocation.dispatch/1`(消息分发) | `Phoenix.Router.dispatch`(HTTP 路由) | "Invocation dispatch" / "Phoenix.Router.dispatch" |
| **broadcast** | `Phoenix.PubSub.broadcast`(只用于 view/telemetry,**不用于 inbound message**) | 通用术语 | Ezagent 写代码时 `PubSub.broadcast` 出现在 inbound 路径 = bug;严格按 Decision #75 |
| **router** | Ezagent 是 message router(全局架构定位) | Phoenix.Router(HTTP path 路由) | "Ezagent(message router)" / "Phoenix.Router(HTTP path)" |
| **kind** | Ezagent Kind(可寻址实体的 class) | (Elixir 无此概念;OO 语言里类似 Class) | 全文用 "Kind",首字母大写 |
| **base** | Ezagent capability substrate(`Behavior` owning a state slice + general reusable actions;composed INTO a socialware) | Elixir `@behaviour`(callback 契约,语言级)/ OO base-class(继承父类) | "Ezagent Base(基座)"/ "Elixir behaviour"(小写 b)/ "OO base class";三者完全不同 —— Ezagent Base 是 composed-not-inherited |
| **socialware** | Ezagent human+program hybrid FLOW(composes ≥1 base + shape,directly user-operable) | 通用 "software"(软件总称)/ "social software"(社交软件) | "Ezagent socialware";名字 deliberate —— 强调 human-in-the-loop gating axis,不是 generic software |
| **recipe** | Ezagent config-as-data recipe(axis A,`Ezagent.Agent.Recipe`,`recipe:<name>`) | 烹饪/general "recipe"(配方)/ DevOps "recipe"(Chef recipe) | "Ezagent Recipe(axis A)";跟 cooking / Chef 无关 |
| **role** / **responsibility** | Ezagent `role_name` responsibility slot(`bot`/`reviewer`/`orchestrator`/`supervisor`,经 `{:role,name}` routing);**"role" 一词 ONLY 留此意义** | Elixir `@behaviour` role(callback 契约)/ 通用 auth "role"(RBAC role) | "Ezagent responsibility(`role_name`)";跟 Elixir behaviour callback 和 RBAC role 都不同 —— recipe 是 content,responsibility 是 runtime slot |
| **fixture** | Ezagent seeded business instance(一个 socialware 为某业务配置的 instance;autoservice = chat for customer-service) | **ExUnit test fixture**(`setup` block 里的 test fixture)/ 通用 "fixture"(固定装置) | **高碰撞风险,必须消歧**:"Ezagent fixture(seeded business instance)" vs "ExUnit fixture(test setup)";两者完全无关 —— socialware-fixture 是 L2 seed + L3 instance,NOT a test fixture |
| **definition** | Ezagent L2 ConfigObject(reusable/forkable/content-addressed config bundle;recipe 或 socialware definition,`recipe:<name> / socialware:<name>`) | 通用 "definition"(定义)/ programming "function definition" | "Ezagent Definition(config-as-data)";不是函数定义 |
| **principal** | 发起 Invocation 的主体(Entity Kind 实例) | (Web 安全/auth 通用术语) | 含义大致一致,不太需要消歧 |
| **transport** | Ezagent Adapter 的 wire 形态(WS/HTTP/stdio/MCP) | (网络栈 layer 4) | 上下文明确 |
| **scope** | Cap 的三档(`:instance` / `:kind` / `:all`) | 通用术语(变量作用域 / 项目范围 / 等等) | 写 "cap scope" 明确 |
| **manifest** | Ezagent 部署清单文件($EZAGENT_HOME deploy 目录里的 seed 输入,`Ezagent.Socialware.ManifestSeed` 扫描,"这个部署环境装什么") | Docker/K8s manifest / npm package manifest / MANIFEST.in | "Ezagent deploy manifest";只指 $EZAGENT_HOME seed 清单,不是容器编排文件 |

### 内部分层词消歧(declaration/content 轴,Decision #161)

上面的表消歧"Ezagent vs 外部世界";这一节消歧 **Ezagent 内部**四个易混层次词。每个词各占一层,新概念命名先对此表(Allen 2026-07-08,起因:skill 分发设计 #1251 讨论中 registry/manifest/definition 混淆):

| 词 | 层 | 回答的问题 | 典型代表 |
|---|---|---|---|
| **Definition** | 应用声明(L2 data) | "这个 socialware 应用是什么"(roles / agents / views / routing) | `Ezagent.Socialware.Definition`,subject `socialware:<name>` |
| **Recipe** | 个体配方(L2 data) | "这个 agent 怎么做出来"(flavor / skills / caps / 依赖) | `Ezagent.Agent.Recipe`,subject `recipe:<name>` |
| **Manifest** | 部署清单($EZAGENT_HOME 文件) | "这个部署环境装什么"(deploy 侧 seed 的输入) | `Ezagent.Socialware.ManifestSeed` 扫描的 deploy 目录清单 |
| **Registry** | 运行时索引(进程内 ETS/read-through) | "运行时按名字怎么找到"(name → pid/module/content) | `KindRegistry` / `RecipeRegistry` / (planned) `SkillRegistry` |

**辅助后缀 convention**(围绕上述四层的既有命名习惯,新模块跟随):
- **`*Store`** = 持久存储后端(Postgres/ETS 的写入面;`ConfigStore` 是 L2 ConfigObject 的 store,Registry 常是它的 read-through)
- **`*Seed`** = boot/deploy 期安装通道(把 manifest/默认内容灌进 Store;`ManifestSeed` / `DefaultAgentSeed` / seed 三态契约 #1242)
- **`*Resolver`** = 读侧查询/read-model(`AgentRecipeResolver` / `Template.Resolver`)
- **`*Materializer`** = 把声明变成运行时 artifact(`RecipeMaterializer`:recipe × flavor → 落地的 agent)

### 命名 convention 总结

- Ezagent 自定义概念用**大写首字母** + **Ezagent.* 模块前缀**:`Ezagent.Kind` / `Ezagent.ActionSet` / `Ezagent.Channel`(如果有)
- 外部库 / Elixir 语言级概念用**官方拼写**:`Phoenix.Channel` / `Elixir behaviour`(小写)
- 写代码命名变量时避免单词裸用:不要 `channel = ...`,写 `cc_channel = ...` 或 `phoenix_channel = ...`

---

## 4. 维护流程

### 实施期新增 Decision

1. 实施期产生新架构决策(brainstorm 阶段 / dev review / Allen 指示)
2. Append 到 §1 Decision Log,编号递增(下一条 #156)
3. Period 字段标 `impl`(区别 v0.1-v0.4 的"设计期"决策)
4. 决策正文要简洁:**一句话核心 + 关键 link**(到 ARCHITECTURE.md 章节或 docs/phase-specs/)
5. 同步:如果决策影响 ARCHITECTURE.md,Allen 决定要不要 patch 主文档(小决策可能只在 GLOSSARY 记录)

### 新增术语

1. 实施期发现一个**没在 §2 列出但需要 Claude Code / 新人快速理解**的概念
2. Append 到 §2(按字母顺序插入)
3. 包含简要定义 + ARCHITECTURE.md 参考章节
4. 如果该词易混淆,同时加 §3 易混淆词表

### 新增易混淆词

1. 实施期碰到 Ezagent 跟外部世界的命名碰撞(代码 review 时容易看到)
2. Append 到 §3 易混淆词表
3. 给出消歧 convention(怎么写以区分)
4. 全 repo grep 一遍现有代码 / 文档,确保已有使用都遵循 convention

---

## End

本文件是 Ezagent 项目的**单一真相源**,跟 ARCHITECTURE.md 平级。实施期任何疑问优先查这里。

**Maintainers**: Allen + Claude(顶层文档维护)+ 工程师(实施期 phase-specs)
**Last updated**: 2026-06-28 — socialware unification + 4-carrier-layer taxonomy 入账(Decision #155;术语表新增 base/socialware/fixture/recipe/responsibility/definition/runtime-state/blob/shape/install-relation;易混淆词表新增对应消歧行;visibility rename `:operator_only`→`:internal` 同步)
**Decision Log status**: #155(下一条 #156,实施期持续 append)
