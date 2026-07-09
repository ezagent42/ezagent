# 官网飞轮 gallery —— 给 lead 的 handoff（想要的效果 + 需研发加的功能）

2026-07-09 · ruihua。让 lead 一眼看清「想实现什么效果」+「需要研发加哪些功能」，便于直接派成任务。技术细节见同目录 `homesite-gallery-flywheel.md`（给研发，W-G1..W-G6 + 依赖）；可点击 demo 见 `docs/website-demo/flywheel/gallery.html`。

## 想要实现的效果（一句话）

让官网成为一个转得起来的**飞轮**：**builder 用 world+hello 造出 socialware 产品 → 发布到官网「探索」→ seller 从外部落进来试用 → fork 成自己的 → 改完再发布回来**。seller 的产物成了下一个 seller 的落地点，越转货越多、越有网络效应。（这是"让官网飞轮转起来"这个目标的落地形态。）

## 现状（好消息：后端大半已就位）

飞轮的后端大部分已落地：socialware = 可 fork 的 `public_view` Definition、`DefinitionRegistry.list`（发现）、发布 CR、**fork 本体 `session_fork_action` 已 ✅**。**唯一硬阻断 = 官网还没有一个「探索 / 货架」界面**（浏览发现 + 从产品页 fork + 发布入口）。

## 需要研发加的功能（可直接派）

| 功能 | 干什么 | 大致归属 | 备注 |
|---|---|---|---|
| **探索 / 货架页 + 目录 API**（W-G1） | 把已发布 socialware 列成可浏览 / 搜索的官网页 | 前端 + world 后端 | **P0**，飞轮启动点；后端 `list` API 已有雏形（`world_live.ex:704`），缺公开 browse UI/API |
| **从产品页一键 fork**（W-G3） | 点「Fork」→ 进 world 复制配置、建新 session、点的人成 owner | world | **fork 本体已 ✅**，只缺"从货架产品触发它"的入口 |
| **发布入口 + 表单**（W-G2） | 填标题 / 简介、传封面图，提交发布 | world / hello | publish CR 已有，缺入口 + 表单 |
| **合规审核流程**（W-G6） | 发布的产品先过审核再上架（防不合规内容上官网） | world + 决策 | 需 lead 定策略 |
| **Definition 加 `owner` 字段**（W-G5） | 卡片署名、回流归属 | world | 现在没有这个字段 |
| **版本标识**（W-G4） | pin 到某版本 / 下架 | world | 部分已落地（content-hash 迁移） |

## 需要 lead 决策

1. **发布走自助还是审核**？现在 public 发布是 admin-gated；飞轮要转得顺需要更自助，但又要防不合规内容 →（我的建议：**自助填表 + 轻量审核门**，即 W-G2 + W-G6 组合）。
2. **要不要现在就排「探索 / 货架」页**？—— 这是唯一 P0，其余原语都已就位，性价比最高。
3. 已有两份设计 spec 覆盖了 marketplace 的 P0/P1（`docs/superpowers/specs/2026-07-03-socialware-manifest-design.md`、`2026-07-04-socialware-registry-and-distribution-plan.md`）—— **派任务前先让研发对齐这两份的落地状态，不要重新设计**。

## 参考

- **可点击 demo**：`docs/website-demo/flywheel/gallery.html`（探索 → 详情 → world 占位页 → 发布 → 回探索，两条路线闭环；本地起服务即可走）。每个页面底部有「world / 后端需要加的功能」框，直接对到上面的 W-G 任务。
- **给研发的 handoff**（W-G1..W-G6 + H 表 + 依赖 + scenario 映射）：`docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md`
- **E2E scenarios**：`docs/scenarios/{40-builder-build-publish,41-seller-gallery-land-fork,42-seller-reflow-publish}`
- **设计梳理**：`docs/rh/homesite/`（README / model / product / gaps）
