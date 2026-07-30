# MFU · MVO 组织孵化总览 Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 制作一个打开即能看见孵化器如何把零散资源转化为多个 MVO 的单文件可玩 Demo。

**Architecture:** 新建独立单文件 HTML，以一个宏观看板为主场景，使用显式 JavaScript 状态管理资源、推荐 MVO、任务和认证。玩家一键确认三个推荐组合后，资源流入组织缩略图，三个 MVO 自动从 To Do 推进到 Doing 和 Done；组织图细节只通过只读弹窗下钻。

**Tech Stack:** 单文件 HTML、CSS、原生 JavaScript、LocalStorage、Node.js、Playwright、MFU Design System。

## Global Constraints

- 设计事实源：`docs/superpowers/specs/2026-07-30-mfu-mvo-incubator-overview-design.md`。
- 新建 `mfu-demo/MFU-MVO孵化总览-v0.1-可玩原型.html`，不覆盖已有 Demo。
- 首页打开即展示资源、可以创造什么、已产出的 MVO 和运行中的 MVO。
- 首页必须突出“12 名学生 → 6 个可运行 MVO”。
- 玩家身份是孵化器运营者。
- 第一版只展示宏观进度和结果，不要求理解具体操作。
- 一键确认 3 个推荐 MVO 后，必须出现资源流入和组织形成动画。
- 至少 3 个 MVO 同时进入运行状态。
- 至少 1 个 MVO 完成后获得“认证 MVO”。
- 具体组织图只作为可选下钻预览。
- 使用 MFU 羊皮纸、纸叠阴影、粗描边、孵化器橙和金色 CTA。
- 支持 `prefers-reduced-motion`，桌面正文不小于 9.5px，键盘焦点可见。
- 改 HTML 后运行脚本语法、静态契约和浏览器流程。
- `git commit` / `git push` 前必须先询问 ruihua。

---

### Task 1: 建立 Demo 契约

**Files:**
- Create: `mfu-demo/test-mvo-incubator-v01.mjs`
- Create: `mfu-demo/mvo-incubator-v01.browser.cjs`

**Interfaces:**
- Expects DOM: `#incubator-dashboard`, `#resource-inventory`, `#opportunity-board`, `#mvo-portfolio`, `#mvo-running`, `#incubate-three`, `#incubation-overlay`
- Expects functions: `incubateRecommendedMvos()`, `advanceMvos()`, `openMvoDetail()`, `resetDemo()`

- [ ] **Step 1: 写静态失败契约**

检查目标 HTML 存在，并包含：

```js
for (const phrase of [
  "12 名学生",
  "6 个可运行的 MVO",
  "再孵化 3 个 MVO",
  "可以创造什么",
  "正在运行",
  "认证 MVO"
]) assert.ok(html.includes(phrase));
```

- [ ] **Step 2: 写浏览器失败契约**

打开页面后断言四个宏观区域同时可见；点击 `#incubate-three` 后断言 `#incubation-overlay` 出现，确认后等待三个新 MVO 进入运行；推进后至少一个进入 Done 并获得认证。

- [ ] **Step 3: 运行并确认失败**

```bash
node mfu-demo/test-mvo-incubator-v01.mjs
```

Expected: FAIL，目标 HTML 尚不存在。

---

### Task 2: 实现打开即是高潮的宏观看板

**Files:**
- Create: `mfu-demo/MFU-MVO孵化总览-v0.1-可玩原型.html`
- Test: `mfu-demo/test-mvo-incubator-v01.mjs`

**Interfaces:**
- State: `resources`, `opportunities`, `mvos`, `tasks`, `incubation`
- Produces: `renderDashboard()`, `renderResources()`, `renderOpportunities()`, `renderMvos()`, `renderRunning()`

- [ ] **Step 1: 实现 MFU 页面框架**

顶部展示孵化器名称、核心转化成果与五类资源数字；主区域用四块纸张面板展示资源、机会、MVO 组合和运行状态。

- [ ] **Step 2: 实现首页高潮数据**

初始状态展示：

- 人才 12、Agent 6、IP / 工具 4、算力 240、资金 ¥20,000；
- 已孵化 MVO 6、正在运行 3、已认证 1、还可创建 3；
- 三个简化三步组织图；
- 三个运行中的任务进度。

- [ ] **Step 3: 实现轻量首屏动画**

页面加载后，代表人才、Agent 和 IP 的小卡片流入三个组织图，随后数字停在“6 个 MVO”。减少动态效果时直接显示最终状态。

- [ ] **Step 4: 实现只读下钻**

点击任意 MVO 打开弹窗，展示三步组织图、装入的代表资源、输入输出、声望、任务和验证摘要。弹窗不要求玩家编辑。

- [ ] **Step 5: 运行静态契约**

Expected: PASS。

---

### Task 3: 实现批量孵化、自动运行与认证

**Files:**
- Modify: `mfu-demo/MFU-MVO孵化总览-v0.1-可玩原型.html`
- Test: `mfu-demo/mvo-incubator-v01.browser.cjs`

**Interfaces:**
- Produces: `incubateRecommendedMvos()`, `confirmIncubation()`, `advanceMvos()`, `openMvoDetail(id)`, `resetDemo()`

- [ ] **Step 1: 实现三个推荐组合**

“再孵化 3 个 MVO”打开确认层，展示校园内容、市场验证和用户研究三个推荐组织，每个只显示三步图、已具备资源和预期任务。

- [ ] **Step 2: 实现资源流入动画**

确认后显示人才、Agent 和 IP 小卡片分别进入三个组织图；资源数量从空闲转为占用，MVO 总数从 6 增长到 9。

- [ ] **Step 3: 实现自动运行**

三个新 MVO 同时进入 Doing。`advanceMvos()` 让进度分阶段增长，完成后任务进入 Done，并展示交付结果和人才、Agent、MVO 的成长。

- [ ] **Step 4: 实现认证高潮**

校园增长 MVO 完成后，声望达到 60，播放盖章动画并标记“认证 MVO”。

- [ ] **Step 5: 实现重置和存档**

LocalStorage 保存孵化与运行进度；右上角“重新演示”清除存档并回到初始高潮首页。

- [ ] **Step 6: 完整验证**

```bash
node mfu-demo/test-mvo-incubator-v01.mjs
node --check /tmp/mfu-mvo-incubator-v01.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/mvo-incubator-v01.browser.cjs
git diff --check
mix precommit
```

Expected: 专项检查通过；若 `mix precommit` 仍因 worktree 缺少 Phoenix / Hex 依赖失败，记录原因，不安装依赖。

- [ ] **Step 7: 视觉复查**

检查 1440×900、1280×800 和窄屏布局；确认首页四块信息同时可读、首屏核心转化最突出、没有横向溢出，并删除至少一个不服务信息理解的装饰元素。

- [ ] **Step 8: 交给 ruihua 试玩**

提供局域网链接，未经允许不提交或推送。
