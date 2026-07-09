# 场景 42：seller —— 改造 fork、发布回货架（飞轮闭合）

**类别**：6 — Socialware / 模板（customize → publish → reflow）
**状态**：🚧 设计 spec —— 现在可对 `docs/website-demo/flywheel/` 录制点击 mock；真站层待建（发布到官网入口 + 跨用户发现）。非 ✅。
**作者**：Claude（与 ruihua），2026-07-09 —— homesite 飞轮 seller arc S4–S5，**闭合**（`docs/rh/homesite/product/2-旅程.md` J-S5）。两条死 funnel 在这里成飞轮。

> 双语对照：[`scenario.md`](./scenario.md)。

## 意图

接场景 41：**seller** 在 world+hello 把 fork 出来的 session 改成自己的产品，然后**发布回货架**。seller 的产品此刻成了*下一个* seller 的落地点 —— 需求腿的产出以供给身份回流。这个闭合（`S5 → 新 B5`）是整条飞轮的承重命题（`model.md §0`）。

## 前置

- 接场景 41（seller 已有一个 fork 出来、自己 owner 的 session）。
- 录制目标：`docs/website-demo/flywheel/`（`world-step.html?mode=fork` → `publish-landing.html` → `gallery.html`）。
- 发布 CR `ConfigGovernance.Socialware` 已落地；归属需 **owner 字段（W-G5）**。

## 角色

- **seller（owner）**：真用户，fork 出来的 session 的 owner。
- **界面**：world+hello 改造（MOCK：`world-step.html?mode=fork`）→ 发布落地页（`publish-landing.html`）→ 货架（`gallery.html`）。

## 步骤

1. **改造** —— 在 world+hello 把 fork 调成 seller 的业务（demo：给李复制的代运营客户做 招人分诊 + 到店接待 + 预约日历）。
2. **发布回去** —— 点 `发布进 gallery · Publish` → **[W-G2]** 发布 CR 开/暂存/发布 seller 的 Definition；**[W-G5]** 署名为 seller（`owner`）。
3. **确认** —— `publish-landing.html`：「你的产品已上架」；卡滑入。
4. **回流可见** —— 回 `gallery.html`；seller 的变体成了一张 live 卡，**和源产品并列** —— 它现在是下一个 seller 的落地点（= 新的 B5 / 新的场景 41 的 S0）。

## 预期

- 第 2 步：一个**新**已发布 Definition（不同 `name`/`version`），seller 是 `owner`，可选记 `forkedFrom` 溯源。
- 第 4 步：`gallery.html`（经目录 API **W-G1**）同时列出源产品与 seller 的 fork —— 飞轮闭合是**演出来的**、不是断言的（seed ∪ published）。
- 后续 seller 能落到 seller 的产品并 fork *它*（递归 —— 飞轮真转起来）。

## 要测的失败模式

- **回流没闭合** —— seller 发布的产品对下一个 seller 不可发现（目录 **W-G1** 缺口）→ 只是「存了个模板」，不是转起来的飞轮。
- **无归属** —— 发布时没 `owner`（**W-G5**）→ 无法署名 seller；溯源/`forkedFrom` 丢失。
- **自助 vs 审核未定** —— 若发布是 admin-gated（registry O-4），seller 无法自助发布 → 需求→供给的回流卡在人工门。

## 交叉引用

- demo：`docs/website-demo/flywheel/{world-step,publish-landing,gallery}.html`。
- handoff：`docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md`（W-G1/W-G2/W-G5）。
- spec：registry P0（版本标识）/ O-4（自助 vs 审核）；manifest O-1（owner）。
- 设计：`docs/rh/homesite/model.md §0`（闭合 = 承重命题）。

## 备注

- 闭合 `S5 == 新 B5` 用的是与场景 40（builder B5）**同一个**发布面 —— 供给腿和需求腿共用发布/货架面。做一次即可。
- 状态 🚧，直到 live 测试 + runbook + 截图 + 签收齐全。
