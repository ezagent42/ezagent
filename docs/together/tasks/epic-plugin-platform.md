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
| A1 分享令牌 + `/socialware/claim`(ShareSetting + 飞书 Model A) | #1594 | ✅ codex NEEDS-CHANGES(Fix1-4)修完、CI 绿、待 cc 复审+合 main |
| A2-1 `Capability.caps_toward/2` 正向可见性 | #1596 | ✅ 已合 main |
| A2-2 `grantees_of` 反向索引 | #1606 | ✅ rebase+hook 决策+LOC 修、CI 绿、待 cc 合 main |
| A3 泛化 CompositionConsent 成 URI-share 超集 | #1597 | ✅ 已合 main |
| A4-1 删 Mount reconcile 重发 trap | #1611 | ✅ 已合 main |
| config role_plugins 挪 config.exs | #1612 | ✅ 已合 main |
| **A4-2** `:members` roster 投影到 `grantees_of`(session→成员反查落地) | #1620 | ⏳ design-first 待 Allen 过设计 → impl(target: 本 epic) |
| **A5** 匿名分享(link_anon):每资源新建专属 anon session 机制 | #1619 | ⏳ design-first 待 Allen 过设计 + A1 落地 → impl(target: 本 epic) |

**A 系剩余**:A4-2(反查落地,依赖 A2-2 的 grantees_of + 需扩 action 过滤,碰 M-9)+ A5(匿名 anon session,依赖 A1 + A4 Mount)。二者已出 design-first PR,待 Allen 过设计后实现。

---

## Group B —— kanban 纯化 + sw 声明化(下一阶段)

> 目标:证明 infra(Group A + 既有 Mount/socialware 声明化)足以支撑一个业务插件**完全自包含**。

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
