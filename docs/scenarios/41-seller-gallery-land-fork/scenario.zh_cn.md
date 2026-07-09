# 场景 41：seller —— 落地货架产品、试用、进 world、fork 它

**类别**：6 — Socialware / 模板（discover → try → fork）
**状态**：🚧 设计 spec —— 现在可对 `docs/website-demo/flywheel/` 录制点击 mock；真站层待建（货架落地 + 从产品页触发 fork 未接）。非 ✅。
**作者**：Claude（与 ruihua），2026-07-09 —— homesite 飞轮 seller arc S0–S3（`docs/rh/homesite/product/2-旅程.md` J-S）。在场景 36（匿名浏览）、39（config-fork）之上补它们没覆盖的**货架落地点**。

> 双语对照：[`scenario.md`](./scenario.md)。

## 意图

一个 **seller**（价值优先业主，如 agency 李复制）从外部进来，落在一个**货架产品**（demo：`expert-recruit` 招募 socialware），匿名试用，然后进 world 把这个 session **fork** 成自己当 owner 的副本。这是需求腿的入口（S0→S3）；fork 本体（`session.fork_config`）已落地 —— 缺口是货架落地 + 从产品页触发 fork。

## 前置

- 录制目标：从仓库根起服务的 `docs/website-demo/flywheel/`。
- seller 起始匿名（干净浏览器）；在 fork 那步登录。
- 已落地（引用）：`public_view` + `AnonUser` 匿名生命周期（场景 35）；**`session_fork_action`** 用户可点的 fork（Conversation.tsx:713 → `config_fork.ex`），受 `:create_session` 门控、caller 成 owner（场景 39）。

## 角色

- **seller（匿名 → 登录）**：`entity://system/user/anon-<rand>` → fork 时变真用户。
- **界面**：货架（`gallery.html`）→ 产品详情（`product-detail.html`）→ 产品的 `public_view` 面（demo：`../recruit-v2.html`）→ world（MOCK：`world-step.html?mode=fork`）。

## 步骤

1. **从外部落地** —— 深链（Instagram 等）进货架 / 某产品详情（`product-detail.html?sw=expert-recruit`）。**[W-G1]** 详情由目录 API 提供。
2. **试用** —— 点 `试用 · Try` → 产品的 `public_view` 面（demo：`recruit-v2.html`）；匿名体验价值（抽卡 → prompt 打分 → 专家市场）。
3. **决定占为己有** —— 回详情，点 `Fork 复制成我的 · Fork this`。**[W-G3]** 深链进 world 并对该产品 session 触发 `session_fork_action`。
4. **fork → 自己的 session** —— 在 world（demo：`world-step.html?mode=fork`），配置复制进一个**新** session；**seller 成 owner**（无历史）。anon→login 在此发生（`anon→login takeover`）。
5. （接场景 42 —— 改造 + 发布回去。）

## 预期

- 第 2 步：匿名访客不登录即可到产品的 `public_view` 面。
- 第 3→4 步：fork 复制的是**配置、不是历史**；建了一个新 `session_uri`，seller 是 `owner` —— 不是加入同一 session（那是场景 38 的「分享」路；fork ≠ join 是承重区别）。
- 源产品不受影响（fork 是复制）。

## 要测的失败模式

- **fork 变成 join** —— 点 Fork 把 seller 加进**同一** session 而非新建自有的 → 两路语义（38 join vs 39/41 fork）破了。
- **产品页够不到 fork** —— `session_fork_action` 在，但没有 UI 路径从货架产品触发它（**W-G3** 缺口）→ seller 无法拥有副本。
- **匿名试用被门控** —— `试用` 面对只读视图也要登录（匿名生命周期泄漏）。

## 交叉引用

- demo：`docs/website-demo/flywheel/{gallery,product-detail}.html` + `recruit-v2.html` + `world-step.html?mode=fork`。
- handoff：`docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md`（W-G1/W-G3）。
- 复用的旧场景：**35**（匿名访问）、**36**（匿名浏览 + 登录门控）、**39**（config-fork → 新自有 session）。本场景补**货架落地**。
- 设计：`docs/rh/homesite/`（seller arc S0–S3）；persona 李复制（`08 §2`）。

## 备注

- fork（W-G3 本体）**已 ✅** —— 别重造；把触发从产品页接上。
- 状态 🚧，直到 live 测试 + runbook + 截图 + 签收齐全。
