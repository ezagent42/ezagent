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
- **一个 fabric**:跨 Kind 唯一路径是 dispatch(P14);cap 检查「严格只在 dispatch step 5.5 发生一次」(`ARCHITECTURE.md:1428`)。chat 本身就是 dispatch 上搭出来的:Chat 是 Behavior——Session 消费 `send/join/leave`,User+Agent 消费 `receive`(Decision #88,`GLOSSARY.md:117`);一条聊天消息 = `send` dispatch 进 session,fan-out 成给每个成员的 `receive` dispatch,**且 per recipient 铸 `:receive` cap**(`apps/ezagent_core/lib/ezagent/routing/resolver.ex:239-240`)。所以「dispatch 是广义的说话」不是比喻,是实现事实。
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
- 「谁和谁」:cap 绑 target URI + grantee(#1386 sign-the-grantee);「哪些话」:cap 绑 action subject。收方向也对称:`:receive` cap per recipient(`resolver.ex:239`)。
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

## 三、给 Allen 的论证段(需过 Allen——P2 授权契约本身就是 Allen-gated,`uploads_controller.ex:5-9`)

> Allen,㊲(kanban 附件下载 forbidden)想动 core 的 `DownloadToken`,过你一眼。根因不是 kanban 签错了什么:serve-time 的参与复查(admin/上传者/session 参与者)全查 Message 表,而 kanban 附件是 attach_artifact dispatch 直接写板 slice、不产生 Message——非 admin 连上传者本人都 403。这道复查是 codex 防 token 泄漏要求「冻结 pre-P2 契约」加的,当时附件只存在于聊天;现在附件也长在 action-dispatch 面(板节点),「参与」的判定需要泛化成「消息参与者 ∪ 宿主钥匙持有者」——这跟你拍的 #154(granter=data_owner)和 mount 发 person keys 是同一个语义:参与一段对话 = 持有对宿主的 cap。修法:DownloadToken 加可选 `grantee` 字段(person-bound,签进 payload),controller 对 person-bound token 只验 caller==grantee(mint 侧本就 cap-gated 后才签);旧 token 无字段走旧复查,零破坏。防泄漏比现状强:bearer 变 person-bound,泄漏换人无效。codex 的「不 auth-widening」约束保住了——不是删复查,是用更强的载体替代。kanban 侧配合点击现签解 TTL。要动 core 授权载体 + web 授权分支,所以先过你。

---

## 四、一句话总结

四条模型:①部分成立(物化成 agent 是拍板方向;「都是聊天」在 dispatch=广义说话意义下成立,chat/action 是一个 fabric 两个 register,RF-6 只挡 principal 身份不挡对话)/②部分成立(chat=成员制会话容器,过滤在 routing 层)/③成立(step 5.5 单点+双向 cap)/④**成立**——㊲ 是「参与」概念的 chat-register 旧窄实现,泛化为「消息参与者 ∪ 宿主钥匙持有者」即架构对齐修法,动 core 载体需过 Allen。
