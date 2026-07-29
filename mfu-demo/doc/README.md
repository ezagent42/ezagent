# MFU 文档入口

本目录只在根层保留持续更新的 living docs；带版本号的策划案、审计、信息图和其他版本快照放入对应版本目录。

## 先读什么

如果要快速理解当前 MFU，建议按以下顺序阅读：

1. [`platform-concept-model.md`](platform-concept-model.md)：平台有哪些概念，以及它们之间是什么关系；
2. [`core-gameplay-card-array.md`](core-gameplay-card-array.md)：玩家反复进行的核心玩法；
3. [`student-opc-lifecycle-roadmap.md`](student-opc-lifecycle-roadmap.md)：学生 / OPC 的完整生命周期与产品演进路线；
4. [`skill-tree.md`](skill-tree.md)：个人、公司和角色成长树的规则与历史迁移。

## Living docs

| 文档 | 单一事实源范围 | 什么时候修改 |
|---|---|---|
| [`platform-concept-model.md`](platform-concept-model.md) | 经验、能力、信誉、认证、资质、会籍、功能、角色与订单关系 | 平台概念或概念边界变化时 |
| [`core-gameplay-card-array.md`](core-gameplay-card-array.md) | 卡牌、阵列、被动连接、主动连接与反复游戏循环 | 核心玩法变化时 |
| [`student-opc-lifecycle-roadmap.md`](student-opc-lifecycle-roadmap.md) | 学生 / OPC 生命周期、角色分支与产品演进顺序 | 用户阶段或产品演进顺序变化时 |
| [`skill-tree.md`](skill-tree.md) | 个人、公司和角色成长树 | 成长树规则或节点变化时 |

修改某项设计时，先更新对应 living doc，再更新新的版本快照和 Demo。旧版 GDD、信息图、审计和实施记录不回写新设计。

## 版本快照

### v0.13

- [`v0.13/MFU-策划案-GDD-v0.13.md`](v0.13/MFU-策划案-GDD-v0.13.md)
- [`v0.13/happy-paths-v0.13.md`](v0.13/happy-paths-v0.13.md)
- [`v0.13/flywheel-audit-v0.13.md`](v0.13/flywheel-audit-v0.13.md)
- [`v0.13/gap-analysis-v0.13.md`](v0.13/gap-analysis-v0.13.md)

### v0.14

- [`v0.14/MFU-策划案-GDD-v0.14.md`](v0.14/MFU-策划案-GDD-v0.14.md)

### v0.15

- [`v0.15/MFU-策划案-GDD-v0.15.md`](v0.15/MFU-策划案-GDD-v0.15.md)
- [`v0.15/infographics/MFU-v0.15-机制信息图.html`](v0.15/infographics/MFU-v0.15-机制信息图.html)
- [`v0.15/infographics/MFU-v0.15-机制信息图-细节页归档.html`](v0.15/infographics/MFU-v0.15-机制信息图-细节页归档.html)

`v0.15/infographics/assets/` 保存信息图使用的局部截图，`capture-v015-crops.js` 用于从对应 Demo 重新生成这些截图。

## 其他工作记录

- `docs/superpowers/specs/`：经过确认的设计说明；
- `docs/superpowers/plans/`：具体版本的实施计划；
- `docs/together/<日期>/`：当日协作、交接和 return。

这些记录保留当时的文件路径和上下文，因此旧记录中的路径可能是历史路径；查找当前文档时以本页为准。
