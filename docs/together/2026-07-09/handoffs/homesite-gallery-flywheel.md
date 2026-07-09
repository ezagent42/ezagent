# 官网飞轮 gallery —— 任务拆分 handoff

2026-07-09 · ruihua。飞轮设计见 [`docs/rh/homesite/`](../../../rh/homesite/README.md)（README/model/product/gaps）。**可点击 demo（本 handoff 的前端 spec）= `docs/website-demo/flywheel/`**，对应新 scenario 40–42。缺口后端大部分已落地，缺的是 gallery 目录 UI + 几个触发点，未实现的面在 demo 里用 mock + 标注占位。

## 主流程（两条路线，经 gallery 闭合）

**🟦 builder 供给**：
1. 在 world + hello 造一个 socialware 产品
2. **发布进官网 gallery**：填标题/简介 + 传封面图 → 提交（publish CR）→ **过合规审核** → 上架
3. 产品作为一张卡出现在货架，可被试用、被 fork

**🟨 seller 需求**：
1. 从外部落进官网某产品页（demo 里 = `recruit-v2` 专家招募产品）
2. 试用它（匿名 `public_view`，已落地）
3. 进 world，**fork 这个 session**（`session.fork_config`，已落地）→ 成 owner
4. 用 world + hello 改成自己的产品
5. **发布回 gallery**（同样：填表单 + 传图 + 过审核）→ 自己的产物 = 下一个 seller 的落地点（回流，飞轮闭合）

## demo 怎么看（含图片标注）

- **走查入口**：起本地服务后开 `docs/website-demo/flywheel/gallery.html`（货架 = 飞轮中心）。两条路线各点到底见 `docs/rh/homesite/` 的验证清单。
- **图片标注**：任一 demo 页加 `?annotate=1`，会在需研发补的元素上打**红框 + W-G 任务号 + 「在此加」**。关键几张：
  - `flywheel/world-step.html?mode=fork&annotate=1` —— W-G3（fork 触发）· W-G2（发布）
  - `flywheel/world-step.html?mode=build&annotate=1` —— W-G2（发布）
  - `flywheel/product-detail.html?annotate=1` —— W-G3（Fork CTA）· W-G4（version）· W-G5（owner）
- 一屏汇总板（可截图进 handoff）：`docs/together/2026-07-09/handoffs/visuals/callout-board.html`。

## W —— world / hello 后端（被依赖）

| # | 任务 | 被依赖 | 现状 / spec |
|---|---|---|---|
| **W-G1** | 面向官网的 **gallery 目录 API**：把 `DefinitionRegistry.list/1` + `lookup/2` 暴露成公开 browse / search / detail 端点（今天只有 `world_live.ex:704` 的薄 install 下拉） | H-G1 / H-G2 / H-G5 | registry spec **P1**（catalog UI/API）· 待建 |
| **W-G2** | **发布到官网**：官网可达的**发布入口 + 发布表单**（填标题 / 简介、上传封面图 / 截图），提交后开 socialware publish CR（`open_cr → stage_definition → publish_cr`） | H-G4 | CR 已落地、入口 + 表单待建 |
| **W-G3** | **从官网产品页 fork**：用 `?fork=<name>` 触发已落地的 `session_fork_action`（Conversation.tsx:713 → config_fork.ex），让 owner=触发者 | H-G3 | fork 本体 ✅，缺「从货架产品一键触发」 |
| **W-G4** | **版本标识**：pin 到具体 version + 下架 / retract（安装现在总取 current） | H-G2 version 展示 | registry **P0**，部分已落地（迁移 `20260704000000_add_content_hash…`） |
| **W-G5** | 给 `Definition` 加 **`owner` / 作者字段**（现在没有）—— 货架卡署名、S5 回流归属都要它 | H-G1 卡署名 | manifest **O-1** / registry O-2 · 待加 |
| **W-G6** | **合规审核流程**：提交发布的产品先过**审核**（防不合规内容上官网），审核通过后才上架 gallery；定 **自助 vs 管理员审核** 策略 | H-G4 | registry **O-4** · 策略 + 审核系统待建 |

沿用旧 handoff（`docs/scenarios/homesite-handoff.md`）W1–W4（fork/深链/红点/分享）仍覆盖 S1' 与试用侧。

## H —— 官网前端（demo 即 spec）

| # | 任务 | 依赖 | demo 文件 |
|---|---|---|---|
| **H-G1** | gallery 货架页（瀑布卡 + 搜索 + 品类筛选） | W-G1 | `flywheel/gallery.html` |
| **H-G2** | 产品详情（manifest 字段 + 试用 + Fork） | W-G1 / W-G4 | `flywheel/product-detail.html` |
| **H-G3** | Fork CTA → 深链进 world fork | W-G3 | product-detail 的 Fork 按钮 |
| **H-G4** | 发布确认落地页 → 卡片滑进货架 | W-G2 | `flywheel/publish-landing.html` |
| **H-G5** | S0 落地 = 从 gallery / 外部深链进产品页 | W-G1 | gallery → product-detail 链路 |
| **H-G6** | 官网 `index.html` 加一个 gallery / cases 导航 tab | W-G1 | （demo 里 gallery 独立页并链回官网；生产做进 index） |

## 依赖关系

- gallery 浏览/详情（H-G1/H-G2/H-G5）← 目录 API（**W-G1**）
- Fork CTA（H-G3）← 从产品页触发 fork（**W-G3**，本体已 ✅）
- 发布落地（H-G4）← 发布入口 + 表单/传图（**W-G2**）→ 合规审核（**W-G6**）→ 上架
- 卡署名 + 回流归属 ← `owner` 字段（**W-G5**）
- version 展示（H-G2）← 版本标识（**W-G4**）
- **承重**：整条飞轮的 P0 = gallery 这层界面（W-G1 + H-G1）；fork（W-G3）已就位，别重造。

## 对应 scenario
- **40** builder-build-publish：造 socialware → 发布 → 上货架（B2→B5）
- **41** seller-gallery-land-fork：落货架产品 → 试用 → 进 world → fork（S0→S3，接旧 36/39）
- **42** seller-reflow-publish：改造 fork → 发布回货架 → 成下一个 S0（S4→S5 闭合）

## 引用（不重新设计）
- `docs/superpowers/specs/2026-07-03-socialware-manifest-design.md`（manifest 字段 §2；name-ref resolver；ConfigGovernance.Socialware publish）
- `docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md`（P0 版本标识 / P1 目录 UI / O-1 owner / O-4 自助 vs 审核 —— **落地状态以此为准，先对齐再排期**）
- 格式仿 `docs/scenarios/homesite-handoff.md`
