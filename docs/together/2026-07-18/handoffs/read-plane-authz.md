# Handoff@Allen: 对话读面无门系列(现象=附件下载 403,根因=读路零 cap 判定)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** Allen
> **Base:** `origin/main` @ `d533a5d73` · **证据源:** `docs/notes/2026-07-18-attachment-x-model.md` §五(全链逐环 file:line 查验)
> **Status:** 定性 + 请 Allen 排修法——**这不是一个「下载 bug」**。授权读面是你 gate 的领域(P2 授权契约 Allen-gated,uploads_controller.ex:5-9),我们不擅动;本文只把现象→根因系列钉实,附建议方向,分层分期由你排。

## 0. 一句话定性

㊲(kanban 附件下载 forbidden)只是**入口现象**。逐环查验后的结论:消息的**写路和投递都有真 cap 门,唯独读面从来没有**——下载 403 是「对话读面无门」这一系列深层问题在附件面的诚实后果,不是孤立的传参/查表 bug。修下载而不认读面,是把补偿当病灶。

## 1. 现象(入口)

板节点附件 → 打开 → forbidden;非 admin 连**上传者本人**都被拒;tab 停留 >5min 再点必 `:expired`(渲染成同一 forbidden)。

## 2. 根因系列(四层,由深到浅;file:line 全部来自 attachment-x-model §五现读)

### 2.1 读消息零 cap 判定(最深层)

world 会话页读史全链:`WorldLive.handle_params` → `ConversationData.state_for` → `load_messages`(`apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:37-42,:409-422`)→ `MessageStore.recent_in_session` / `recent_visible_in_session`(`apps/ezagent_core/lib/ezagent/message_store.ex:142-174`)——**纯 Repo 查表,无 get_slice、无 dispatch、无 cap/membership 判定**。`caller_caps` 唯一用途是 `read_unfiltered?`(内部消息管理面,`conversation_data.ex:416-422`);普通消息默认 `:external_visible`(`message.ex:121-123`),**任何进得了页面的登录者都能读**,连 roster 都不查。

### 2.2 被拒 join 仍可 observe 读

`self_join` 被拒**明文 degrade to observe**:「A denial degrades to "observe" — the viewer still sees the conversation」(`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:1066-1067,:1109-1116`)。session 列表虽按成员 fail-closed 过滤(#1217),但 `?session=` 深链直接给 URI 就读——**准入被拒 ≠ 读被拒**,门形同虚设。

### 2.3 下载 serve-time 查表复查 = 给无门读面打的补偿

`UploadsController.authorized?/2` = admin ∪ 上传消息 sender ∪「向附件所路由 session 发过消息的人」,全查 Message 表(`apps/ezagent_web/lib/ezagent_web/controllers/uploads_controller.ex:110-157,:199-210`,body LIKE 找候选)。**它的 moduledoc 自己说破了因果**:正因为渲染面「renders a token link for everyone who can VIEW the session……includes observe-only callers」,minting alone would WIDEN access,才必须有这道复查(`uploads_controller.ex:42-54`)。即:查表复查不是孤立的偷懒,是 2.1/2.2 无门读面的**补偿**——而它用「发过言」推断「参与」,把 kanban 附件(action dispatch 写入,零 Message)和潜水成员、跨会话分享点击者一律误杀。

### 2.4 token 无人绑定

`DownloadToken` payload 只有 `{uri, issued_at, ttl}`(`apps/ezagent_core/lib/ezagent/uploads/download_token.ex:66-67,:92`),**bearer token 不认人**,TTL 300s(`:61`);且 chat 侧渲染预签发生在 2.1 的无判定读路里(`conversation_data.ex:549-566`)——observer 也拿到 token,泄漏后同 ws 任何参与者可重放。

## 3. 对照面:系统里不是没有门,是读面独缺

| 环 | 判定 | 锚 |
|---|---|---|
| 发(send) | **cap 判定 ✅**(`caps: [:send]` 过 step 5.5) | `behavior/session.ex:147-153` + `kind/runtime.ex:319` |
| 附件上传 | **cap 判定 ✅**(`:attach` dispatch 与 send 同 chokepoint) | `world_uploads_controller.ex:125-141` |
| 投递(receive) | **cap 判定 ✅**(join 一次性 member-cap + 收方 in-handler 自查) | `member_cap.ex:259-267` + `member_receive.ex:78-85` |
| 读(内部会话页) | **无判定 ❌**(查表 + visibility 过滤;observe 也可读) | `conversation_data.ex:37-42` + `conversation_actions.ex:1109-1116` |
| 下载 serve-time | **查表捷径 ⚠️**(Message 表推断「参与」,= 读面无门的补偿) | `uploads_controller.ex:110-157` |

**倒挂**:持 held-cap 判定的读路反而全在**外部面**——`Membership.authorize/3`(roster ∧ held member-cap,`membership_predicate.ex:55-83`)用在 `chat_feed.ex:137` / `external_feed.ex:402` / `socialware_publisher_read.ex:202`。匿名/外部读比登录内部读判得严。

## 4. 建议方向(仅方向,不越权定案)

我们不擅动读面授权契约,以下只给对齐系统已有语义的方向,**修法版本/分层/分期请你排**:

1. **读面回归 cap 判定**:内部读史对齐系统里已存在的 held-cap 读判定语义——外部读的 `Membership.authorize/3`(消息宿主=session 的钥匙)∪ mount/composition 的宿主钥匙(#154 granter=data_owner)。「参与」的一等表达=「持有对宿主的 cap」,不是「发过言」。
2. **token 绑人**:`DownloadToken` 加可选 `grantee`(person-bound),serve-time 验 `caller == grantee`;无字段走旧复查,零破坏。签发面须在真 cap 门内(kanban 点击现签已在 `get_tree` cap-gated dispatch 内,`world_data.ex:239-249,:403-412`;chat 侧现签前补 `Membership.authorize/3`)。防泄漏比现状强:bearer 变 person-bound,泄漏换人无效。
3. **分层分期由你排**:哪层先修(只修下载补偿面 = 局部止血;连读史无门一起修 = 系列除根)、2.1/2.2 是否本轮动、与 #1217 fail-closed 口径如何拉齐——都是你 gate 的授权契约决策,我们不预设。

## 5. 关联与不阻塞项

- 同线另一 handoff `uploads-person-token`(开工单 infra #4,kanban-collab-round2 线)是本系列**下载面的局部修**;若你排全盘,它是第一期候选,两者不冲突。
- 顺手项(不阻塞):`resolver.ex:238-241` 「fan-out mints a :receive cap PER recipient」注释是 A2.2 前 stale 说法(现行 delivery 呈交零 cap,`delivery.ex:296-306`),待修。
