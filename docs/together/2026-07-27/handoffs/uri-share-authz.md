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
