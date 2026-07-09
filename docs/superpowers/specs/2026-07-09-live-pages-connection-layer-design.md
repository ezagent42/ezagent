# 从静态生成页到活页面:连接层缺口与 external adapter 的改造评估

**Status:** PROPOSAL(调研 + 方案对比;非决议)。**本文档是提案 —— 所有架构取舍需 Allen 确认后才能进入 SPEC/PLAN**(遵循仓库惯例:实施期发现架构问题 → 暂停 → 讨论 → Allen 改 → 继续;不发明新 Decision,任何架构决策走 Allen review 后进 GLOSSARY Decision Log)。
**Date:** 2026-07-09。基准:`origin/main` @ `7cb85a48c`(文中所有 file:line 均在该 commit 上核实)。
**Scope:** 只调研 + 设计评估,不改任何产品代码。
**Reader 前置:** `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`(三层模型)、`docs/superpowers/specs/2026-06-09-socialware-substrate-design.md`(P2.5/P3/P4 交付契约)、GLOSSARY Decision #122 / #154。

> 术语按 main 现状:`Behavior` 命名空间已更名 `Ezagent.ActionSet.*`(#1138);"customer" 概念已退役为 anon-user + external visibility(#1037),CustomerFeed/CustomerChannel 现为 `ExternalFeed` / `SessionFeedChannel`。

---

## 1. 问题陈述

hello socialware 的自然语言生成页面链路已可跑:访客/成员一句话 → front-desk 中继 agent 按 意图×身份 分流(`:rebuild` 页面重建 / `:answer` 只读答疑)→ `HelloBuilder` → `Generator` → `Spec.validate`(fail-closed 组件目录)→ `turn.compose` 路由进 `Surface.put_version` → `turn.settle` 推进 approve 指针 + commit settlement 两道门 → `ExternalFeed` 把 **committed** 快照沿 durable outbox + cursor replay 推给外部 SPA。

但生成出来的页面本体是**提交时刻的静态快照**:组件 props 全是烘焙进 Surface 版本树的静态字面量,页面上没有任何可交互的 action,页面内的值也没有任何随业务对象变化的通道。要承载有真实数据流的业务对象 —— 服务单流转、需求单表单、服务来源选择、交付状态跟踪、运营看板 —— 缺口收敛于四处(§2);而候选承载机制之一是 `ezagent_domain_external_mirror` 的 adapter 抽象,本文回答"它是否可以/应该改造为通用连接层"(§3 现状,§4 论证)。

**一个重要的前情更新**:本任务的输入调研(基于较早分支)断言"顾客 channel 无任何入站 handler、顾客页面是纯接收端"。在当前 main 上这**已经部分过时** —— #1037/#1069/#1168 之后,feed channel 已长出受 participation profile 门控的 `post`/`join`/`history` 入站(§2.2)。这不削弱本提案,反而**改变了问题的形状**:系统已经用行动回答过一次"入站往哪放"(放在 pull-adapter 的 caller 侧参与面,而不是改 push 契约、也不是另起炉灶),本提案的方案推荐正是沿着这条已被选择的沟槽延伸。

---

## 2. 四个缺口:main 上的现状与证据

### 2.1 缺口一:actions 注册表为空,组件目录无事件出口 —— 完整存在

- 运营端 catalog:`apps/ezagent_plugin_hello/assets/src/catalog.ts:18` —— `actions: {}`。
- 外部 SPA catalog:`apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs:20` —— `defineCatalog(schema, {components: shadcnComponentDefinitions, actions: {}})`。
- 组件目录(36 个)在 `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex:29-71`:`Button`(`:40`)props 仅 `["label","variant","disabled"]`,无 action/onClick;`Input`(`:64`)/`Select`(`:66`)无提交目标。
- `Spec.validate/1` fail-closed(spec.ex `:113-116` `{:error, {:unknown_type, type}}`;`:136` missing_type)。**澄清**:validate 只 gate 节点 TYPE;props 的静态约束由渲染端 zod(`shadcnComponentDefinitions`)保证 —— 即 action 白名单若要落地,Elixir 侧 validate 与渲染端 catalog 两处都要动。

json-render 框架本身留有 `actions` 槽位,所以这是**目录内容缺口**而非框架能力缺口。

### 2.2 缺口二:入站通道 —— 已部分收窄,剩"无页面级 action/表单入站"

main 上 feed channel 已统一为 adapter 参数化的 `EzagentWeb.Socialware.SessionFeedChannel`(`apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex`):

- **已有入站**:`handle_in("post"|"join"|"history", …)`(`:42/:49/:56`),由 adapter 声明的 `participation_profile`(`:read_only | :participatory`)门控;`post` 走 `dispatch_post/3`(`:359-374`):构造 `Ezagent.Message` 并 `@`-mention `hello.front-desk` 中继 agent → `session?action=session.send` 正常 dispatch —— **入站已经归一为 CapBAC-gated dispatch**。
- **仍缺**:入站只有**自由文本 chat**。没有页面 action(按钮点击/表单提交/选择器)的类型化入站:外部 SPA(`apps/ezagent_domain_socialware/assets/js/viewer_app.js`)仅 `ch.push("join")`(`:461`)与 `ch.push("post")`(`:471`),无任何 page-action push。表单类交互连表达都表达不出来(缺口一),即便表达了也没有对应 `handle_in`。
- **匿名被排除在写之外**:`signed_in_principal/1`(`:325-330`)对 anon URI 返回 nil → `post/join` 一律回 `"not_logged_in"`。

### 2.3 缺口三:页面烘焙进 Surface 版本树,无数据绑定/订阅 —— 完整存在

生成链路逐环(main file:line):

1. front-desk 分流后的重建入口:`Ezagent.ActionSet.HelloBuilder`(`apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_builder.ex:80` `handle_rebuild`;`:146` 注入 `Generator.start/2`)。
2. `EzagentPluginHello.Generator`:`generator.ex:288-289` —— `Spec.extract` → `Spec.validate`(出目录即 halt,页面不落地)。
3. `EzagentPluginHello.TurnDriver.drive/4`(`turn_driver.ex:41-43`;moduledoc `:9-13`):`turn.open → turn.compose([%{kind: :page, tree: spec}, %{kind: :chat, …}]) → turn.settle`。
4. `turn.compose` 把 `kind: :page` 路由进 `:put_version`(`apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex:436`);存储在 `Ezagent.ActionSet.Surface`:`surface.ex:59-72` `handle_put_version` 把 `%{tree: tree, by_turn: turn_id}` 以整数版本号**不可变追加**进 `:versions` map —— 整页烘焙,无逐节点数据引用。
5. 两道门:`turn.ex:469-487` `approve_and_commit_effects`(`:approve` + `:commit_settlement`);`surface.ex:90-98` `handle_approve` 推进 approved 指针,`:101` 起 `handle_commit_settlement`。
6. 外部投影只读 **committed** 版本:`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:462-465` `external_page` ← `committed_surface_version`(`:478`)← `Surface.tree_for_version`;交付走 P2.5b durable outbox + cursor replay(`:101-125` `committed_deliveries_since`,advisory 仅 wake-up)。

**不存在任何页面内数据订阅/绑定机制**:任何内容变化 —— 哪怕一个数字 —— 唯一路径是 front-desk `:rebuild` 重跑 Generator 生成一整棵新版本树,再走 approve/commit 推整页快照。对"改文案/改布局"这是正确的治理模型;对"看板计数每分钟变一次"这是错误的模型 —— 缺一个与版本树正交的**数据槽位通道**。

### 2.4 缺口四:匿名访客只读 —— 存在,但授权机制的"延伸点"已经就位

- anon-User **read-only by construction**(`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex:25-29`):`Users.create_read_only` 不带 default session 写 caps;`chat.send` 在 CapBAC 卡点(dispatch step 5.5,`apps/ezagent_core/lib/ezagent/kind/runtime.ex:378-389`,`granted_via_ctx_caps?`/`granted_via_holds_cap?` 双 miss → `:unauthorized`)被拒。`Ezagent.ActionSet.Session` 的 `:send` 声明 `caps: [:send]`(`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:147-150`)。
- 但 main 上匿名授权已不是"一刀切空 caps",而是**两层门 + 细粒度铸造**:`AnonUser.mint_for_public_session/1`(`anon_user.ex:119-134`)铸 `join_cap` + `Installation.anon_view_caps/1`(`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:305-320`,T2-2b)—— 对每个 `web_anon_access == true` 的已安装 definition,按其 views ActionSet 逐 action 铸 render cap,**granter = session owner**(#154 合规,不走 `system://` principal)。admission 序列(mint → spawn → bind → join → 挂参与 caps)收敛在 `Ezagent.Socialware.AnonAdmission`(`anon_admission.ex:31-38`)。
- 已注册成员另有**参与 cap 分层**(#154 spec 甲):`Membership.mount_participation_caps/2`(`apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1162-1163,:1174-1183`)—— unconfirmed → 仅 `subscribe_from`;confirmed → + `Session.:send` + `:leave`;授权 authority `{:rule, :session_participation, owner}`。
- 生成侧兜底:`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/sanitize.ex:26` `@dangerous_tags` **denylist**(非白名单)服务端剥除 `form/input/textarea/select` 等 —— 访客拿到的 shell 是纯展示 HTML(prompts 里的规则只是 LLM 提示,强制点在 sanitize)。

**含义**:匿名写的问题已经从"CapBAC 有没有口子"变成"沿哪条既有铸造通道再铸一档**交互 caps**":`anon_view_caps`(逐 view 逐 action、owner 作 granter)和参与分层(rule-authority)都是现成模具;email 入站的 ephemeral ctx-cap mint(`apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex:45`,恰好一个 `session.send` cap,自证 authority)是第三个可选模具。

---

## 3. external adapter 现状分析

### 3.1 职责边界:三层模型,push 契约是"出站纯翻译"

Decision #122 的三层模型(Allen 2026-05-24 定为 FINAL 的组织原则):**Publisher**(Session 是带 history/cursor/replay 的结构化流,不知道谁消费)→ **Adapter**(无状态纯翻译,`event_to_payload/1` 禁 I/O;唯一例外 `target_ownership_check/2` 只在 bind 时)→ **Binding**(有状态 per-target GenServer 拥有外部 transport,PerBindingSupervisor 崩溃隔离)。bind 走 facade 四道门 + nonce 防伪(`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex:152-180`,`FacadeNonceTable.claim_nonce/4` 单一 SoT):Check 1 session `:bind` cap → Check 2 per-adapter allow cap(`cap_subject/0`)→ Check 3 外部成员资格 → dispatch(step 5.5 再兜 Check 1)。

**push 契约里没有入站消息类型**,消息单向:`Ezagent.Publisher.Event` → `event_to_payload/1` → `Binding.publish/2`。

### 3.2 adapter kind 轴:契约已经分化三次,而且 pull 侧已经长出参与面

`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`:

- **`:push`**(默认)—— Feishu、email 出站镜像。Worker + Binding。
- **`:request_scoped`** —— protocol-api 入站 HTTP(`apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/adapter.ex:30`):binding 只活一个请求,transport 归 caller 的 Plug;adapter 注册主要承担身份/注册面。
- **`:pull`** —— **外部 SPA 就在这里**。且 main 上 pull 契约已远比 P3-1 的 `render/2` 丰富(`adapter.ex:117-360`):
  - `delivery_discipline/0`(`:snapshot_refresh | :cursor_replay`)+ `live_topics/1` + `render_authorized/2` + `join_with_cursor/2` + `replay/3` —— **读侧/订阅侧**;
  - `participation_profile/0`(`:read_only | :participatory`)+ 可选 `post/3`、`join/2`、`history/2` —— **入站参与面**。
  - 实现:`Ezagent.Socialware.ExternalFeedAdapter`(`external_feed_adapter.ex:63-71`,`:pull` + `:cursor_replay` + `:participatory`)与 `ChatFeedAdapter`;Allow 模块(`dispatchable?: false` 的 cap-only ActionSet)承担 Check-2 cap subject。

`SessionFeedChannel` 是 caller 侧的统一宿主:从 topic 解析 adapter → 订 `live_topics` → 按 discipline 分发 join/replay;入站按 `participation_profile` 门控,`post` 优先走 adapter 可选 callback、缺省 fallback 到 `dispatch_post`(session.send + front-desk mention)。**分工定型为:channel 拥有 transport + per-connection 身份门控;adapter 提供投影与领域调用中介;授权兜底永远在 dispatch CapBAC 卡点。**

### 3.3 双向性的真相:出站在 Domain 契约里,入站从来在 transport 侧归一为 dispatch

三个既有双向渠道,入站没有一个走 push adapter 契约:

- **Feishu**:`WebhookPlug`/`WsClient` → `InboundDispatcher.dispatch/1`(`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:58`)→ `SenderResolver` 解析成**已绑定真实 User + 其 caps** → `session.send` dispatch(`mode: :call`,cap 拒绝回帖给人,P18)。
- **Email**(#88 PR-2):inbox 轮询 → `Inbound.Guard`(bounce/SPF/DKIM/DMARC fail-closed)→ `Inbound.Principal.mint/1` 铸 ephemeral 合成身份 + 恰好一个 `session.send` ctx-cap(#154 合规,self-authority)→ dispatch。
- **Web feed**(§3.2):channel 身份门控 → participation profile → dispatch。

**结论:"入站 = transport 侧守门 + 身份解析/铸造 + CapBAC-gated dispatch"是系统里唯一的入站规范形态**;adapter 契约的出站纯翻译边界从未被入站穿透。

### 3.4 离"通用连接层"有多远

| 能力 | 现状 | 距离 |
|---|---|---|
| 数据订阅出站(活看板) | `:pull` + `:cursor_replay` + durable outbox + advisory wake-up 已是通用交付机;缺的只是投影粒度从"整页快照"细化到"页面数据槽位" | 增量 |
| 页面 action 入站(按钮/表单) | 参与面(`participation_profile` + `post`)已开,但只有自由文本;无类型化 page-action | 沿既有参与面延伸一个 handler + 契约可选 callback |
| 匿名访客写授权 | anon 两层门 + 逐 action 铸 cap(view 维度)+ 参与分层已就位;缺"交互 caps"这一档 | 模具现成,铸新档 |

**距离已经很近,而且方向已被 main 自己选定**:当外部 feed 需要参与能力时,仓库既没有去改 push 契约,也没有另起一条独立通路,而是让 pull adapter 长出参与面、channel 守身份、dispatch 兜授权。

---

## 4. 核心论证:external adapter 是否应该改造为通用连接层?

### 4.1 方案 A —— 扩展(push)mirror 契约:页面事件作为一种入站消息类型,数据订阅作为出站镜像

给 `Adapter`/`Binding` 增加入站消息类型与双向 transport;页面事件从 channel 进来后交 adapter 翻译再入 session;数据订阅复用 push Worker 出站。

**不推荐。**
1. **职责单一性**:把出站纯翻译器改成双向协议网关,违背 #122 三层模型;与全部三个既有双向渠道的实际形态(入站在 transport 侧)脱节 —— 改完契约反而没有实现者。
2. **CapBAC 契合度**:push 侧 cap 体系管 **bind 动作**(谁能把 session 镜像到哪个外部 target);页面 action 的授权主体是"访客对单 session 的单 action" —— 两个正交的权限面硬挤一个契约。
3. **匿名最小开放面**:不解决 —— 身份铸造在 dispatch 之前的 transport 侧,与 adapter 无关。
4. **Surface 一致性**:正交,未触及。
5. **工作量**:最大 —— Domain 契约 + Grill-5 编译检查 + AdapterRegistry per-kind 断言 + 全部既有 adapter + 不变量测试连锁。

### 4.2 方案 B —— 不动 adapter:新建独立 page-actions 通路(actions 注册 + channel 入站 handler + 绑定协议)

**方向对一半,但在 main 现状下已经过时**:它假设"顾客 channel 是纯接收端、需要从零建入站"。实际上参与面已在 pull 契约与 `SessionFeedChannel` 里存在;再建一条与之平行的独立通路会造成**同一个 channel 上两种入站形态、两套门控**,且 actions 注册、访客授权、投影订阅各自还要重新发明一遍已有机制(participation profile、anon caps 铸造、cursor replay)。

### 4.3 方案 C(推荐)—— 沿已选定的沟槽延伸:pull 参与面从"自由文本"扩到"类型化页面 action",数据槽位挂进 cursor-replay 交付,action 白名单烘焙进 Surface 版本

不改 push 契约,不建平行通路;四件增量:

**C-1 · action/绑定 props 进组件目录 + Surface 版本(缺口一/三之结构侧)**
`spec.ex` 目录扩展受控交互 props(`Button.action: {name, args_schema}`、`Input/Select.bind: slot_id`),`Spec.validate` 从"只 gate type"升级为**同时 gate 交互 props**(fail-closed;纯展示 props 仍留给渲染端 zod);两端 catalog 的 `actions: {}` 填入通用桥(action 触发 → `ch.push("page_action", {action, args, version})`)。**页面声明的 action 集合是版本树内容,随 approve/commit 两道门走** —— 生成器能给页面配什么交互,和页面长什么样一样受结算治理;`:approve` 未 `:commit` 的版本其 action 集不生效(与 page-leak gate 同姿态)。

**C-2 · `SessionFeedChannel.handle_in("page_action", …)`(缺口二)**
与 `"post"` 并列、同受 `participation_profile` 门控;守门序列:身份(channel 既有)→ action ∈ 当前 **committed** 版本的 action 白名单(fail-closed)→ args 按 args_schema 校验 → adapter 可选 callback `page_action/4`(pull 契约新增一个 optional callback,与 `post/3` 同格)、缺省 fallback 到 dispatch(与 `dispatch_post` 同构:P-α 阶段即"结构化 session.send",front-desk / 领域 agent 消费)。授权兜底不变:dispatch CapBAC step 5.5。

**C-3 · 匿名交互 caps:沿 `anon_view_caps` 模具铸新档(缺口四)**
在 T2-2b 两层门上加第三层细粒度:definition 的 `visibility_policy` 增加 `web_anon_interact`(或按 action 列表),admission 时对声明为匿名可用的页面 action 逐条铸 cap(granter = session owner,#154 合规,与 view render caps 完全同构)。已登录访客走既有参与分层。**不需要 email 式 ephemeral mint**(那是"外部对应方没有 ezagent 身份"场景的模具;web 匿名访客已有 anon-User 真实 principal),但若 Allen 倾向"交互授权不落 caps_json",ephemeral ctx-cap 是现成替代。

**C-4 · data slot + committed 槽位投递(缺口三之数据侧)**
Surface 版本树里组件可引用 slot id(版本 = 结构 + 槽位引用,不含值);槽位值更新沿 **既有 cursor-replay 交付机**下发 —— P2.5b outbox 行已携带 `surface_version`,扩展为可携带槽位增量;`ExternalFeedAdapter.replay/3` 与 viewer 端投影同步细化。数据变化不产生 Surface 版本,结构变化才产生。看板类"尽力而为实时"是否允许 advisory-only 降级投影,留 §4.5。

### 4.4 五维度对比

| 维度 | A · 双向化 mirror 契约 | B · 独立新通路 | C · 延伸 pull 参与面 |
|---|---|---|---|
| 职责单一性 | ✗ 破坏 #122 三层模型;契约与全部现存实现脱节 | ○ adapter 不动,但同 channel 出现第二套入站形态 | ✓✓ 完全顺着 main 已发生的演化方向(pull 参与面);push 契约零改动 |
| CapBAC 契合度 | ✗ bind-cap 与访客-action 权限面错位 | ○ 授权模型需自建,易漂移 | ✓✓ dispatch 卡点原样兜底;participation profile + rule-authority 分层照用 |
| 匿名最小开放面 | ✗ 不解决 | ○ 自行设计 | ✓✓ 逐 action 铸 cap、owner 作 granter,与 `anon_view_caps`(T2-2b)同构,#154 免新论证 |
| 与 Surface 版本模型一致性 | ✗ 未触及 | ○ action 白名单归属需另行设计 | ✓✓ action 集与 slot 引用都是版本内容,approve/commit 治理不旁路;committed 门与 page-leak gate 同姿态 |
| 实现工作量 | 最大(契约 + 全 adapter + gate 连锁) | 中(全新面孔) | 中偏小:spec.ex/两端 catalog/channel handler/anon caps 一档/outbox 槽位增量;Domain 仅 pull 契约加一个 optional callback |

**推荐:方案 C。** 一句话:调研发现"adapter 要不要双向化"是个已经被 main 回答过的问题 —— 入站的规范形态(transport 守门 → 身份/caps → CapBAC dispatch)三个渠道一以贯之,pull 参与面就是它在 web 侧的落点;页面 action 只是参与面从"自由文本"到"类型化、版本治理的交互"的下一格,数据槽位只是 cursor-replay 交付机的投影粒度细化。

### 4.5 需要 Allen 决策的开放问题

1. **匿名交互授权的载体**:C-3 的持久 caps(落 anon 的 caps_json,可审计、随 48h GC 走)vs email 式 ephemeral ctx-cap(零 standing authority,每次 action 现铸)?两者都 #154 合规,取舍在审计粒度 vs 最小常驻权限。
2. **page_action 与 front-desk 的关系**:自由文本走 front-desk 意图分流是刻意设计(#1168);类型化 action 已自带意图,是**绕过 front-desk 直达领域 ActionSet**,还是仍经 front-desk 统一编排(保持"所有外部输入都过中继 agent"的不变式)?这决定 C-2 fallback dispatch 的目标。
3. **data slot 的结算语义**:槽位值一律 committed(outbox),还是允许看板类声明 advisory-only 降级?后者动摇"外部可见 = committed"的现有不变式,需明确边界。
4. **`page_action/4` 进 pull 契约 vs 只在 channel**:进契约(与 `post/3` 同格)让非 hello 的 socialware 也能各自定义交互中介;只在 channel 则面更小。倾向前者,但这是 Domain 契约变更,需 Allen 点头。
5. **sanitize denylist 放开顺序**:`form/input/textarea/select` 的剥除必须等 C-1+C-2 落地且 deny-path E2E 齐备后再放开(fail-closed 不先松)。

---

## 5. 分阶段落地建议

| 阶段 | 内容 | 解锁 | 前置 |
|---|---|---|---|
| **P-α 选择器/表单** | C-1(目录交互 props + validate 升级 + 两端 catalog 桥)+ C-2(`page_action` handler,fallback = 结构化 send);登录访客先行(participation 分层已就位),匿名仍只读 | 服务来源选择、需求单表单(登录用户) | §4.5-2 决议 |
| **P-β 匿名交互 + 活数据** | C-3(anon 交互 caps 一档)+ C-4(data slot + committed 槽位投递);sanitize 放开随本阶段末 | 匿名访客提单;交付状态跟踪、运营看板 | P-α;§4.5-1/3 决议 |
| **P-γ 服务单状态机** | action 目标扩展到领域 ActionSet(服务单 Kind 状态迁移);`page_action/4` 进 pull 契约全量(若 §4.5-4 同意);运营侧 Admin 面板可视化交互开关 | 服务单流转全生命周期 | P-α/β;§4.5-4 决议 |

每阶段过 CONTRIBUTING PR 门禁(`mix compile --force` / `ezagent.arch.scan` / `check_invariants(.lifecycle)` / `doc.scan` / 全量 test),并沿用 substrate 的 gate 传统:P-α 加"非白名单 action 被拒 + read_only profile 被拒 + anon post 仍拒"deny E2E;P-β 加"approve-未-commit 的 action 集与槽位值均不可见"gate 与 wake-up-loss 回放测试。

---

## 6. 结论

- external adapter(push/mirror 契约)**不应该**双向化成"通用连接层"(方案 A):出站纯翻译是 #122 刻意边界;系统唯一的入站规范形态(transport 守门 → 身份/caps → CapBAC dispatch)在 Feishu、email、web feed 三处一致成立。
- 也不需要平行新建 page-actions 通路(方案 B):main 已让 pull adapter 长出参与面 + `SessionFeedChannel` 统一宿主 —— 再造一条只会分裂入站形态。
- 推荐**方案 C**:类型化页面 action 作为 pull 参与面的下一格(committed 版本内 action 白名单 fail-closed;dispatch CapBAC 兜底),匿名交互沿 `anon_view_caps` 模具逐 action 铸 cap(owner 作 granter,#154 同构免新例外),活数据作为 cursor-replay 交付机的槽位粒度细化(committed 语义默认不破)。
- 本文档是 proposal;§4.5 五个开放问题需 Allen 裁决后,再按 §5 分阶段进 SPEC/PLAN。
