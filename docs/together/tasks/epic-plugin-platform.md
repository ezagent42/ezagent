# Epic: Plugin Platform —— URI-share 统一授权 → kanban 纯化 → plugin-dev gate

- **id**: `epic-plugin-platform`
- **owner**: jjkysy
- **status**: in-progress
- **target 分支**: `epic/plugin-platform`(总任务 PR;子任务 PR **合进这个分支**,整体再入 main —— #189 模式)
- **每日追踪**: plan + review 引用本卡的子任务勾选

## 总任务(一句话)

把"分享"做成 **URI-无关的统一授权 infra**(Group A),用它把 **kanban 插件纯化成自包含、热插拔**、**socialware 纯配置声明预装**(Group B),最终把 kanban 的开发过程与约束**沉淀成 plugin-dev gate**,批量生成其它插件 + sw 模板(类比旧 sw simulation 库);落点(并入 orchestrator MCP vs 新做 dev-guide domain agent)后定。

---

## Group A —— URI-share 统一授权(接近收尾)

> 权威设计/合并路径:Allen 在 #1594 留言 + `docs/together/tasks/group-a-uri-share.md`。

| 子任务 | PR | 状态 |
|---|---|---|
| A1 分享令牌 + `/socialware/claim`(ShareSetting + 飞书 Model A) | #1594 | ✅ **已合 main** `7462f95e1`(2026-07-30) |
| A2-1 `Capability.caps_toward/2` 正向可见性 | #1596 | ✅ 已合 main `145cbbf11` |
| A2-2 `grantees_of` 反向索引 | #1606 | ✅ **已合 main** `cc31d1dd`(2026-07-30;allen 07-30 复审 SOUND) |
| A3 泛化 CompositionConsent 成 URI-share 超集 | #1597 | ✅ 已合 main `f04b2362b` |
| A4-1 删 Mount reconcile 重发 trap | #1611 | ✅ 已合 main `fb35003cf` |
| config role_plugins 挪 config.exs | #1612 | ✅ 已合 main `f7e99d82f` |
| **A4-2** `:members` roster → 纯投影(#192) | **#1655**(接替 #1620) | 🔵 P1 ✅ / P1.5(#1665)✅ / P2 ✅,**CI 全绿**;剩一个收口确认 |
| **A5** 匿名分享(link_anon) | #1619 | ⏳ design **v4** 待 Allen 过 —— **撤回三条错误主张**(见下) |

**A 系剩余两件的现状(2026-07-31)**

**① A4-2 —— 已实现三段,CI 全绿**
P1(roster 派生改读 `effective_caps`,把在途的钥匙算进来)/ P1.5(#1665 撤销完整性,堵 write-after-leave)/ P2(反向索引补齐 action 维 + provenance + 撤销墓碑 reindex + 机制入口)。
剩余是**一个收口确认题**,见下方「A4-2 的剩余 delta」。
*(此前本节写过"不是等价替换 / 三选一 / 授权门只剩一条路"—— 那些是把**手段**〔用反向索引〕当成**要求**〔#192:roster 别再当第二真相源〕后自造的问题,已撤回;授权门也已由 Allen 2026-07-31 裁决为 ActionSet 分层 + 机制入口,已实现。)*

**② A5 —— 设计 v4 已获批,待实现**
撤回过三条错误主张(删 Mount / 硬阻塞是缺 caller / 锚 anon_view_caps);真正缺的是**匿名 feed 里没有"外部资源投影"**(`ExternalFeed.snapshot` 只返回 messages/page/shell)+ 绑定(`MountRow.list_for_session`)零渲染消费者。

---

## Group B —— kanban 纯化 + sw 声明化(下一阶段)

> 目标:证明 infra(Group A + 既有 Mount/socialware 声明化)足以支撑一个业务插件**完全自包含**。
>
> **次序(allenwoods #1587:72-76)**:URI-share 原语先立 → **#1474 rebase 到原语上** → 再合。#1474 目前删掉 `Mount`/`MountRow` 全部并把 `board_provision` 下沉进 plugin —— 后者在 skill-1 的解耦路线图里记为 **"待 Allen 决策 PR-5"**,尚未拍板。

| 子任务 | 状态 | 备注 |
|---|---|---|
| **B1** kanban 插件纯化成自包含 + 热插拔 | ⏳ 待开 | 业务侧**已手测过**;把残留 infra 侵入清零(见 skill-1 kanban⇄infra 解耦路线图残留清单) |
| **B2** kanban socialware 纯配置/声明预装 | ⏳ 待开 | **未手测**;预期会撞其它 agent-runtime 问题 → 归下一阶段修 |

---

## 🚦 执行次序(用户 2026-07-31 拍板)

> **"我们需要把 A4、A5 收尾,kanban 纯化做完,才能转到 socialware protocol + plugin gate 这条线。"**

```
A4 收尾 + A5 收尾  →  Group B:kanban 纯化(#1474)  →  Socialware Protocol + plugin-dev gate
```

与 allenwoods 在 #1587:72-76 的建议次序一致(**先把 URI-share 原语立起来 → #1474 rebase 到它上面 → 再合**)。注意「Mount→Provision/Share 改名 + 删 MountRow 表」**属 Group B 不属 A4**(见下),它正是 #1474 要落在其上的那块。

### A4 收尾清单

> **⚠️ 自我更正(2026-07-31)**:本节一度被我写成 "A4-1..A4-5" 五件套,**是错的**。
> 我把已合入 main 的计划文档 `share-a4-1-reconcile-trap.md:35-37` 里"A4 剩余"那几行
> 当成了 A4 的待办,但**原文明写「归后续(或 Group B 一起)」** —— 那是**延后到
> kanban 阶段**的项,不是 A4 的收尾条件。**A4 = A4-1 + A4-2,做完即进 A5。**

| # | 件 | 状态 |
|---|---|---|
| A4-1 | 删 Mount reconcile 重发 trap | ✅ 已合 `fb35003cf`(#1611) |
| **A4-2** | `:members` roster → 纯投影(#192) | 🔵 **#1655**:P1 ✅ / P1.5(#1665)✅ / P2 ✅,**CI 全绿**;剩收口确认(见下) |

**A4-2 的剩余 delta(一个确认题,不是架构决定)**
#192 的要求是 Allen 备忘里那句:「`:members` 今天仍是**单独存储、只是被 reconcile 一下**,要变成纯投影」——**要求是"别再当第二个真相源",没规定必须用反向索引**。
既然 M-8 已把 reconcile 变成精确 cap-holder 投影、`MembershipConvergence`(`behavior/identity.ex:290`/`:767`)又在钥匙落地时从 caps 自愈、P1 让它连在途的钥匙也算得进,**正向派生已经满足"从 caps 派生"**。
⇒ 待确认:这样是否即可判 #192 收口?(此前我写的"甲/乙/丙三选一"是**把手段〔用 grantees_of〕当成了要求**后自己制造的取舍,已撤回。)

### Mount 改名 / 删表 —— **归 Group B,不属 A4**
`Mount→Provision/Share 改名 + 删 MountRow 表`、`unmount 取 actions 脱 MountRow`、`backfill 改派生`:计划文档原文即「碰 kanban 消费者…归后续(或 Group B 一起)」。且实证一个必须先解的点 —— **`access: :read` / `:operate` 只存在于挂载表的列**(`mount_row.ex:62`),cap 上没有该字段(`mint_cap` 只收 actions),两者在 cap 层只差"发了哪些动作",而那份只读动作清单住在 **kanban 策略层**(`board_provision.ex:83 @default_read_actions`)。所以"读挂载不扩散"这条规则**无法从 cap 派生**,删表前需先定 tier 怎么表达。**留到 Group B 一并处理。**

### A5 收尾(A4-2 之后的下一件)
设计 v4 已获 allenwoods 批准(#1619)。实现四步:接通 `enable(:link_anon)` + provision `S_R` + 经 A4 primitive 建绑定并铸只读 cap → **匿名 feed 的 cap-gated 资源投影(主体工作量)** → 前端匿名壳渲染 → e2e(可见/隔离/fail-closed/撤销即失效)。

---

## ★ Socialware Protocol —— 终极目标的**实体形态**(新记,2026-07-31)

> **用户定位**:"socialware protocol 应该是我们最终结果之一,是 **socialware 开发指南和 gate 的一个实际上的体现**。"
> 也就是说:下面"plugin-dev gate + sw 模板"那节不是另一件事 —— **有了协议才谈得上"照着写就能装上"的开发指南,有了 conformance 才谈得上 gate**。协议是那个目标的可执行形式。

### 心智模型(Allen 定性):这是个 PROTOCOL,按 LSP / ACP 设计

| 协议要素 | 在 ezagent 里 | LSP 类比 |
|---|---|---|
| 总线 | **session** | LSP 连接 |
| 一次交互 | 一条**带 `event_type` 的 typed message** | LSP 的 method |
| 参与者 | **一个 socialware** = 定义自己的 typed 事件(`kanban:new_task`)+ 实现后端 handler + 注册前端 renderer | 语言服务器声明 capabilities + methods |
| core 的职责 | 只提供**通用协议机制**:typed-message 信封(F1)、分发路由、注册 seam(`SessionViewRegistry`=F2 + cap 鉴权)、传输端点(F3 receiver 入站 / F0 EM 出站) | LSP core 不认具体语言 |
| 关键性质 | **core 不硬编码任何 socialware 类型**;命名空间开放可版本化;客户端按类型分发 + 优雅 fallback(`registry[type] \|\| __unknown` 已在);未知类型降级不崩 | 同 LSP |

**这正是它能统一 hello / kanban / autoservice 的原因** —— 也正是 Group B「kanban 纯化成自包含」想要的那个"通用底座"的**协议表述**。

### 两个半边

**① 入站半边 —— socialware-receiver foundation(原 P-α)**
权威文档已在 main:`docs/superpowers/handoffs/2026-07-28-socialware-receiver-foundation-handoff.md`(PR **#1609**,含来龙去脉 + 上表的协议定性)。
- **F1 typed-message**:`Ezagent.Message` 加 `event_type`(开放命名空间、默认 `:chat`、向后兼容)
- **F2 event-renderer 注册**:扩 `SessionViewRegistry` + 前端 `registry[type]` 分发
- **F0 EM 投递策略**:EM 现在盲发任何 message → 改按 `event_type` 决定外部投递(默认 `:chat` 投,typed 各自声明投/skip),**与 v5/B 协调**
- **F3 receiver**:入站 `session.page_action`,坐在 F1/F2 之上
- **约束**:匿名只读、交互触发登陆、复用 `anon_takeover`;`page_action` 进确认档、**绝不给匿名**;**复用后端唯一那套 cap 机制、不自造 auth**;web 层只 dispatch、绝不碰 Kind/pid;`page_version` 乐观并发**拒**;输入只走 catalog 受控组件;file upload 走现有 cap-authed 端点
- **来龙去脉**:处理 PR **#1267**(过时的 "live-pages" 提案 doc)时挖出来的 —— #1267 已关,但其中"socialware 页面上的结构化输入"无人跟进,捞出来成 P-α,与 Allen grill 后长成这块地基

**② 出站半边 —— 应答路由 + 完成授权(#1667)**
spec:`docs/superpowers/specs/2026-07-31-socialware-answer-routing-authz.md`(branch `spec/socialware-answer-routing-authz`,commit `6bbd30800`,**过 3 轮 codex 对抗复审、逐条对 main 核过**;**暂留 branch 未合 main**,开工再合)。
- **触发它的真实缺陷**:官网应答链断 —— front-desk→concierge→llm 以 **admin 身份**补全 → `authorize_complete :unauthorized`;且 #1576 改定义后**路由规则从没重装到已存在会话**。根因 = 协议对「应答路由 + 完成授权」没有成文约定。
- **C1/C2** 声明式应答者 + **强制投递规则**:typed `answers: chat | {events:[...]}`;public 应答角色必须带一条 **enabled 的无条件 matcher**(否则消息永远到不了应答者 = 官网那个病);含糊的 `answers: true` 判 conformance error
- **C2.5** 完成角色绑定:新增 `completion: <role>|none`,有 `answers` 即必填;conformance 校验这条**声明的边**(替掉靠 recipe 名字**猜**完成角色的老逻辑 —— 那条永远不触发)
- **C3** 完成走 **composition-cap(去 admin)**:`Agent.Complete` 定成 `dispatchable?/0 == false` 的 cap-only 主体、有主 = lineage owner、boot 注册;driver 以「应答角色成员」身份补全。**C3c 激活 barrier**:binding `:pending`→CAS→`:active`;应答规则在激活前**deferred 不装**(不是装了 disable,保持 audit tri-state 诚实);cap-delivery ack sink 做优化、boot/reconcile sweep 做**保证**;不设"创建失败"超时,outbox `:dead` ⇒ `:degraded {:absorb_dead}`
- **C4** owner policy:新增 `agent_owner_policy`(默认 `inherit`);唯一被禁的是「**system policy 解析成 admin**」,admin 自己拥有的会话照走 owner fast-path;会话 `owner_policy` 不动
- **C5** config-reconcile 通道(官网"规则没重装"的结构性修法):`:repair` 只认会话自有 install 集;`:upgrade` 复用 migrate_session + `repoint_template_installs/4` + finalize-pin;normalized role-skeleton diff(skeleton = role 去掉 operates/answers/completion);公开 `retract_session_install/3` + per-ref tombstone;`add/5 opts[:enabled]`;repair 排除 `removed: true`
- **cursor(归 socialware 协议,我方写)**:`committed_seq` 是 socialware 的读模型游标 —— 叠在通用 outbox 行之上、**由 socialware 拥有**(Allen 定)
- **迁移**:seed_owned(官网/demo)破坏性重建 vs user_data reconcile;靠 **durable metadata 分类、绝不按名字猜**;老官网会话经 provisioner 授权的一次性 lifecycle adoption(`mix ezagent.socialware.adopt_lifecycle`,幂等、集合受限),in-place `:upgrade` 作 fallback

### DoD(出站半边)
- 新建任一"应答型" socialware 会话,必以「投递规则 → 应答角色 + **授权的完成边**」收尾 —— 有 fresh-session **不变量测试**守(缺完成边 → main 红;走 production-path driver seam;fixture 钉 `caller ≠ owner` + legacy-pinned)
- 官网原生 front-desk→llm 链能**自动回话**(可退掉现场加的 id=3 路由规则 + 手工 deepseek key)

### 纪律
brainstorm → spec → **codex 对抗审(碰 Cap 轴、impl 前必过)** → impl。cap-model 的最终实现细节归本人判断(owner);**不确定的协议层形状先问 Allen/cc,不自行改语义**。

### 与本 epic 其它部分的关系
- **Group A(URI-share)** 提供协议的**鉴权轴**(cap 做注册 seam 的鉴权;#1667 的 C3 明确"复用唯一那套 cap 机制、不自造 auth")
- **Group B(kanban 纯化)** 是协议的**第一个完整参与者样板**
- **下节"plugin-dev gate + sw 模板"** = 本协议成文后的**自然产物**,不是并列的另一件事

---

## 终极目标 —— plugin-dev gate + sw 模板(方向,未拆细)

| 方向 | 状态 |
|---|---|
| 把 kanban 的开发过程与约束写成 **plugin-dev gate**,批量生成其它插件 | 🔭 方向 |
| sw 同理形成**模板**(类比旧 sw simulation 库) | 🔭 方向 |
| 落点:并入 orchestrator 的 MCP,还是新做 **dev-guide domain agent** | 🔭 待定 |

---

## 合并纪律(本 epic)

- 子任务 PR **base = `epic/plugin-platform`**(不是 main),合进 epic;epic 整体再入 main。
- 已在 main 直合的早期 A 系(A2-1/A3/A4-1/config)+ 待 cc 合 main 的 A1/A2-2 = epic 的既有底座,不回退。
- 每件仍走 dev-together(return + CI 绿 + Loop B rebase + Loop C 监控)。
- 设计级/不变量敏感件(A4-2 碰 M-9、A5 碰 anon 授权、B2 碰 agent-runtime)先 design-first 过 Allen 再 impl。
