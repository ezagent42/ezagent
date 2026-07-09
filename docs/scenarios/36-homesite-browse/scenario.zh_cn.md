# 场景 36：官网访客旅程 — 浏览 → 登录门控 → 门控 CTA

**分类**：1 — 认证与访问（登录、令牌、成员资格）
**状态**：🚧 设计规范 — 现在即可针对静态 mock（`docs/website-demo/v1/`）录制；
真站层（`feat/website-framework-hello-prod-0630`，app.ezagent.chat）+ 实景
agent-browser 录制 待定。**未** ✅（尚无不变式测试 + 尚未签收）。
**作者**：Claude（与 ruihua），2026-07-02 — 从访客旅程 brainstorm 得出；
不另起 spec 文档（设计就落在本 scenario + 本分支 git 历史）。

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

一个首次到访的**匿名访客**落地 ezagent 营销官网，走一条连续的单一旅程：读完主张 →
去看源码（GitHub）或跳到实时进度（world.cup）→ 试图在底部对话框写东西、被**引导去登录**
→ 登录后**回到同一个官网页面**、nav 翻成已登录态 → 使用两个产品 CTA（`Try world`、
`Try hello`），每个都会**重新校验登录态**，已登录时在**新浏览器标签页**打开目标。

这是场景 [35](../35-external-user-anon-access/scenario.zh_cn.md)（外部匿名访问一个
socialware 会话）的**营销界面**姊妹篇。35 拥有承重的 匿名用户 + 成员资格 + 写入门控 基元；
36 从公开官网复用同一套 *匿名 → 写入门控 → 登录* 模式，并补上 35 未覆盖的
**登录后门控 CTA** 路径。

## 前置条件

标准前置（README §1.1）适用，另加：

- **录制目标（近期）**：本地起 `docs/website-demo/v1/` 静态 mock
  （`cd docs/website-demo/v1 && npx --yes serve . -l 8080`），配它的
  `mock-ezagent-api.js` + `login.html`。本 scenario 的 selector 锚定权威视觉参考
  `~/Desktop/Socialware.html`（官网的 socialware-external 存档渲染）；**在建的真站
  与 v1 不完全一样**，故步骤按**角色/文案**描述，不用脆弱的结构 class。
- **访客状态**：干净浏览器、无 session cookie → 页面渲染匿名 viewer 态
  （`data-viewer="anon"`；对话框输入框 `disabled`）。
- **登录凭据**：仅步骤 4–6 需要真登录。用任一 seed 用户（README §1.1 自助 token 配方），
  或针对 v1 录制时用 mock 的 `login.html`。

## 角色

- **访客（匿名）**：`entity://system/user/anon-<rand>` — 来自场景 35 的只读匿名用户
  变体（`caps_json` 为空；经成员资格读取，`chat.send` 在 CapBAC 第 5.5 步被拒）。
- **访客（登录后）**：一个带 session cookie 的真实 `Ezagent.Entity.User`。
- **界面**：官网页；nav 药丸（`.navlinks`）；底部对话框（`.previewbar`，匿名 → `disabled`）。
- **外部目标**：`github.com/ezagent42`（源码仓库）；`app.ezagent.chat/`（world 应用，
  新标签页）；hello builder（新标签页 — **暂用空白 HTML 占位**）。

## 步骤

Selector 列给出**角色/文案**（契约）与结构提示（`—` 仅参考，来自 Socialware.html；
真站可能不同）。

### 匿名浏览

1. **经 nav 进 GitHub** — 点 nav 链接 `↗ GitHub`
   *（`.navlinks` 内 a[href="https://github.com/ezagent42"]）*。
   → 浏览器导航到 `github.com/ezagent42`。
2. **经 hero CTA 进 GitHub** — 在 hero 点 `开始使用 · Get started →`
   *（主 `.cta [data-slot=button]`）*。
   → 与步骤 1 同一目标：`github.com/ezagent42`（开始使用 == 源码仓库，
   据 ruihua 2026-07-02）。
3. **跳到进度** — 点 `看看进度 · See progress`
   *（次要 hero CTA）*。
   → 页面平滑滚动到 **world.cup** 区块（`研发进度 · Progress` tab 面板，`.worldcup`，
   标签 `PROGRESS · world.cup`）。若 world.cup 在 tab 内，点击应先激活该 tab 再滚动。

### 写入门控 → 登录

4. **对话框写入尝试** — 底部对话框输入框 `disabled`、placeholder `登录后参与`；
   点对话框动作按钮 `登录` *（`.previewbar-action`）*。
   → 匿名写入尝试被**置换为登录流**（不静默丢弃 — 明确告知访客去登录）。这与场景 35
   的写入门控是同一个。
