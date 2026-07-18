# ㊲ 附件 forbidden 的模型层复盘——「一切操作都是对话」四条假设逐条实证

> 2026-07-18。承 `2026-07-17-xy-review.md` §2(机制层定案:uploads 通用层 + 点击现签)。
> 本篇回答模型层问题:用户提出的「plugin 操作=对话」底层模型在架构里站不站得住,㊲ 的根因是不是模型层的。
> 每条断言带 file:line / Decision 号。基线:worktree HEAD a02f5fdd6(skill-1 基线 d533a5d73 之上的本分支 notes)。

---

## 一、用户模型四条逐条对照

### 1.「所有 plugin 操作都是聊天;plugin 物化成 agent」——**部分成立**

**「plugin 物化成 agent」成立**,且就是 Allen 拍的方向:
- kanban-as-role SPEC 原话:「Allen's resolution: **agent = actor (any non-human operator)**; a kanban is such an actor」(`docs/together/2026-06-25/specs/kanban-as-role-spec.md:6`)。#964 曾把板做成 `resource://` live Kind,被推翻重做成 agent。
- mount 模型(2026-07-12 结论,#1425/#1435 已落 main):数据宿主 agent 像 U 盘挂进会话(`apps/ezagent_domain_session/lib/ezagent/socialware/mount.ex:7-8`)。

**「都是聊天」只在广义(C1)意义下成立**。架构里 chat 和 action dispatch 是**一个 fabric、两个 register**:
- **一个 fabric**:跨 Kind 唯一路径是 dispatch(P14);cap 检查「严格只在 dispatch step 5.5 发生一次」(`ARCHITECTURE.md:1428`)。chat 本身就是 dispatch 上搭出来的:Chat 是 Behavior——Session 消费 `send/join/leave`,User+Agent 消费 `receive`(Decision #88,`GLOSSARY.md:117`);一条聊天消息 = `send` dispatch 进 session,fan-out 成给每个成员的 `receive` dispatch,**且 per recipient 铸 `:receive` cap**(`apps/ezagent_core/lib/ezagent/routing/resolver.ex:239-240`)。〔**勘误 2026-07-18,见 §5.2**:该注释是 A2.2 前 stale 说法——现行 delivery 呈交零 cap(delivery.ex:296-306),真机制是 join 时一次性 member-cap + 收方 in-handler 自查;「对话双向都有 cap 判定」的结论不变,形态变了。〕所以「dispatch 是广义的说话」不是比喻,是实现事实。
- **两个 register**:principal 的 **chat register**(Message 落 MessageStore + routing rules + 会话成员制)vs passive data actor 的 **action register**(直接 action dispatch,不产生 Message)。board 被 RF-6 三闸刻意挡在 chat register 外:「NOT @-mentionable, NOT joinable as a session member, does NOT receive chat. It acts **ONLY on direct kanban.\* dispatch**」(`kanban-as-role-spec.md:23-24`;闸的实现 = mention-resolver / `:join` gate / resolver 末端 universal 过滤 `resolver.ex:234-242`)。

**RF-6 与「人和 plugin 聊天」不矛盾**:RF-6 挡的不是「对板说话」,是「把 passive actor 当 principal 会话参与者」——resolver 注释写明理由:passive actor 若活到 fan-out 会被铸 `:receive` cap,等于泄漏 principal 身份(`resolver.ex:238-241`)。对板的 kanban.* dispatch 一直畅通,而且同样过 step 5.5 cap 门。**即:对话没有被禁,只是走 action register。**

### 2.「chat 这个 sw 的功能是过滤消息」——**部分成立(准确说:成员制会话容器;过滤在 routing 层)**

builtin `chat` definition 的全部内容:`name: "chat", bases: Session.chat_behaviors(), shape: []`(`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:491-496`),bases 展开 = `[ActionSet.Session, Publisher.SessionImpl, ActionSet.ExternalMirror]`(`apps/ezagent_domain_session/lib/ezagent/entity/session.ex:73-78`)。职责拆开:

| 关切 | 住哪 |
|---|---|
| 准入(join/leave)+ 发送 + 成员制 | `Ezagent.ActionSet.Session`(chat definition 的本体) |
| **谁收到这条消息(过滤/路由)** | RoutingRegistry + Resolver(`resolver.ex:202-242`,含 F14 防自环、RF-6 passive 过滤) |
| 谁能说话/哪些话有效 | dispatch step 5.5 cap 门(`ARCHITECTURE.md:1428`) |

所以「过滤消息」抓住了 routing 那一层,但 chat definition 本身提供的是**成员制会话容器**(准入+投递);过滤是 core routing 的关切,权限是 CapBAC 的关切——三者刻意分层。

### 3.「权限 = CapBAC =『谁和谁能说话、哪些话有效』」——**成立**

- 单点:cap 检查只在 dispatch step 5.5,LV/controller/Behavior body 内的检查被 invariant test 禁止(`ARCHITECTURE.md:1428`)。
- 「谁和谁」:cap 绑 target URI + grantee(#1386 sign-the-grantee);「哪些话」:cap 绑 action subject。收方向也对称:收方自持 member-cap in-handler 判定(§5.2 勘误;`member_receive.ex:78-85`,非 per-message 铸)。
- 钥匙有主:每个 cap 的 `granted_by` 必须是 real entity(Decision #154,`GLOSSARY.md:165`);mount 发钥匙 granter 恒 = 数据宿主 data_owner(`mount.ex:7-8,:39`)。

### 4.「㊲ 根因是模型层的:下载授权查『chat 消息参与者』是『对话参与』的旧窄实现」——**成立**

机制事实(承 xy-review §2,本篇补齐模型链):

- serve-time 复查 `authorized?/2` = admin ∪ 上传消息 sender ∪「向附件所路由 session 发过消息的人」,**全部查 Message 表**(`apps/ezagent_web/lib/ezagent_web/controllers/uploads_controller.ex:110-157`,`caller_in_attaching_messages?` 按 body LIKE 找带 attachment 的消息行)。
- kanban 附件走 `attach_upload` → `attach_artifact` **action dispatch** 写板 slice,零 Message(`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_actions.ex:330-349`)。**kanban 代码注释自己已经说破了模型错位**:「kanban 节点是资源、非会话绑定……**会话绑定是 chat 语境,对资源节点无意义**」(`world_actions.ex:351-352`)。
- 于是:同一个「人对板发言」(attach_artifact 是 action register 里的一次发言,过了板的 cap 门才写进去),回头下载时却被 chat register 的参与复查判为「从没参与过对话」→ forbidden,连上传者本人都拒。

**这是旧窄实现,不是有意的安全边界**——三条证据:
1. 复查的自我定位就是「冻结 pre-P2 契约」:codex P2-revision HIGH 防 token 泄漏,要求「keep the access decision **identical to the pre-P2 contract**」(`uploads_controller.ex:42-54`)。pre-P2 时代附件**只存在于聊天**(`/files/:filename` 参与授权路),非-chat 附件面(kanban 板)当时不存在——复查冻的是当时唯一的参与形态,不是针对 action register 的排他决定。
2. **伏笔早就埋了**:token 自名「signed **capability** token」(OI-1 DECISION),moduledoc 钉死「minted only after authorization——this module does NOT itself authorize……pure signer」(`apps/ezagent_core/lib/ezagent/uploads/download_token.ex:2-7,:34-37`)。授权的本位概念一直是 capability(surface 授权后签发),chat 参与复查是后补的防泄漏副轴,却成了非-chat 面的唯一裁判。
3. 泛化方向与现行架构同向:「参与 = 持有对宿主的钥匙」正是 mount/person-keys 已经落地的语义(mount 给人发对板的 operate/read cap,`mount.ex:7-8`;㊵ 人本位:tab=持钥板集合)。

**结论:用户的 X 判定在模型层成立**。「参与一段对话」在这套架构里的一等表达就是「持有对这段对话宿主的 cap」(chat register 里是 member/receive cap,action register 里是对数据宿主的 operate/read cap);下载授权只认了前者。

---

## 二、架构对齐的修法(= xy-review §2 定案,补模型表述)

把 serve-time 的「参与」判定泛化为:**消息参与者 ∪ 宿主钥匙持有者**。实现口(向后兼容):

1. **core**:`DownloadToken` payload 加可选 `grantee`(person 绑定;可再带 `host_uri` hint)。旧 token 无字段 → 走现行 chat 复查,零破坏。
2. **web**:`UploadsController.download/2` 加一条分支——person-bound token 校验 `caller == grantee` 即放行。合法性:mint 侧本就要求「授权后才签」(`download_token.ex:89`),kanban 渲染签发前已过板的 read cap 门(`world_data.ex:406` 在 cap-gated read_ctx 之内)——所以「caller==grantee 的 person-bound token」= 「该 caller 被宿主授权过」的可验证凭据,正是「宿主钥匙持有者」分支。防泄漏**更强**而非更弱:泄漏 token 换人无效(现行 bearer token 同 ws 内任何参与者可重放)。
3. **kanban 侧**:点击现签(`world:dispatch` 返 fresh href)替代渲染时预签,解 TTL 300s(`download_token.ex:61`)必过期问题;顺手把 grantee 绑点击者。

## 三、给 Allen 的论证段(需过 Allen——P2 授权契约本身就是 Allen-gated,`uploads_controller.ex:5-9`;2026-07-18 按 §五 全链查验改写)

> Allen,㊲(kanban 附件下载 forbidden)想动 core 的 `DownloadToken`,过你一眼。先交代查验结论(§五全链 file:line):消息的**写路和投递**确实 cap 闭合——`session.send` 声明 `caps: [:send]` 过 step 5.5(`behavior/session.ex:147-153` + `kind/runtime.ex:319`),上传走 `:session :attach` dispatch 同一 chokepoint(`world_uploads_controller.ex:125-141`),接收方授权是 join 时一次性铸的 member-cap `cap(:session, Session, :receive, S)` 由收方 in-handler 自查(`member_cap.ex:259-267` + `member_receive.ex:78-85`)。**但读路不是**:world 内部会话页读历史是纯查表(`ConversationData.state_for` → `MessageStore.recent_in_session`,`conversation_data.ex:37-42,:416-422`),没有任何 cap/membership 判定——self_join 被拒也「degrade to observe,viewer still sees the conversation」(`conversation_actions.ex:1066-1067,:1109-1116`),普通消息默认 `:external_visible`(`message.ex:121-123`)对任何进得了页面的登录者可见。持 held-cap 判定的读路反而在**外部面**:`Membership.authorize/3`(roster ∧ held member-cap,`membership_predicate.ex:55-83`)用在 chat_feed/external_feed/publisher_read(`chat_feed.ex:137`/`external_feed.ex:402`/`socialware_publisher_read.ex:202`)。所以下载 serve-time 那道「参与=发过言」查表复查(`uploads_controller.ex:110-157,:199-210`)不是孤立的偷懒——它是**给渲染面无 cap 门打的补偿**(moduledoc 自己说破:token 链接 renders for everyone who can VIEW,含 observe-only,minting alone would WIDEN access,`uploads_controller.ex:42-54`)。这意味着修法的对齐对象要说准:不是「对齐消息读路现状」(它本身就是查表),而是**对齐系统里已有的 held-cap 判定语义**——外部读的 `Membership.authorize/3` ∪ mount/composition 的宿主钥匙(#154 granter=data_owner)。修法三件:① core `DownloadToken` payload 加可选 `grantee`(person-bound);② `uploads_controller.download/2` 对 person-bound token 验 `caller == grantee` 放行,无字段走旧复查零破坏;③ **签发面必须过真 cap 门才有资格签 person-bound**——kanban 侧点击现签天然在 `get_tree` cap-gated dispatch 之内(`world_data.ex:239-249,:403-412`),chat 侧现签前补跑 `Membership.authorize/3`(正好把 chat 附件的「参与」从『发过言』修正到『持 member-cap』,与外部面同一谓词、无 drift)。防泄漏比现状强:bearer 变 person-bound,泄漏换人无效;codex「不 auth-widening」保住。另附带发现两条(不阻塞 ㊲,单独立项):内部会话页读史零判定 observer 全可读,与 #1217 列表 fail-closed / 外部面 held-cap 不对齐;`resolver.ex:238-241` 「fan-out mints a :receive cap PER recipient」注释是 A2.2 前的 stale 说法(delivery 现呈交零 cap,`delivery.ex:296-306`)。要动 core 授权载体 + web 授权分支,所以先过你。

---

## 四、倒转方案验证(2026-07-18 续:「把 kanban 操作物化成 Message」可行性四点实证)

> 用户模型倒转:「过滤」只是显示层(kanban tab 操作=对 kanban-manager 说话,不必显示在 chat);真正的 X 是 kanban 操作**没有物化成消息**。若 attach_artifact 物化为 Message(人↔板对话的一次发言、带附件),现有「Message 参与者」下载授权原样成立,契约零改动。逐点验证:

### 4.1 消息物化点:现在零 Message,最小物化改动在 plugin 层,不撞 P14/RF-6

- **现状确认**:kanban 写动作(含 attach_artifact)全程零 Message 行。UI 路径 `world_actions.ex:175-198 act()` → `Invocation.dispatch` → 板 `:kanban` slice `:set`;dispatch 层的留痕只有 EventLog 审计(`apps/ezagent_core/lib/ezagent/router.ex:247-257`,`:router_dispatch_ok` append,非 Message)。Message 的唯二写点都在 domain_session:`behavior/session.ex:578`(handle_send)和 `behavior/turn.ex:604`。
- **最小物化改动**:kanban `world_actions` 在 act 成功路径补一发 `session.send` dispatch——sender=**人**(当前登录者,非板),`body.attachments=[upload_uri]`,`hops: 0`,`visibility: :internal`。纯 plugin 层,零 core 改动。
- **P14 干净**:走 dispatch 唯一路径,人持自己的 session member cap(人本来就在这个 session)。**RF-6 不撞**:RF-6 挡的是 passive actor 作 chat **receiver**(resolver.ex:234-242 fan-out 末端过滤);此处板既非 sender 也非 receiver——`hops: 0` 时 handle_send **存了但整个跳过 fan-out**(session.ex:613-615,`stored: true, dropped: :hop_exhausted`),没有任何 recipient 被铸 `:receive` cap。Message.sender 类型上允许 entity://agent(message.ex:69,`sender: %URI{}` 无 scheme 限制),但板无需发言、也没有 send cap,不必作对话方入表。
- **覆盖缺口(诚实)**:cc assistant 经 composition operate 边直接 dispatch 的 attach 不经 world UI,不会物化——UI 层物化天然只覆盖人手操作。

### 4.2 对话容器:(a) 当前 session 机制现成但参与≠钥匙;(b) 板容器机制勉强能装但三处失洽

- **(a) 当前 session**:机制零改动。但「参与者」在 serve-time 复查里=该 session **发过言的人**(`uploads_controller.ex:149-154`,`caller_sent_in_any_session?`——连从没发言的正式成员都 403),与㊵「参与=持钥」不一致的场景:①潜水成员;②人本位分享后的跨 session 点击者(见 4.4)。
- **(b) 板自身作容器**:表机制上**勉强**能装——`messages.session_uri` 只是 Ecto.URI 列,entity:// URI 也能派生 workspace(`uri.ex:710-714`,`workspace_of(%URI{scheme: "entity"})`→ `MessageStore.write/2:73` 的 `workspace_uri_for!` 不 raise)。但三处失洽:①板是 passive native agent,不消费 `ActionSet.Session`,**没有 send dispatch 可走**→只能 MessageStore 直写绕 dispatch(P14 张力;turn.ex:604 直写是 domain 层特例,plugin 层直写是新破例);②所有 chat 读路(replay/ConversationView/membership authorize)都键在 session:// 上,板容器消息对全系统不可见,只服务 uploads 授权一个查询——为一个查询发明一类幽灵消息;③「板容器参与者」=对板**行使过写钥匙**的人,仍 ⊊ 钥匙持有者(只读 sharee 永远没"发过言",见 4.4)。
- **结论**:2a 与㊵不一致,2b 也只是「行使过钥匙」≈「持钥」的真子集且机制别扭——两条都到不了㊵。

### 4.3 显示过滤:现成机制,零新成本

「不显示于 chat」两件套都是现成的:`visibility: :internal`(message.ex:121-123)——普通成员读 `recent_visible_in_session`(world conversation_data.ex:420)看不到 :internal,仅 `read_unfiltered` cap 持有者(管理面,conversation_data.ex:417-418)可见;加 `hops: 0` 跳过全部路由副作用(session.ex:613-615,不触发 routing rule、不惊动 assistant)。语义 overload 提示::internal 本为 socialware 外部面设计,复用作「操作留痕不进聊天」可接受;要更干净可加 `kind` 字段(1 migration+读路不动),非必需。

### 4.4 跨会话/跨 ws 下载:倒转对分享场景确实白做——两方案不等价,倒转 ⊊ 泛化分支

- **2a 白做成立**:物化进当前 session,人本位分享后点击者不在原 session、更没在原 session 发过言 → `caller_sent_in_any_session?` 照样 false → 403。
- **2b 也救不了**:板容器的「参与」判定仍是「向容器**发过**消息」;只读 sharee 拿的是 read cap(`forward_board` 只发 `[:get_tree, :export_markmap]`,board_provision.ex:256),从不产生"发言"——除非把**读**也物化成消息(荒谬)。
- **等价性判定**:两方案**不本质等价**。板容器参与者=行使过写钥匙的人 ⊊ 钥匙持有者;泛化授权分支(person-bound token,点击时过板 read cap 门后现签)覆盖读+写持钥者全集,正是㊵「参与=持有对宿主的 cap」的完整实现。倒转方案是泛化分支的真子集:它真正修复的只有「上传者本人」(物化消息 sender=uploader → `uploads_controller.ex:144` uploader 分支原样命中,**这一段确实契约零改动**)+「同 session 发过言的人」。
- **改动量对比**:倒转(2a 版)≈ plugin 层 20 行、零 core 改动,但覆盖不了分享;泛化分支动 core `DownloadToken` + web 一条分支(需过 Allen),覆盖全集。

### 4.5 给 Allen 的最终建议(替代/补充 §三论证段)

> Allen,㊲ 又推演了一轮「物化成消息」的倒转方案(kanban 操作=对板发言,attach_artifact 物化成带附件的 Message,让现有 Message-参与者下载授权原样成立)。验证结论:**倒转在机制上可行且便宜**(人以自己身份补发 `session.send`,`hops: 0` 只存不路由、`visibility: :internal` 不进聊天面,纯 plugin 层 ~20 行,P14/RF-6 都干净),它能零契约改动修好「上传者本人 403」,还白送操作留痕。**但它覆盖不了人本位分享**:跨 session 点击者/只读 sharee 在任何容器选择下都从未「发过言」,serve-time 参与复查照样 403——「发过言的人」永远只是「持钥人」的真子集。所以最终建议不变:**主修法仍是 §三的泛化授权分支**(DownloadToken 加 person-bound `grantee` + 点击现签,参与=消息参与者 ∪ 宿主钥匙持有者),这是唯一同时覆盖只读分享、且与你拍的 #154/mount 语义同向的方案;**倒转可作独立的补充项**(操作留痕+上传者即时修复),两者不冲突、可分开排期。若只批一个,批泛化分支。

---

## 五、消息物化全链查验(2026-07-18 续:发/投递/读/附件/判定 逐环 file:line)

> 从头验「消息是怎么物化的、是否已符合 CapBAC」,回答:用户断言「消息本身已符合 CapBAC、下载检查是偷懒查表」成立吗?worktree HEAD 37138e784(本分支 notes-only,代码同 skill-1 基线 d533a5d73)。

### 5.1 发 —— cap 判定 ✅

- **授权**:`session.send` 声明 `caps: [:send]`(`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:147-153`)。dispatch step 5.5 = `Kind.Runtime.authz_check/5`(`apps/ezagent_core/lib/ezagent/kind/runtime.ex:319`):非 cap-exempt 动作解析 `required_caps`,先查 `ctx.caps` 呈交 caps、miss 再查 caller 自己 `:identity` slice 持有 caps(`runtime.ex:382-415`),deny → `:unauthorized`。
- **handler → 落库**:`handle_send`(`session.ex:563`)第一步 `MessageStore.write(msg, session_uri)`(`session.ex:578`),写失败=发失败(let-it-crash);之后 Resolver 路由 + DeliveryQueue 异步 fan-out(`session.ex:624-694`)。
- **Message 行结构**(`apps/ezagent_core/lib/ezagent/message.ex:84-137`):`id`(UUID PK)/ `session_uri` / `workspace_uri` / `sender`(单 URI)/ `mentions` / `body`(map,含 `text` + `attachments`)/ `ref_id` / `inserted_at` / `visibility`(enum,**默认 `:external_visible`**,:121-123)/ `hops` / `routed_at`。**没有 recipients/participants 列**——接收方从不物化在 Message 行上(`message_routings` 连接表 2026-06-21 已删,`message_store.ex:80-87`),「谁参与过」只能靠 sender 列 + 「在该 session 有 sender 行」间接推断——这正是 serve-time 查表复查形状的由来。

### 5.2 投递 —— cap 判定 ✅,但「每条消息铸 receive cap」的说法要修正

- **旧引用 stale**:`resolver.ex:238-241` 注释「The Session delivery fan-out mints a `:receive` cap PER recipient」是 **A2.2 之前的旧机制描述**(RF-6 gate 本身仍 load-bearing,但理由句过时)。现行 delivery 呈交**零 cap**:`dispatch_receive_call/3` 显式 `caps: MapSet.new()` + 注释「delivery presents NO receive cap……the ephemeral `member_receive_caps/1` bearer token is DELETED」(`apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex:296-306`)。
- **真机制 = join 时一次性 + 收方自查**:成员 join 时 `MemberCap.grant_at_join/2` 铸普适 member-cap `cap(:session, Ezagent.ActionSet.Session, :receive, session_uri, ws)` 进成员自己 `:identity` slice(`apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex:31,:259-267`;granter=session owner,#154);leave/remove 同步 revoke(`member_cap.ex:139-151`)。`:receive` 动作在 step 5.5 是 **cap-exempt**(`behavior/user/receive.ex:187` + `behavior/agent/receive.ex:283`),授权在 handler 内:`MemberReceive.authorize/1`(`apps/ezagent_domain_identity/lib/ezagent/session/member_receive.ex:78-85`)查收方 pre-loaded `:identity` sibling slice 里是否持对 `ctx.caller`(源 session)的 member-cap,K4 provenance 过滤(须 real-entity granted),fail-closed。
- **cap 的 instance 轴 = session URI**(`member_receive.ex:102-109` 按 `cap.instance == session` 匹配),**不是 message**。即:不是每条消息/每次投递铸 cap,是每成员每 session 一把、revoke 即时生效(零 bearer 窗口)。判定:✅ cap 判定(形态=一次性 member-cap + in-handler 自查)。

### 5.3 读 —— 内部面 ❌ 无判定;held-cap 判定只在外部面

- **world 会话页读史全链**:`WorldLive.handle_params` → `maybe_set_current_session`(`world_live.ex:78-111`)→ `ConversationSessionState.state_for`(`conversation_session_state.ex:59-69`)→ `ConversationData.state_for` → `load_messages`(`apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:37-42,:409-422`)→ `MessageStore.recent_in_session` / `recent_visible_in_session`(`apps/ezagent_core/lib/ezagent/message_store.ex:142-174`)——**纯 Repo 查表,无 get_slice、无 dispatch、无 cap/membership 判定**。
- `caller_caps` 唯一用途是 `read_unfiltered?`(`conversation_data.ex:416-422,:432-458`):持 `:read_unfiltered` cap 才能看 `:internal` 消息;普通消息默认 `:external_visible`(§5.1),**任何进得了页面的登录者都能读**。
- **「进得了页」的门**只有:`RequireEntity`(登录)+ workspace 选择;session 列表虽按 member_uris fail-closed 过滤(#1217),但 `?session=` 深链直接给 URI 就读——且 `self_join` 被拒**明文 degrade to observe**:「A denial degrades to "observe" — the viewer still sees the conversation」(`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:1066-1067,:1109-1116`)。读不依赖成员身份,连 roster 都不查。
- **有 held-cap 判定的读路在外部面**:`Ezagent.Session.Membership.authorize/3`(owner ∨ roster∧held member-cap,与 receive 共用 `holds_member_cap_over?` 同一谓词,`apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex:55-83`)用在 `chat_feed.ex:137`、`external_feed.ex:402`、`socialware_publisher_read.ex:202`、`session_config/admission.ex:13`。**倒挂**:匿名/外部读比登录内部读判得严。判定:❌ 查表无判定(内部面)。

### 5.4 附件 —— 上传 ✅ / 预签在无判定读路内 / serve-time ⚠️ 查表

- **上传**:`POST /world/uploads` → `authorize_attach` dispatch `:session :attach`(`apps/ezagent_web/lib/ezagent_web/controllers/world_uploads_controller.ex:125-141`),与 `:send` 同 chokepoint 同参与 tier 共授(:10-20)——✅ cap 判定。成功后存 ws 分区 uploads + 返 anti-laundering grant(uri↔caller↔session Phoenix.Token,:150-156)。
- **挂进消息**:composer 下次 `chat.send` 带 grant,`build_message` 验 grant 后把 `resource://…/uploads/…` 放进 `body.attachments`(`conversation_data.ex:381-398`)。
- **渲染预签**:chat 侧 `attachment_row → DownloadToken.mint!(uri)`(`conversation_data.ex:549-566`)——**mint 无 caller 参数,payload 只有 `{uri, issued_at, ttl}`**(`apps/ezagent_core/lib/ezagent/uploads/download_token.ex:66-67,:92`,TTL 默认 300s :61),bearer token;且这一步发生在 §5.3 的**无判定读路**里——observer 也拿到 token。kanban 侧 `world_data.ex:403-412` 同一 mint,但发生在 cap-gated `:get_tree` dispatch 的响应整形内(`world_data.ex:239-249` `dispatch_ctx` 带登录者身份/caps)——kanban 预签反而有 cap 门在前。
- **serve-time 复查**:`uploads_controller.download/2`(`uploads_controller.ex:89-100`)verify token 后跑 `authorized?/2`(:110-157)= admin ∪ 上传消息 sender ∪ 「向附件所路由 session 发过消息」(`caller_sent_in_any_session?` :199-210)——全 Message 表 SQL(body LIKE 找候选 :159-174 + sender/session_uri exists 查询)。⚠️ 查表捷径。**但注意它的自我定位**(:42-54):正因为渲染面「renders a token link for everyone who can VIEW the session……includes observe-only callers」,minting alone would WIDEN access,才必须有这道复查——**查表复查是给读路无 cap 门打的补偿,不是孤立的偷懒**。

### 5.5 判定表 + 断言裁定 + 修法重述

| 环 | 判定 | 锚 |
|---|---|---|
| 发(send) | **cap 判定 ✅** | session.ex:147-153 + runtime.ex:319 |
| 投递(receive) | **cap 判定 ✅**(join 一次性 member-cap + in-handler;非 per-message 铸) | member_cap.ex:259-267 + member_receive.ex:78-85 |
| 读(内部会话页) | **无判定 ❌**(查表 + visibility 过滤;observe 也可读) | conversation_data.ex:37-42 + conversation_actions.ex:1109-1116 |
| 附件上传 | **cap 判定 ✅**(:attach dispatch 同 send chokepoint) | world_uploads_controller.ex:125-141 |
| 下载 serve-time | **查表捷径 ⚠️**(Message 表推断「参与」) | uploads_controller.ex:110-157 |

**断言裁定:半成立**。「消息本身已符合 CapBAC」对**写路和投递**成立(send/attach/receive 三处都是真 cap 判定),对**读路不成立**——内部读史本身就是查表零判定,和下载复查是同一窪地(且后者是前者的补偿)。「下载检查是偷懒查表」成立,但它不是相对「消息已 CapBAC」的孤立退化,而是**读面从来没有 cap 门**的诚实后果。

**修法重述**(替代「回归读路的 cap 判定」这一表述——读路现状没有可回归的 cap 判定):下载对齐的对象是**系统里已存在的 held-cap 读判定语义** = 外部读的 `Membership.authorize/3`(消息宿主=session 的钥匙)∪ mount/composition 的宿主钥匙(板的 read cap,#154)。落到 file:line:
1. **core** `download_token.ex`:payload 加可选 `grantee`(`mint!/2` opts 扩展,`verify` 返回携带);
2. **web** `uploads_controller.ex:89-100`:token 带 grantee → 验 `caller == grantee` 放行;无 grantee → 走 :110-157 旧复查,零破坏;
3. **签发面过真门才有资格签 person-bound**:kanban 点击现签在 `get_tree` cap-gated dispatch 内(`world_data.ex:239-249`)已满足;chat 侧现签 action 签发前补 `Membership.authorize/3`(`membership_predicate.ex:55`)——chat 附件的「参与」判定从『发过言』(⊊ 成员)修正为『持 member-cap』,与外部面/receive 同一谓词,消 drift;
4. **另立项不阻塞 ㊲**:内部会话页读史零判定(observer 全可读)与 #1217 列表 fail-closed、外部面 held-cap 的倒挂;`resolver.ex:238-241` stale 注释顺手修。

---

## 六、一句话总结

四条模型:①部分成立(物化成 agent 是拍板方向;「都是聊天」在 dispatch=广义说话意义下成立,chat/action 是一个 fabric 两个 register,RF-6 只挡 principal 身份不挡对话)/②部分成立(chat=成员制会话容器,过滤在 routing 层)/③成立(step 5.5 单点+双向 cap)/④**成立**——㊲ 是「参与」概念的 chat-register 旧窄实现,泛化为「消息参与者 ∪ 宿主钥匙持有者」即架构对齐修法,动 core 载体需过 Allen。

倒转方案(§四):机制可行且便宜(`session.send` + `hops: 0` 只存不路由 + `visibility: :internal` 不进聊天面,plugin 层 ~20 行),零契约修好上传者本人 403;但「发过言的人」⊊「持钥人」,人本位分享(跨 session/只读 sharee)在任何容器选择下都覆盖不了——倒转是泛化分支的真子集,作补充不作替代,主修法仍是泛化授权分支。
