# MFU 猎人教学关卡 v0.3.2 聚焦修正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 恢复 v0.3 清晰流程，在编排工作台内教授角色与拖拽，并把调教页面改成四种升级方式的游戏界面。

**Architecture:** 保持现有单文件场景状态机，撤销 v0.3.1 的独立卡牌介绍、全程目标条、额外提示和结算评分。编排页用局部 Tour 加基于真实 DOM 坐标的 ghost 动画；调教页用单一 Agent 卡牌和四个升级入口承载 Form 购买与守则输入。

**Tech Stack:** 单文件 HTML、CSS、原生 JavaScript、LocalStorage、Node.js、Playwright。

## Global Constraints

- 设计事实源：`docs/superpowers/specs/2026-07-29-mfu-hunter-tutorial-v032-focus-correction-design.md`。
- 不增加独立卡牌介绍页面。
- 不显示贯穿全程的“当前目标”。
- Tour 同时圈出本人和小角，且不遮挡两张卡或任务位置。
- ghost 从真实卡牌区域移动到真实任务环节。
- ghost 同时显示：“把角色卡牌拖到任务的某一个环节，决定由谁来完成这部分工作。”
- 玩家可以自由安排本人和小角，同一卡牌可以承担多个环节。
- “阵列预估”改为自然语言“创业教练提示”，不引入具名教练。
- 调教页面中央靠上显示小角卡牌，底部显示喂范例、写守则、复盘、安装工具四种方式。
- 本关实际完成安装 Form 和写守则；喂范例仅说明，复盘因素材 0 不可完成。
- 删除结算页三项评分卡。
- 改 HTML 后运行脚本语法、静态契约和完整浏览器流程。
- `git commit` / `git push` 前必须先询问 ruihua。

---

### Task 1: 把测试契约改为聚焦流程

**Files:**
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Expects DOM: `#role-tour`, `#drag-ghost`, `#coach-tip`, `#agent-training-card`, `#training-methods`
- Expects functions: `acknowledgeRoleTour()`, `dismissDragGhost()`, `coachAdvice()`, `selectTrainingMethod()`

- [ ] **Step 1: 静态测试要求新增结构**

要求存在：

```js
for (const phrase of [
  "这是你现在可以编排的角色",
  "把角色卡牌拖到任务的某一个环节",
  "创业教练提示",
  "🍱 喂范例",
  "📏 写守则",
  "🔍 复盘",
  "🧰 安装工具"
]) assert.ok(html.includes(phrase));
```

要求不存在：

```js
for (const removed of [
  "你当前拥有的角色卡牌",
  "当前目标",
  "分工评价",
  "资源评价",
  "改进评价"
]) assert.ok(!html.includes(removed));
```

- [ ] **Step 2: 浏览器测试覆盖工作台内 Tour 与 ghost**

进入 `build` 后断言任务位置与角色卡牌已经同时可见；点击 `#acknowledge-role-tour` 后断言 `#drag-ghost` 和目的说明出现；第一次安排卡牌后断言 ghost 消失。

- [ ] **Step 3: 浏览器测试覆盖教练提示与调教方式**

自由编排一个缺少本人检查的阵列，断言 `#coach-tip` 提示可能误解且主按钮可用。进入调教页后，断言 Agent 卡牌和四个按钮存在；点击喂范例显示说明，点击复盘显示素材 0，安装 Form 后仍停留在调教页，再通过写守则进入 Form。

- [ ] **Step 4: 运行测试并确认失败**

```bash
node mfu-demo/test-card-array-v01.mjs
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/card-array-v01.browser.cjs
```

Expected: 分别因缺少新文案和 `#role-tour` 失败。

---

### Task 2: 实现工作台 Tour、ghost 和创业教练提示

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Test: `mfu-demo/test-card-array-v01.mjs`
- Test: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- State: `tutorial.roleTourSeen`, `tutorial.dragGhostDismissed`
- Produces: `acknowledgeRoleTour()`, `dismissDragGhost()`, `coachAdvice(assignments)`

- [ ] **Step 1: 撤销 v0.3.1 结构**

删除 `renderCardIntro()`、`currentObjective()`、`objectiveMarkup()`、`mechanicTip()`、`settlementAssessment()` 及相关 CSS；恢复结算页原有两栏布局。

- [ ] **Step 2: 在完整工作台内渲染角色 Tour**

使用包围整个手牌区的高亮框，并把 Tour 卡放在工作台右侧：

```html
<div id="role-tour">
  这是你现在可以编排的角色：你自己，以及你的第一个 Agent 小角。
  <button id="acknowledge-role-tour">知道了</button>
</div>
```

- [ ] **Step 3: 用真实坐标驱动 ghost**

在 `bindBoard()` 后读取本人卡牌和第一个任务位置的 `getBoundingClientRect()`，把 fixed 定位的半透明卡牌 ghost 从两者中心之间移动。ghost 同时渲染目的说明，任何选择、拖拽或分配操作调用 `dismissDragGhost()`。

- [ ] **Step 4: 改为创业教练提示**

`coachAdvice(assignments)` 返回自然语言；右侧渲染：

```html
<section id="coach-tip">
  <h2>创业教练提示</h2>
  <p>...</p>
</section>
```

不显示等级、分数或正确答案。

- [ ] **Step 5: 运行静态与浏览器测试**

Expected: 工作台相关契约通过；调教页面契约仍可失败。

---

### Task 3: 实现四种调教方式并同步文档

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/doc/core-gameplay-card-array.md`
- Modify: `mfu-demo/doc/student-opc-lifecycle-roadmap.md`
- Test: `mfu-demo/test-card-array-v01.mjs`
- Test: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- State: `trainingMethod`
- Produces: `selectTrainingMethod(method)`
- Produces DOM: `#agent-training-card`, `#training-methods`, `#training-detail`

- [ ] **Step 1: 重做调教页面布局**

中央靠上显示小角卡牌及当前资产；底部横向显示四个升级按钮，每个按钮写明名称、效果和成本。

- [ ] **Step 2: 实现四种入口**

- `examples`：显示“二选一鉴别，教出品味；本关先认识这种方式”；
- `rule`：展开现有守则输入表单；
- `review`：显示“当前复盘素材 0，打回与落选会产生素材”，不扣资源；
- `tool`：展开 Form 工具购买卡，购买后仍停留在本页。

只有已安装 Form 时，写守则按钮和表单才允许继续。

- [ ] **Step 3: 同步 living docs**

在核心玩法文档新增 v0.3.2，明确 v0.3.1 被取代；生命周期阶段 1 恢复聚焦描述，并引用 v0.3.2。

- [ ] **Step 4: 完整验证**

```bash
node mfu-demo/test-card-array-v01.mjs
node --check /tmp/mfu-card-array-v032.js
NODE_PATH=/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules node mfu-demo/card-array-v01.browser.cjs
git diff --check
mix precommit
```

Expected: 专项检查通过；`mix precommit` 若仍因当前 worktree 缺少 Phoenix/Hex 依赖失败，记录原始原因，不安装或清理依赖。

- [ ] **Step 5: 视觉复查与试玩**

检查 1440×900 下的角色 Tour、ghost、创业教练提示和调教页面，确认无浮层遮挡。提供局域网链接给 ruihua 试玩，未经允许不提交或推送。
