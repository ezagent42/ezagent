# Handoff：URI 授权分享统一机制 —— #1552 的完整化

> **这是 #1552 的接续与完整化,不是新提案。** #1552(Sy, 2026-07-23,已 CLOSED、Allen 轨道跟踪)已提出核心——把 person-bound token 从 uploads-only **泛化到任意 target URI**、消掉 kanban 平行分享,并点明 `DownloadToken` = Allen 的 read-plane **PR-3**。**token 那一块本 handoff 不重复(直接见 #1552)**,只补它没覆盖的三块——**审批 / 可见性 / 模型裁决**,把"share token 统一"升级成完整的"URI 授权分享统一"。

- **类型**：平台 infra 设计(动 domain_session + core 授权底座) → Allen 拍板 + 排期
- **一句话**：分享 = 授予某人一个指向某 URI 的 cap,天生 URI 无关。#1552 已提了其中的"令牌"一块;这里把它补成完整五块。

---

## 0. 时机:为什么现在把它完整化

- Allen 的 **read-plane 5-PR 主线已全部 MERGED**(PR-1~5,2026-07-19~21),其中 **PR-3(#1471) 的 person-bound `DownloadToken` 底座已落地**——我们刚确认的 kanban 附件下载就跑在它上面(授权跟资源走、令牌承载 web 边界)。
- 但 **#1552 提的"PR-3 延伸:token 泛化到任意 URI"至今悬着没做**:main(`7ec3c8bda`)上 `DownloadToken` 还锁死 `uploads-only`、kanban 的 `@share_board_salt` 平行 token 还在。
- **read-plane 底座既已铺完,token 泛化是明摆着的下一步**,却一直没人推。本 handoff 把这一步补全(token=#1552 + 审批 + 可见性 + 模型),凑成一份完整提案,建议直接排进 read-plane 的收尾。

---

## 1. 现象和需求

**具体现象(以 kanban 打样)**:用户想把一块看板分享给同事——生成**只读链接**和**读写链接**,谁拿到谁获得对应权限,只读的能**申请**升级、由板主**批准**。这套东西 kanban 现在是自己从头搭的:自签令牌(`Phoenix.Token`)、自开 web controller、自搭"申请-批准"气泡。

**通用需求(重点)**:这件事**跟"看板"无关**。主语换成任何有 URI 的东西——

> 把 **X** 分享给某人,给读/写权限,只读的能申请升级。X = 一块看板 / 一个 agent / 一个 resource / 一份数据资产。

参照飞书:文档/多维表格/看板分享逻辑完全一样,因为对它们都只是"一个可授权的对象"。

---

## 2. 原因:为什么现在每个都得自己造

**分享的本质 = 授予一个指向某 URI 的 cap**(`mint_cap(grantee, target_uri, ...)` 里 target 是任意 URI,跟 kind 无关)。但系统只有最底层的"铸钥匙"通用了,**"分享这件事"的完整编排没沉淀成通用件**,于是 kanban 在铸钥匙外面自己包了一整层;下一个想被分享的数据资产会照抄一遍。**#1552 已经诊断了其中的一半(两套平行 token);本 handoff 把另一半(审批/可见性/模型)也摊开。**

---

## 3. 系统现有的支撑

授权底座本身是对的、且大多 URI 无关,已能拼一部分:

| 现成积木 | 是什么 | 状态 |
|---|---|---|
| **铸钥匙** | `CompositionCaps.mint_cap/4` —— 通用发钥匙,target/行为/动作参数化,fail-closed | 现成,kanban 已用 |
| **令牌底座** | `Ezagent.Uploads.DownloadToken`(read-plane **PR-3 #1471**) —— person-bound + URI 绑定 + 短 TTL + mint-behind-chokepoint | **已落地,但锁死 uploads**(泛化=#1552) |
| **申请-批准原语** | `CompositionConsent` —— 两方同意状态机 + **owner 待办箱** `pending_for_owner`。schema 层 URI 无关 | 现成,但入口绑 composition(见 §4) |

**关键**:kanban 自搭的"申请-批准气泡"是把 `CompositionConsent` 重复造了一遍——你担心的"申请了板主看不到",`pending_for_owner` 待办箱本就解决。

---

## 4. 现有支撑解决不了什么(缺口)

现成件覆盖了"铸钥匙"和"审批状态机",串成一次完整分享还差四样:

1. **令牌:泛化到任意 URI** —— **= #1552,不在此重复**。现状 `DownloadToken` 锁死 uploads、kanban 另签 `Phoenix.Token`。#1552 已列 5 个待裁设计问题(scheme 开到哪、board-share 授权口径、`kanban.share_board` 归宿、person-binding 语义、消息 share 是否纳入)。
2. **可见性派生(本 handoff 补)** —— "拿到 cap 后在自己空间看到这个资源",workspace/session/kanban **三处各写一遍**"把自己的 cap 捞出来手工过滤"(`union_cap_boards` 硬编码只认看板)。缺一个通用"从某人的 cap → 派生指向某类资源的可见实例"。
3. **审批入口泛化(本 handoff 补)** —— `CompositionConsent` 的状态机 URI 无关,但**创建/命令入口绑死 composition**(`sync(%CompositionBinding{})`、`command(binding_id, session_uri, ...)`,调用方全是 composition_caps)。要给"任意 URI 分享升级"用,得把入口泛化成"任意 (被授权人, 目标URI, 动作)"。kanban 规则 8 现在是绕过它、自己搭的重复轮子。
4. **通用接收落点(本 handoff 补)** —— kanban 是孤立写死的 controller。缺一个"验令牌 → 交给注册的处理器 → 授权"的通用 `/socialware/claim`。

**外加一个必须先裁的分叉(本 handoff 补)**:系统里已有**两套分享哲学**——socialware feed 的"入会 + 实时判权"(令牌只是入场票) vs kanban 的"令牌即凭证、兑换即铸 cap"。**通用机制该统一走哪套,得先裁。**

---

## 5. 我们 propose 什么

**一个通用的"URI 授权分享"机制,授权层统一(URI 无关)、使用层各 plugin 管自己怎么渲染。**

- **授权层**(签令牌 → 铸 cap → 申请升级 → 从 cap 派生可见):对所有 URI 一视同仁,infra 负责;
- **使用层**(拿到权限后这个 URI 怎么 render):按 kind,plugin 声明。

**模型裁决建议**:统一走 **person-cap 那套**(链接=授权凭证、兑换即铸 cap)——它本来就是"对 URI 授权"本身;feed 那套是 session 的"参与"语义,留给 session。

---

## 6. 怎么改(五块,标注归属)

```
[② 分享令牌(带目标URI)] → [⑤ 通用接收落点] → [① 铸 cap(mint_cap,任意目标)]
          ↓                                          ↓
[③ 从 cap 派生"能看到啥"]              [④ 申请→owner 批准→升级(任意目标)]
```

| # | 改什么 | 归属 |
|---|---|---|
| ① 铸 cap | 直接用 `mint_cap` | **现成,不动** |
| ② 分享令牌泛化 | 以 `DownloadToken`(PR-3)为底,加"不记名 bearer 可兑换"轴,取代 kanban 平行 token | **= #1552(已提,直接接续)** |
| ③ 可见性派生 | 通用 `caps_toward(holder, behavior)`,收掉三处重复 | **本 handoff 补** |
| ④ 审批入口泛化 | 把 `CompositionConsent` 创建/命令入口脱离 composition + session,接受任意 target;状态机+待办箱不用重写 | **本 handoff 补** |
| ⑤ 接收落点 | 通用 `/socialware/claim`(验令牌→注册处理器→授权) | **本 handoff 补** |

**收益**:read-plane 底座 + #1552 的 token 泛化 + 这三块,合起来 = 一套完整的 URI 授权分享。下一个想被分享的数据资产零 per-kind 代码;kanban 自己那套令牌/controller/审批气泡全删、收编进底座。

---

## DoD(本 handoff 的完成 = 拿到方向)

- [ ] **模型裁决**:通用 URI 分享统一走 person-cap 模型?(feed 留 session 参与语义)
- [ ] **#1552 的 5 个 token 设计问题** + 本 handoff 的 ③④⑤,是并进 read-plane 收尾(#1552 说的"PR-3 延伸")一起做,还是拆?
- [ ] 落地后,kanban(PR #1474 保留的 person-cap 现状)作为第一个消费者收编

> 溯源:#1552(Sy, 2026-07-23)提 token 泛化;本 handoff(2026-07-27)出自 kanban 示范重构 PR #1474 的三轮讨论 + 两次代码查实,补上审批/可见性/模型,完整化成"URI 授权分享统一"。read-plane 主线(PR-1~5)已 MERGED,token 泛化至今悬着 —— 建议一并推进。

---

## 7. 设计定案(2026-07-27,与 Allen 对齐后 —— 权威,取代上文分歧处)

以下决策已与 Allen 逐条对齐(甲/乙 + 4 处纠正 + Mount + 反向索引),作为实现依据。

### 7.1 Mount 表:删对了,不恢复;缺口用「派生反向索引」补(Allen 确认)

**实证**(main):`socialware_mounts` 表除 mount.ex 内部 upsert 去重外,外部只被两处读——session 启动 `reconcile_session_mounts`、入会 `backfill_member_mounts`,**全是"照表重新 mint 钥匙"**。无任何读点做授权/可见性/feed(feed 列成员读 `:session` 的 `:members` slice,不碰 Mount)。

**结论**:Mount 的"账本身份"(照表重发)= 第二真理源 trap,#1474 删对(合甲 cap-as-truth)。它唯一 cap 给不了的是 `session_uri` 维度(cap 形状 `(holder,target,actions)` 无上下文轴)。**不恢复 Mount**;这个反向缺口用**从 cap 投影出的派生只读索引**补(cap→行,永不反过来重发钥匙)。

### 7.2 反向索引 `grantees_of`(新增第 5 件,Allen 拍板现在做)

**需求**:统一的"某资源的 cap 发给了谁"反查,避免每个 biz 各造(`:members` 今天就是这个,但在 biz 层手做)。

**实现(低-中难度,靠现成收口)**:
- **单一存储收口已存在** = `Ezagent.Identity.absorb_cap/2` —— 所有 cap 落地(含 member-cap:`grant_at_join`→`issue_and_absorb_cap`→`Cap.issue`→`absorb_cap`)都过它,无活的绕过口(`workspace_user_admin` 那处历史绕过已修、现走 `Cap.issue`)。
- **写**:在 `absorb_cap` 顺手写一行反向表 `(target_uri, grantee_uri, behavior, actions, key_id/generation, granted_by)`(≈ MountRow schema 去掉 reconcile/session-scope 包袱)。
- **读**:`grantees_of(target_uri, behavior \\ :any)`,**按目标当前 generation 过滤**(撤销=generation-bump 不删行,旧行自动失效,镜像 `verify_against_current`,不引入新撤销机制)。
- **`:members` 迁移分两步**(碰 M-9 授权不变量,授权敏感):先出索引+接口、验证与现有 `:members` 逐条一致 → 再迁 `:members` 成投影。
- **drift gate**:禁 biz 层再各自实现反向查询(仿 `attachment_plane_chokepoint`)。

### 7.3 两个设计题(Allen 留给我定)的决定

- **令牌 bearer vs grantee-bound → 分层,两个都要**:分享**链接** = bearer(不知谁点、谁拿到谁兑);claim 那刻 mint 出的 **cap** = grantee-bound(person-cap,甲)。即泛化 `DownloadToken` 加一个"grantee 在 claim/verify 时才填"的 bearer 模式(= 甲的 bearer→mint)。
- **4 处可见性统一 → `caps_toward` 做共享过滤器**:各处枚举源不同(list_by_recipe / 全 ws / agent)属 use-layer 各管;真正重复的是"∩ 我持有指向它的 cap"过滤 + 3 条 caps-loading。`caps_toward(holder, behavior)`(正向)做这个共享 filter,每处保留自己的枚举、只把 cap 过滤路由进来。

### 7.4 乙(访问=持 cap,不自动建展示 session)→ 非回归守卫

Allen 核实:"创建资源/agent 自动建 owner 展示 session"在现 main **不成立**(独立 session Kind 已删、`create_session` 独立 action、建 agent 只写潜伏 cap-gated 蓝图)。所以乙 = 非回归守卫 + 关两个**真**残留:`KanbanRender.boards_for/1`(`kanban_render.ex:113`,无 caller/cap 过滤的 render 路)+ `:members` roster(确认是 cap 派生投影 —— 正好由 §7.2 的 `grantees_of` 收编)。

### 7.5 命名(与 Allen 对齐,2026-07-27)

`target` = cap 指向的 URI 的**既定通用词**(`cap.ex` 通篇、`mint_cap`/`consent` 的 `target_uri`)——**不是 `resource`**(target 可为 agent/session/resource 任意 URI)。避开 `Delegation`(与 #153/#137 "delegation policy"/`:grant_not_delegable` 撞车)。

- **`Ezagent.Socialware.Share`** —— URI 无关的"授/分享/撤/查 指向 target 的 cap"(mint、bearer token→claim、caps_toward、grantees_of、consent、revoke)。
- **`Ezagent.Socialware.Provision`** —— 建数据宿主 + 发 owner cap(= board_provision 泛化,现 `Mount.provision`),接口按 target/spec 参数化。
- **分层**:`Share`+`Provision` 复合体住 socialware(domain_session,唯一能同碰 `create_agent` + `mint_cap` 的层);纯 cap 索引 `caps_toward`/`grantees_of` 下沉 cap/identity(挂 `EntityCaps`/`absorb_cap`)= Allen 说的 "cap/identity layer"。

### 7.6 board_provision = 泛化,不是删(选 a)

**xy 实证**:`Mount.provision` moduledoc 自述"这是 `BoardProvision.create_board/5` 的泛化,零 kanban 字面,所有 socialware 复用"——**通用原语早已存在 = `Mount`**。#1474 为 kanban 纯化把它删了、让 kanban 重造薄 board_provision,对"通用 infra"目标是倒退。选 a 的正解 = **重构 Mount → `Provision`/`Share`(改名 + 去 MountRow trap),非删**:保留 provision + mint 边;删 MountRow 账本/reconcile(第二真理源 trap)→ 由 `grantees_of` 派生索引替。kanban board_provision 退成薄壳(甚至无,直调通用原语)。

### 7.7 最终 PR 拆分(两组严格先后:infra 全合 → kanban 统一迁,防 drift)

**Group A —— 纯 infra(无 kanban 文件,全部先合):**
```
A1  分享令牌 + claim 落点      Socialware.Share 的 bearer token 轴(泛化 DownloadToken,claim 绑 grantee)
                              + 通用 /socialware/claim(= #1552 token 泛化 + 通用接收)。additive
A2  可见性 + 反向索引          cap/identity 层 caps_toward(正向)+ grantees_of(挂 absorb_cap + generation
                              过滤 + 反向表)。additive
A3  审批泛化                  CompositionConsent 入口泛化到 (grantee, target_uri, actions)。additive
A4  Mount → 通用原语(重构非删) 重构 Mount 成 Socialware.Provision/Share:保留 provision+mint,去 MountRow
                              trap;迁 member_backfill/reconcile 脱 Mount;:members 投影到 grantees_of  [依赖 A2]
config PR  部署 config        role_plugins / socialware_check_reference_apps 挪 config.exs(独立,决定 2)
```
**Group B —— kanban #1474 slim + rebase(A 全合后统一改):** 只留纯 kanban 业务;authz 指向 A 的新 seam(share→A1、rule-8→A3、union_cap_boards→A2、board_provision→A4 薄壳)。
**最后 —— drift gate:** 禁 biz 外造 token签/mint/holder查/审批(kanban 也迁完才能过)。

依赖:A1/A2/A3 可并行 → A4(等 A2 的 grantees_of)→ config 独立 → Group A 全 merge → #1474 → drift gate。**每个 PR 走 dev-together:测试 + 需 e2e 者截图 + full suite CI 绿 + 提交后监控 CI。**

> **本节所有决策已与 Allen 对齐并 ok。** 实现从 A1 起。
