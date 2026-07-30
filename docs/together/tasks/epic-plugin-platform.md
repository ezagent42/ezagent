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
| **A4-2** `:members` roster 投影到 `grantees_of` | **#1655**(接替 #1620) | ⏳ design **v3** 待 Allen 对齐 —— **结论升级:不是等价替换**(见下) |
| **A5** 匿名分享(link_anon) | #1619 | ⏳ design **v4** 待 Allen 过 —— **撤回三条错误主张**(见下) |

**A 系剩余两件的设计已按对抗取证重写(2026-07-30/31)**,两条定论:

**① A4-2 —— 原 scope 今天不安全,不是"加个 action 过滤"就完事**
索引与 roster **两个方向都不等**:过报 5 类(`:join`-only 未加入者 / **离会残留参与档**〔离会只撤 `:receive`,`:send/:leave/:attach` 从不撤〕/ provenance 未过滤 / self-license 与 fence 只作用于 `EntityCaps.load` / `revoke_provisioning`·`tombstone` 不 reindex),漏报 2 类(**`:receive` 走 cast + delivery outbox**,冷成员刚 join 时索引里没有 / user 侧落库要求 `users` 行存在)。**更根本:源不同** —— `EntityCaps.load` 是 live-first 读活 slice,索引只从 Store 写派生,**pre-epoch 两者不相交**;而测试强制 post-epoch、dev/prod cutover 前是 pre-epoch → **CI 全绿不代表线上一致**。⇒ 建议换源排在 **#189 cutover 激活之后**;授权门只剩"target 自读 arity"一条正当路(交 Allen)。

**② A5 —— 方向不是"删 Mount";真正的阻塞也不是"渲染没有 caller"**
- **删 Mount 的依据被推翻**:#1474 是 OPEN/draft/**0 review**;与 allenwoods 2026-07-29 在 #1594 的明文批准("仅 mount 该资源")冲突;main 已合注释 `share_setting.ex:31/:83` 写 via A4 Mount;#1587:35-38 把 `mint_cap`+`Mount`/`MountRow` 列为**复用底座**。且 `mint_cap` 生产调用点只有 2 处、**都在 `mount.ex` 内部** —— "改锚 mint_cap"与"用 Mount"机制上同一件事。**官方计划是"改名 Provision/Share + 删 MountRow 表"(绑定改从 `caps_toward` 派生),不是删模块。**
- **阻塞点重新定位**:`external_render/1` **全仓零生产调用点**;匿名链路不经 view registry 且**全程有 caller**。真正缺的是**匿名 feed 里没有"外部资源投影"**(`ExternalFeed.snapshot` 只返回 messages/page/shell)+ 绑定没被渲染路消费(`MountRow.list_for_session` 零渲染消费者)。`anon_view_caps` 在匿名侧**没有 gate 会检查**,不能拿来当授权锚。
- **次序**(allenwoods #1587:72-76):先立 URI-share 原语 → **#1474 rebase 上去** → 再合;#1474 合不合是 owner 的决定。

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
