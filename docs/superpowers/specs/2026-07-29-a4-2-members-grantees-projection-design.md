# A4-2 — `:members` roster 投影到 `grantees_of`【设计 v3 · 对抗取证复核后重写】

- **status**: proposed — design-first,待 Allen 对齐。**v3 的结论比 v1/v2 严重:按原 scope(直接换源)今天不安全。**
- **task**: A4-2(URI-share 统一授权:两步 `:members` 迁移的第二步)
- **base**: `origin/main`(A2-2 #1606 已合,merge commit `cc31d1dd`;本文 file:line 全按 main 现读核对)
- **前身 PR**:#1620(base 是 A2-2 分支,#1606 合入删 base 后被 GitHub 连带关闭;本设计换 base=main 重开)

> **修订史**
> - **v1**(2026-07-29):列了 5 维语义差(behavior/action/provenance/generation/admin-wildcard),结论"必须加 action 过滤",provenance 与 trusted-internal 作为**开放问题**留给 Allen。
> - **v2**(2026-07-30 早):重锚合并后的 A2-2;曾把 provenance/trusted-internal 说成"新发现",**属夸大**——v1 §3.2/§3.4 与 #1620 body 的开放问题 4 都已提出。v2 亦把 `:join` 说成"pending joiner 持久状态",**措辞不准**。
> - **v3**(本文):两轮**专门证伪**的只读取证后重写。**结论从"加个 action 过滤即可"升级为"索引与 roster 在两个方向上都不等、且不是同一个源,不能直接换"。**

---

## 0. 意图:这件事到底为什么做(**不是性能**)

A4-2 是 **#192「成员真相有两份」** 的收尾件 —— 属 P3(单一真相源)违规,不是"把全扫换成索引查询"的性能优化。权威表述见 allenwoods 的研究备忘 `docs/notes/2026-07-30-decentralization-hypothesis.md` 第 9 行(已在 main):

> 成员真相住在**两个地方**:(i) session 的 `:members` roster(chat-slice map,唯一写者 `add_self`)—— **投递目标,显式容忍陈旧,不携带任何权限**;(ii) 每个成员**自己** `:identity` store 里的 member-cap —— **动作时授权**(撤销 ⇒ 立即拒收)。
> 入会时的授予是 `:async` best-effort **出于必然** —— 在 `handle_join` 内同步授予会**死锁** session 创建(已实证)—— 所以**漂移是结构性的**:要么 roster 有陈旧条目(fail-closed,无 cap 就收不到),要么**只有 cap 没进 roster(没被当作投递目标,直到被 heal)**。
> 已落地:M-6、**M-8**(`reconcile_after_load` 从并集翻成**精确 cap 持有者投影** —— "caps win",补齐 + 驱逐)、#1611。
> **#1620 计划把 `:members` 做成纯投影 —— 今天它仍然是单独存储的,只是被 reconcile 一下。**
> 分类:**[B] textbook** —— 两个成员真相源;归属权(caps)正在指派中。

**所以 A4-2 的目标 = 把 roster 从"第二真相源"降级成"caps 的纯投影"**,让"谁是成员"只有一个答案:谁持有 member-cap。

**两条必须先说清的口径(直接决定验收标准):**

1. **roster 不是权限,只是投递目标**。收信闸(M-9 `holds_member_cap_over?`)在**投递时**独立查 member-cap 并过完整 `Cap.authorize` —— 这一条**保持不变**。⇒ roster **稍旧是安全的**(fail-closed),目标不是"集合永远完全相等",而是"**不丢投递**"。
2. 因此 §2 的七类差异**危害不等** —— 但**必须把"roster 多报"和"钥匙没撤"分开算**(本文 v3 初稿把两者混为一谈,Allen 2026-07-31 纠正,已改):
   - **过报(roster 多出人)本身**:投递到他 → **收信闸当场拒**(M-9 查 `:receive` 并过完整 `Cap.authorize`),不泄漏消息内容;真实危害只有"成员名单 UI 显示了前成员/从未加入者"(`SessionReads.members` 会读它)。**级别:正确性/观感,fail-closed。**
   - **⚠️ 但造成过报的那个根因不是 fail-closed**:离会只撤 `:receive`,残留的 `:send`/`:attach` **在发送路径上没有任何东西挡** —— `Verifier` 的 `@non_cap_actions`(`verifier.ex:21-41`)对 `Ezagent.ActionSet.Session` 只免验签 `[:approve_admission, :deny_admission, :withdraw_admission, :composition_consent, :add_self]`,`:send`/`:attach` 走正常 cap 验签;而 `handle_send/2`(`session.ex:591`)**除 cap 外零成员校验**。⇒ **已退出成员仍能发言/传附件 = write-after-leave,撤销完整性漏洞**。**级别:安全缺陷,已单开 issue #1665,且按 Allen 裁决排在 P4 之前。**
   - **漏报(cap 持有者不在 roster)**:**他收不到消息,直到被 heal** —— **真丢投递**。**级别:功能损坏,必须先修(P1)。**

## 0c. Allen 裁决(2026-07-31,已落入下方各节)

1. **授权门 —— 否掉"会话自证",改走 ActionSet 分层**:查 `GranteeIndex` 的应当是 **`ActionSet.Session.Membership`**(它本就是"成员"这件事的机制/权威层,grant/revoke 参与权就是它做的),**不是 Session 实体** —— 实体永远不直接读 cap 表。做法 = 给 `GranteeIndex` 加一个**内部机制入口**(如 `members_of(target)`),**不走** `grantees_of/4` 的 `manages?` 人类管理员闸(调用方是机制在算自己域内、单一目标的投影,属 platform mechanism 声明,不需要用户级 cap witness);**面向外部枚举的 `grantees_of/4` 保持 `manages?` 不变**。→ **本设计原提的 "target 自读 arity" 作废,不需要发明新授权机制。**
2. **cutover 已激活**:prod 实测 `Ezagent.Identity.Cutover.activated?() => true`(status `:active`),canary 同;**P4 的 epoch 前提已满足,可照常排**(§2.4 的顾虑消解)。
3. **撤销完整性单开且前置**:见上方 ⚠️ 与 issue #1665,**排在 P4 之前**(否则换源后历史成员会被全部算回 roster)。
4. **执行顺序**:P1 →(#1665 撤销完整性)→ P2(含裁决 1 的内部入口)→ P4。每步独立可合。

⇒ **优先级:先修漏报,再收敛过报。** 而漏报里最主要的那条(钥匙还在投递 outbox、尚未落库)**恰好就是 #207/#1501 已记在案的残留**("`EntityCaps.load` 只读已持有的 cap,没有并入 pending outbox 行")—— 同一件事,不是新问题。

---

## 0b. 结论摘要

1. **action 过滤:仍然必需**,而且有**两条独立**理由(§2.1)。
2. **但远不止如此** —— 把 roster 换成 `grantees_of` 查询**不是等价替换**:
   - **过报**(索引多、roster 少):5 类(§2.1)
   - **漏报**(索引少、roster 多):2 类,其中 `:receive` 成员 cap 走 **cast + delivery outbox**,冷 principal 刚 join 时索引里根本没有(§2.2)
   - **源不同**:reconcile 用的 `EntityCaps.load/1` 是 **live-first 读活 slice**,索引只从 `Store` 写派生;**pre-epoch 两者不相交**(§2.3)
   - **epoch**:测试强制 post-epoch,而 dev/prod 在 operator 跑 cutover 前是 pre-epoch → **测试全绿不代表 dev/prod 一致**(§2.4)
3. 因此 v3 建议:**A4-2 先做"等价性修复"这一层(§3 的 1-4),并把换源排在 #189 cutover 激活之后**;或者由 Allen 拍板接受"roster = best-effort 投影"的语义降级。

## 1. 现状(origin/main 行号)

**改写目标** —— `apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex`(共 143 行):
- `reconcile_after_load/2` **L56**;`candidate_uris/1` **L83**(枚举 workspace 内 users〔含 anon〕+ agents + workers,经 `InternalReads`);`member_cap_holder?/3` **L113**;`member_cap/2` **L134**。
- 匹配是**含 action 的 5 元组** `Capability.identity_key`(`capability/match.ex:74-82`),先过 `granted_by_entity?`(**L118**,K4 provenance)。
- **L103-111 注释显式说明:故意不用 `matches?/2`** —— 否则 admin 的 all-`:any` genesis cap 会"re-add admin into `:members` of EVERY session on reload"。

**M-9(不碰)** —— `MemberReceive.holds_member_cap_over?/3`:要求 `action_of(cap) == :receive` + concrete instance + provenance,并过完整 `Cap.authorize`。moduledoc 明写:按 `kind/action/instance` 这些**稳定识别字段**匹配,而**故意不锁 `Ezagent.ActionSet.Session` 这个 behavior 模块**。

**A2-2 索引(已合)** —— `apps/ezagent_domain_identity/lib/ezagent/entity_caps/grantee_index.ex`:
- `grantees_of/4` **L113-114**(`(target, caller, caller_caps, behavior \\ :any)`,收**呈交的已认证 caps**),授权门 **L119** `Identity.Authority.manages?(caller, target, caller_caps)`。
- `maybe_filter_behavior` **L160/L162** —— **只过滤 behavior,无 action 维**。
- schema `field(:action, :string)` **L50**(列已存在,读路径不用)。
- `row_attrs/2` 只收 concrete instance **L202**,非具体的 catch-all 返 `[]` **L231**。
- `backfill_all` **L151-158**,只枚举 `Store.active_uris()`(`store.ex:204-206`)。
- migration `20260730010000_create_cap_grantee_index.exs:33-37`:`flush()` + `backfill_all()`。
- **`grantees_of/4` 目前零生产调用点** —— 索引现在是 write-only,没有任何生产运行证据。A4-2 会是它的首个消费者。

## 2. 语义差:两个方向都不等

### 2.1 过报(索引会返回不该进 roster 的人)

| # | 来源 | 证据 |
|---|---|---|
| **A** | **`:join`-only** —— 被邀请拿到 tier-0 `:join` cap、**从未 join** 的人。behavior 同为 `Ezagent.ActionSet.Session`、instance 同为该 session | `membership.ex:1071-1086` `do_grant_join_cap`(落库路径);`provision_join_authority/2` **L590** |
| **B** | **离会残留参与档** —— 离会/被移除只撤 `:receive` 一把,`:send/:leave/:attach` **从不撤销** | 发:`@member_chat_actions` `membership.ex:538` → `member_cap.ex:141`/`:147`;撤:`member_cap.ex:349`(`member_cap/2` **只构造 `:receive`**,`:353`)+ `revoke_membership` `:241`;调用点 `membership.ex:760`(leave)、`:946/:970/:1002`(remove) |
| **C** | **provenance 未过滤** —— reconcile 过 `granted_by_entity?`(`reconcile.ex:118`),索引只存裸 `granted_by` 字符串、读路径不判 | `capability.ex:325-326`(`system://` 授予者 → false) |
| **D** | **self-license 全有全无门 / RevocationFence 只作用于 `EntityCaps.load`** —— 持有人自身 regenesis 后、下次 cap 写之前,`load` 返回 `[]`(非成员)而索引仍报它是 grantee | `entity_caps.ex:558-563`(self-license 门)、`:74`(fence) |
| **E** | **撤销/墓碑不 reindex** —— `revoke_provisioning`(`store.ex:1031`)/ `tombstone`(`:1045`)走 `transition_locked`(`:1126-1145`),**里面没有 reindex**;索引行残留,靠读侧 `grantee_active?`(`grantee_index.ex:142`)兜 | 读能兜住,但 Store moduledoc 那句"sole downstream confluence of EVERY conferral path"在**写侧是不完整表述** |

> 注:**owner/admin 的 manage cap 不是过报来源** —— 它 behavior 是 `Ezagent.ActionSet.Manage`(`creator_grant.ex:20-31`),本就被 behavior filter 挡掉。v1 曾拿它举例,不成立。
> 注:**admin genesis wildcard 天然不入索引**(instance `:any` 撞 `row_attrs` 的 concrete-only 子句 L202/L231)→ 索引**结构性**地挡住了 `reconcile.ex:103-111` 手动挡的那个陷阱,这一条是白捡的好处。

### 2.2 漏报(索引查不到该进 roster 的人)—— v1/v2 完全没有识别

| # | 来源 | 证据 |
|---|---|---|
| **F** | **`:receive` 成员 cap 走 cast + delivery outbox** —— 它**不走** `grant_cap_via_router`,走 `Grant.issue_cap`(只签发不落库)+ `Identity.absorb_cap`(`:cast`,先进 capability delivery outbox)。冷/离线 principal 刚 join 时 cap 还在 outbox、Store 尚未写入 → **索引查不到他**,而 `effective_read` 显式把 outbox 里 pending 的并进"有效 caps"(`entity_caps.ex:212`),join 幂等判断(`member_cap.ex:50`)用的就是这个 | 发放 `member_cap.ex:70-88`;`grant.ex:97-102`(issue_cap)/`:113-124`(issue_and_absorb);`identity.ex:158-181`(cast + outbox) |
| **G** | **user 侧唯一落库口要求 `users` 行存在** —— `persist_entity_caps` 对非-user 或无 `users` 行的 user **静默 no-op** | `behavior/identity.ex:808-814` |

> **agent 侧不漏**(这条我原本预期会漏,查实是不漏的):agent 的 caps 经 snapshot 提交走 `Store.sync_committed_identity`(`store.ex:597-633`,`:618 persist` → reindex),agent 是 `{:snapshot, :on_change}`。

### 2.3 源不同(最根本的一条)

`reconcile.ex:117` 用的 `EntityCaps.load/1` 是 **live-first**:先 `Kind.read(uri, :identity, spawn: :never)` 读**活进程的 `:identity` slice**(`entity_caps.ex:101`),只有 `{:error, :not_live}` 才落持久读;而持久读本身还 epoch 分叉 —— post-epoch 读 Store(`entity_caps.ex:166-172`),**pre-epoch 读 legacy caps_json / snapshot,完全不碰 Store**(`:174-186`)。

而 `GranteeIndex` **只从 Store 写派生**。⇒ **pre-epoch 两者源不相交;post-epoch 也只在"冷读"时重合,热路径读的是 live slice。**

### 2.4 epoch:测试与 dev/prod 不同口径

**先把口径说准(避免"#189 没落"的误读)**:**#189 的代码已经合了,而且是刻意做成 DORMANT 的** —— 翻不翻 epoch 是一个**运维动作**,不随合并发生。逐条实证:

- migration `20260729130000_create_identity_cutover.exs` **只建表、不插行**,其注释即设计声明:「Merging PR-3 does **NOT** flip production reads to the store; it lands the store-authoritative code **DORMANT** behind this epoch. The operator activates the epoch **ONLY after** `mix ezagent.identity.cutover` runs the backfill + the fleet-parity barrier … and the barrier reports COMPLETE.」
- 判定(`identity/cutover.ex:144-156` `db_status`):**有行 → `:active`;无行 → 明确 `:inactive`(真 pre-cutover 节点);读不到 → `:unknown` 且不缓存**,gated 消费者一律 fail-closed 回落 legacy 语义。
- `Cutover.activate/0`(`cutover.ex:218`)的调用者**只有** `mix ezagent.identity.cutover`(`mix/tasks/ezagent.identity.cutover.ex:24`)与 `cutover/runbook.ex:194` —— **boot 不跑**(各 app `application.ex` 无调用点)。
- `config/test.exs:47` 强制 `identity_cutover_active_override = true` → **测试套跑在 post-epoch**;而 #1627 MAJOR-3 把该 override 做成**编译期 `MIX_ENV=test` only**(`cutover.ex:119` `@override_seam = Mix.env() == :test`)→ **dev/prod 构建里 override 整个被编译掉**,只能读 DB 那一行。
- pre-epoch 下镜像失败被**吞成 `:ok`**:user 侧 `user_store.ex:207-229`;agent 侧 `store.ex:628` → `:659-664 swallow_pre_epoch`。

⇒ **"原子同事务、永不过报"的论证只在 epoch 已激活的库上成立**;在尚未跑过 cutover task 的库(含本地 dev)上,索引一致性是 best-effort。**最危险的一条:CI 全绿不代表线上一致。**
⇒ **代码答不了的一问**:目标环境(canary / prod)到底跑过 cutover task 没有?查法 = 该库 `identity_cutover` 表有无那行,或节点上 `Ezagent.Identity.Cutover.activated?()`。**若已激活,§3b-P4 的这条顾虑即消失。**

### 2.5 存量覆盖

`backfill_all` 只枚举 `Store.active_uris()`(仅 `identity_status = 'active'` 的行);`identity_caps` 表本身 `20260728120000` 才建,比索引早两天。⇒ **存量是否已完整索引,取决于这两天 shadow 镜像实际写了多少,不能假设是全的。**

## 3. 提议(修正后的 A4-2 scope)

**必需(缺一不可,全在 A2-2 层)**:
1. **action 维过滤** —— 列已存在(`grantee_index.ex:50`),照 `maybe_filter_behavior`(L160/L162)加 `maybe_filter_action` 即可(~5 行)。注意 `behavior \\ :any` 默认参数的歧义。加 `where action == "receive"` **不会误排除任何当前成员**(§2.1 注),反而精确复刻现有语义。
2. **provenance 过滤** —— 加派生列,或读侧按 `granted_by` 判是否 entity URI。(v1 §3.2 的选项 (b)「`(S,Session,:receive)` 只可能实体授予」**已被证否**:索引不区分,而 reconcile 确实在过滤。)
3. **补 `revoke_provisioning` / `tombstone` 的 reindex**(§2.1-E),或把"读侧 `grantee_active?` 兜底"写进契约并测。*(与 allenwoods 2026-07-30T09:50:46Z 在 #1606 复审里要求补 `activate_locked` reindex 是同一类问题的延伸。)*
4. **处理 pending absorb outbox**(§2.2-F):查询时并进 outbox,还是 join 后 `await` 落库再 reconcile?
5. **明确 epoch 语义**(§2.3/§2.4):**建议把换源排在 #189 cutover 激活之后**,否则索引在 dev/prod 不是权威源。

**授权门 —— 已由 Allen 裁决(2026-07-31),不再是开放问题**

背景(为什么它曾是问题):`grantees_of/4` 的第一道门是 `manages?(caller, target, caller_caps)`,而 reconcile 在 `activate` 里跑、无 user caller。三个候选走不通:`manages?/3` 函数头要求 `%URI{} = caller`,catch-all 对 `:vm_internal` 直接 `false`(与 `kind/runtime.ex` 的 `:vm_internal` 旁路不是一套机制);可借的系统主体**已被 #154 清空**(`system_principal/catalog.ex:99, :255-280`);测试里手搓的 admin witness **绝不能进生产**。

**裁决(采纳,替代本文原提的"target 自读 arity"):**
- 查 `GranteeIndex` 的是 **`ActionSet.Session.Membership`** —— 它本就是"成员"这件事的机制/权威层(发/撤参与权就是它做的);**Session 实体永远不直接读 cap 表**。
- 给 `GranteeIndex` 加**内部机制入口**(如 `members_of(target)`),**不走** `manages?` 闸 —— 调用方是机制在算**自己域内、单一目标**的投影,属 **platform mechanism 声明**,不是外部 principal 冒名枚举,不需要用户级 cap witness。
- **对外的 `grantees_of/4` 保持 `manages?` 原样不变**(那条服务 dispatch 可达的外部调用)。
- `:members` roster 退化成 `Membership.members_of(session)` 的投影。
- ⇒ **不需要发明新授权机制**:这不是"会话自证",是"机制读自己域"。落点归 P2。

## 3b. 分阶段 plan(建议次序,每阶段独立可合)

**按 Allen 2026-07-31 裁决的顺序**(原 P3 已被裁决消解、折进 P2;新增撤销完整性作为 P4 前置):

| 阶段 | 做什么 | 为什么排这个位置 | 依赖/gate |
|---|---|---|---|
| **P1 — 修漏报(真丢投递)** | roster 派生时把 **pending absorb outbox** 一并算进来(或 join 后 `await` 落库再 reconcile,二选一)。**不换源**,仍用今天的 `EntityCaps` 读法 | 唯一会让成员**收不到消息**的一类;与 #207/#1501 的"held ∪ pending"是同一件事,应一次做掉 | 与 #1501 协调(可能就该合进 #1501) |
| **P1.5 — 撤销完整性(issue #1665)** | 退出/移除时撤销**全部参与档**(`:receive` + `:send`/`:leave`/`:attach`),覆盖 leave(`membership.ex:760`)与 remove 三处(`:946`/`:970`/`:1002`)、user 与 agent 两侧 | **安全缺陷**(write-after-leave,§0 口径 2);且**必须在 P4 之前** —— 否则换源后历史成员因仍持 Session-behavior cap 被全部算回 roster | 独立可合;**P4 的前置** |
| **P2 — 索引侧补齐 + 内部机制入口** | ① `grantees_of` 加 action 维过滤 ② 加 provenance 过滤 ③ 补 `revoke_provisioning`/`tombstone` 的 reindex ④ **加 `members_of(target)` 内部机制入口(不走 `manages?`),对外 `grantees_of/4` 原样不动**(裁决 1) | 前三条是"索引要成为可信派生源"的前置,**现在做不影响任何生产行为**(`grantees_of` 目前零生产调用点);④ 是换源的调用面 | 无;可独立合。③ 与 allen 07-30 在 #1606 要求补 `activate_locked` reindex 同族 |
| **P4 — 换源 + 降级成纯投影** | `:members` 退化成 **`Membership.members_of(session)`** 的投影;不再作为独立真相存储;**实体不直接读 cap 表** | #192 真正的收尾。**epoch 前提已满足** —— Allen 实测 prod `Cutover.activated?() => true`(canary 同) | P1 + **P1.5** + P2 |
| **P5 — 回归与闸** | §5 的双向断言 + M-9 回归 | 收口 | P4 |

**如果只能做一段**:做 **P1**(它修的是真丢投递)。
**如果最终判定 P4 不值得**:P1+P1.5+P2 仍各自有独立价值(修投递丢失 / 补安全洞 / 加固索引),`:members` 维持现状即可 —— 此时 #192 只是收窄而非关闭,应明确记账。

## 4. M-9 保持

A4-2 只改 `reconcile_after_load`(delivery-targeting 投影的 seeding),不碰 `holds_member_cap_over?`(授权谓词)。roster ⟂ authz → M-9 天然保持。**但注意**:§2 的语义差会改变**谁被推消息**,不改变谁有权限。

## 5. DoD

- §3 的 1-4 逐项实现 + 单测。
- **双向集合相等回归**(每条独立断言):
  1. `:join`-only 被邀请者**不**进 roster(过报 A)
  2. 离会/被移除的前成员**不**进 roster(过报 B)
  3. 非实体授予的 cap 持有者**不**进 roster(过报 C)
  4. 持有人自身 self-license 失效后**不**进 roster(过报 D)
  5. `revoke_provisioning`/`tombstone` 后**不**进 roster(过报 E)
  6. **冷 principal 刚 join(cap 仍在 outbox)仍**进 roster(漏报 F)← 今天必红
  7. admin genesis wildcard 持有者不进任何 session 的 roster(结构性保证,回归保护)
- **M-9 回归**:`holds_member_cap_over?` 行为不变。
- **epoch 双跑**:post-epoch(现测试口径)+ pre-epoch 显式用例,或在设计里明确"仅 post-epoch 支持"并让 boot 拒绝。
- 闸:check_invariants(#M-9)/gate.arch/format 全绿;reconcile never-crash fail-safe 保留。

## 6. 交 Allen 的开放问题

**已由 Allen 2026-07-31 裁决关闭的三条:**
1. ~~cutover epoch 前提~~ → **已满足**:prod 实测 `Cutover.activated?() => true`(canary 同),P4 照常排。
2. ~~授权门形状~~ → **改走 ActionSet 分层**:`ActionSet.Session.Membership` + `GranteeIndex` 内部机制入口(不走 `manages?`),对外 `grantees_of/4` 不动;**实体不直接读 cap 表**,原提的"target 自读 arity"作废(§3.3)。
3. ~~离会残留参与档是否单开~~ → **单开 issue #1665**,且定级上调为**安全缺陷**(write-after-leave,非 roster 观感),**排在 P4 之前**(P1.5)。

**仍待定:**
4. **P1 的 outbox 处理方式**:并进查询 vs join 后 `await` 落库再 reconcile?(建议与 #1501 一并定,别两处各修一半)
5. **generation 语义变化**(被撤销成员从 roster 掉出)接受为改进?