5. **登录 + 回跳** — 完成登录。成功后访客**回到同一个官网页面**（**不是** `/admin`、
   **不是**裸 `/`），且 nav 的 `登录 · Login` 按钮
   *（`.navlinks [data-slot=button][data-variant=secondary]`）* 翻成**已登录态**
   （`已登录`）。对话框输入框变为可用。

### 登录后门控 CTA

6. **Try world** — 点 world 产品 CTA `试玩 · Try world →`
   *（`.product-world .product-foot [data-slot=button]`）*。
   → **若匿名**：重新门控去登录（同步骤 4）。**若已登录**：在**新浏览器标签页**
   （`target=_blank`）打开 `app.ezagent.chat/`，官网标签页留在原处。
7. **Try hello** — 点 hello 产品 CTA `试玩 · Try hello →`
   *（`.product-hello .product-foot [data-slot=button]`）*。
   → **若匿名**：重新门控去登录。**若已登录**：在新标签页打开 **hello builder**
   （当前是**空白 HTML 占位**页）。

## 实测结果 vs 预期

营销界面 — 结果断言在**可见行为**层（这是 transport、不是 router 副作用；CapBAC 拒绝
基元在场景 35 断言，此处 cross-ref、不重证）：

- 步骤 1–2：顶层文档 URL == `github.com/ezagent42`。
- 步骤 3：world.cup 区块滚入视野（其标题可见；若分 tab 则 Progress tab 激活）。
- 步骤 4：匿名对话框写入永不发出消息；落到登录。
- 步骤 5：登录后文档 URL == 官网路径（回跳往返保持）；nav 显示已登录（`已登录`）
  态势；对话框输入框 `disabled` → 可用。
- 步骤 6–7（已登录）：每次点击恰好打开**一个新标签页**，分别指向 `app.ezagent.chat/`
  与 hello builder。
- 步骤 6–7（匿名）：不开新标签；落到登录。

## 失败模式（需测试）

- **门控泄漏** — 匿名点 `Try world` / `Try hello` 直接打开目标应用而非登录。门控承重；
  泄漏意味着匿名用户抵达了已认证界面。
- **登录回跳丢上下文** — 登录后落到 `/admin` 或裸 `/` 而非离开时的官网页。回跳 URL
  必须往返官网。
- **CTA 静默失效** — 新标签打开被弹窗拦截、或缺 `target=_blank`，点击毫无可见反应。
  "失败了谁会知道？" → 必须降级为可见导航或报错，绝不 no-op。
- **nav 态陈旧** — 登录后 nav 仍显示 `登录 · Login`（态未重渲染），访客无法得知已登录。
- **锚点跑偏** — `See progress` 滚到错误区块，或（分 tab 时）未激活 Progress tab
  导致 world.cup 仍隐藏。

## 交叉引用

- 场景 [35](../35-external-user-anon-access/scenario.zh_cn.md) — 本 scenario 复用的
  匿名用户 + 成员资格 + 写入门控→登录 基元。
- 视觉/结构参考：`~/Desktop/Socialware.html`（官网的 socialware-external 存档渲染）。
- 录制 mock：`docs/website-demo/v1/`（index.html、hello-demo.html、login.html、
  site-nav.js、worldcup.js、mock-ezagent-api.js）。
- 真站构建：`feat/website-framework-hello-prod-0630`（T4，
  `docs/together/2026-06-30/plan.md`）；生产目标 `app.ezagent.chat`。
- Socialware 外链路由：`/socialware/external`
  （`apps/ezagent_web/lib/ezagent_web/router.ex:157`）。

## 备注

- **状态刻意标 🚧。** 登录回跳、`已登录` nav 翻转、门控新标签 CTA 是**真站尚未完全构建
  的预期行为**。在确定性/实景测试 + runbook + agent-browser 截图存在且 ruihua/Allen
  签收之前，**不要**标 ✅（`feedback_completion_requires_invariant_test`）。
- **录制备注（路径 A）。** 这条设计 scenario 是后续 Playwright 录制脚本的地图。录制脚本
  仿 `scripts/demo/agent-create-record.js`：`login()` → 存 `storageState` →
  `recordVideo` context → 用 角色/文案 selector 驱动步骤 1–7 + 每步 `snap()` → 关闭 →
  改名 `demo.webm` → ffmpeg 转 GIF/MP4。步骤 6–7 会开新标签 — 录制脚本必须 await
  `context.on('page')`（弹出页）并捕获它，否则视频漏掉新标签内容。
- **hello builder** 在真实页面上线前是空白 HTML 占位；scenario 只断言"打开一个到
  hello builder 的新标签"，不断言其内容。
