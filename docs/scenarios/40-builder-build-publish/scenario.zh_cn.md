# 场景 40：builder —— 造一个 socialware，发布到官网货架

**类别**：6 — Socialware / 模板（author → publish → discover）
**状态**：🚧 设计 spec —— 现在可对 `docs/website-demo/flywheel/`（gallery/world-step/publish-landing）录制点击 mock；真站层待建（货架目录 UI + 发布入口未做）。非 ✅（无不变式测试、无签收）。
**作者**：Claude（与 ruihua），2026-07-09 —— 出自 homesite 飞轮 builder arc（`docs/rh/homesite/product/2-旅程.md` J-B）。取代 `product/2` 的 J-index 预留。

> 双语对照：[`scenario.md`](./scenario.md)。

## 意图

一个 **builder**（技术创作者，tool-first）在 world+hello 造出一个 socialware 产品，然后**发布到官网货架**，变成一张可发现、可试用、可 fork 的卡。这是供给腿的兑现（B4→B5），也喂飞轮：这个已发布产品就是 seller 在场景 41 落地的那个。

## 前置

- 近期录制目标：从仓库根起服务的 `docs/website-demo/flywheel/`。
- builder 是已登录用户，持 `:create_session` / 模板作者 caps。
- 后端已落地（引用、不重造）：socialware = config-only `Ezagent.Socialware.Definition`；发布 CR `ConfigGovernance.Socialware`（`open_cr → stage_definition → publish_cr`，public scope admin-gated）；发现 `DefinitionRegistry.list/1` + `lookup/2`。

## 角色

- **builder**：`entity://system/user/<builder>` —— 真用户、模板作者。
- **界面**：world+hello 构建工作台（demo 里 MOCK = `world-step.html?mode=build`）；官网**货架**（`flywheel/gallery.html`）+ **发布落地页**（`flywheel/publish-landing.html`）。

## 步骤

1. **进构建工作台** —— 货架点 `发布你的产品 · Publish yours` → world+hello 构建面（demo：`world-step.html?mode=build`）。
2. **描述 → 生成（hello）** —— 一句话 prompt → hello 生成一个 `public_view` 产品面（demo：mock 的 hello 面板 + 成员 chip）。
3. **发布** —— 点 `发布进 gallery · Publish` → **[W-G2]** 打开/暂存/发布 socialware CR，让官网目录能看到它。
4. **确认** —— 落 `publish-landing.html`；新产品卡动画滑进 mini 货架。
5. **出现在货架** —— 回 `gallery.html`；builder 的产品成了一张 live 卡（标题/作者/版本/`public_view` 徽标）。

## 预期

- 第 3 步后，Definition 发布进 registry（public scope），带稳定 `name` + `version` + **`owner`**（**[W-G5]** owner 字段）。
- 第 5 步：`gallery.html` 通过目录 API 列出新产品（**[W-G1]**）；卡显示 `public_view · live` 与正确的作者 + 版本（**[W-G4]**）。
- seller（场景 41）现在能落到这个产品。

## 要测的失败模式

- **发布静默失败** —— CR 没开/没发；产品从未进目录。「失败了谁会知道？」→ 必须报错，不许静默丢。
- **无 owner** —— 已发布 Definition 无作者 → 货架卡无法署名、S5 回流无法归属（**W-G5** 缺口）。
- **不可发现** —— 发布了但目录 API（**W-G1**）不列出它 → 它只是个 install 下拉行，不是可浏览产品。

## 交叉引用

- demo：`docs/website-demo/flywheel/{gallery,world-step,publish-landing}.html`。
- handoff：`docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md`（W-G1/W-G2/W-G4/W-G5）。
- spec（不重设计）：`docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md`（P0 版本标识、P1 目录）、`2026-07-03-socialware-manifest-design.md`（manifest §2）。
- 设计：`docs/rh/homesite/`（飞轮 builder arc B4/B5）。

## 备注

- **状态刻意 🚧**。货架目录 UI + 官网可达的发布入口是「有意但未建」；demo 用 mock 面录。不到「确定性/live 测试 + runbook + agent-browser 截图 + 签收」齐全，不标 ✅。
