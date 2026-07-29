# MFU 猎人教学关卡 v0.3.1 连续引导 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让玩家先认识本人和小角两张角色卡，通过不遮挡内容的动画学会自由编排，并在连续引导下完成首单、理解风险和获得可解释的结算评价。

**Architecture:** 保持单文件 HTML、CSS 和原生 JavaScript 的场景状态结构，在现有 `state.tour` 上增加“卡牌认识、当前目标、已完成关键提示”状态。编排仍使用现有 `assignments`，新增纯函数计算分工风险与结算评价；关键机制使用短 Tour，其余步骤使用不遮挡操作区的当前目标条。

**Tech Stack:** 单文件 HTML、CSS、原生 JavaScript、LocalStorage、Node.js、Playwright。

## Global Constraints

- 设计事实源：`docs/superpowers/specs/2026-07-29-mfu-hunter-tutorial-v03-design.md` 第 8 节。
- 继续修改 `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`，不修改旧 v0.14 / v0.15 原型。
- 先介绍“你自己”和“小角”，玩家点击“知道了，开始编排”后才进入拖拽。
- 拖拽示意动画不得遮挡角色卡牌或任务位置。
- 玩家可以自由安排本人和小角，不设置唯一强制答案。
- 高风险编排只提醒，不阻止执行。
- 同一张角色卡可以承担多个任务位置。
- 每个后续场景只有一个明确的当前目标，直到完整订单结算。
- 结算评价分为“分工、资源、改进”，每项必须解释原因。
- 刷新后不重复已经完成的卡牌介绍或关键 Tour。
- 改 HTML 后必须提取脚本并运行 `node --check`。
- 每次 `git commit` / `git push` 前必须先询问 ruihua。

---

## File Map

| 文件 | 职责 |
|---|---|
| `mfu-demo/test-card-array-v01.mjs` | 检查连续引导、风险评价和必要文案的静态契约 |
| `mfu-demo/card-array-v01.browser.cjs` | 覆盖卡牌认识、自由编排、风险提醒、完整引导及刷新恢复 |
| `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html` | 实现卡牌介绍、拖拽动画、当前目标、风险和结算评价 |
| `mfu-demo/doc/core-gameplay-card-array.md` | 把 v0.3.1 连续教学规则写入核心玩法 living doc |
| `mfu-demo/doc/student-opc-lifecycle-roadmap.md` | 把首单生命周期更新为连续引导与可解释评价 |

---

### Task 1: 建立 v0.3.1 静态与浏览器失败契约

**Files:**
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Expects: `acknowledgeCards()`, `currentObjective()`, `assignmentAssessment()`, `settlementAssessment()`
- Expects DOM: `#card-intro`, `#acknowledge-cards`, `#drag-demo`, `#current-objective`, `#assignment-risk`, `#settlement-assessment`

- [ ] **Step 1: 增加静态契约**

在静态测试中要求以下文案和函数存在：

```js
for (const phrase of [
  "你当前拥有的角色卡牌",
  "你的第一个 Agent",
  "知道了，开始编排",
  "当前目标",
  "分工评价",
  "资源评价",
  "改进评价"
]) {
  assert.ok(html.includes(phrase), `missing v0.3.1 copy: ${phrase}`);
}

for (const token of [
  "acknowledgeCards",
  "currentObjective",
  "assignmentAssessment",
  "settlementAssessment"
]) {
  assert.ok(html.includes(token), `missing v0.3.1 interaction: ${token}`);
}
```

- [ ] **Step 2: 增加浏览器行为契约**

在进入 `build` 后依次断言：

```js
await page.locator("#acknowledge-cards").click();
assert.equal(await page.locator("#drag-demo").isVisible(), true);

await dragCard(page, "agent", "understand");
await dragCard(page, "agent", "make");
await dragCard(page, "agent", "check");

assert.match(
  await page.locator("#assignment-risk").textContent(),
  /缺少本人检查|需求误解/
);
assert.equal(await page.locator("#primary-action").isEnabled(), true);
```

完整流程结束后断言：

```js
const assessment = await page.locator("#settlement-assessment").textContent();
assert.match(assessment, /分工评价/);
assert.match(assessment, /资源评价/);
assert.match(assessment, /改进评价/);
```

- [ ] **Step 3: 运行测试并确认正确失败**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
node mfu-demo/card-array-v01.browser.cjs
```

Expected:

- 静态测试首先报告缺少“你当前拥有的角色卡牌”；
- 浏览器测试报告找不到 `#acknowledge-cards`；
- 失败来自新功能尚未实现，而不是语法或服务器错误。

---

### Task 2: 实现卡牌认识与不遮挡的拖拽示范

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Test: `mfu-demo/test-card-array-v01.mjs`
- Test: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Produces state: `tutorial.cardsIntroduced`, `tutorial.dragDemoDismissed`, `tutorial.completedTours`
- Produces: `acknowledgeCards(): void`
- Produces DOM: `#card-intro`, `#acknowledge-cards`, `#drag-demo`

- [ ] **Step 1: 扩展并恢复教学状态**

在 `initialState` 中加入：

```js
tutorial: {
  cardsIntroduced: false,
  dragDemoDismissed: false,
  completedTours: []
}
```

在 `restoreState()` 中像 `resources`、`tour` 一样合并 `tutorial`，保证旧存档也能使用默认值。

- [ ] **Step 2: 实现卡牌认识层**

`build` 场景首次进入时渲染：

```html
<section id="card-intro" class="card-intro">
  <h2>这是你当前拥有的角色卡牌</h2>
  <!-- 完整显示本人和小角卡牌 -->
  <button id="acknowledge-cards" type="button" onclick="acknowledgeCards()">
    知道了，开始编排
  </button>
</section>
```

`acknowledgeCards()` 设置 `cardsIntroduced = true`、保存并重新渲染。介绍层存在时，任务位置不接受点击或拖放。

- [ ] **Step 3: 实现拖拽示范动画**

在手牌区与任务区之外生成 `#drag-demo`，使用绝对定位的半透明卡牌副本、CSS `@keyframes demo-drag` 和目标位置 `demo-target` 呼吸高亮。任何 `dragstart`、卡牌点击或第一次成功安排都会调用：

```js
function dismissDragDemo() {
  state.tutorial.dragDemoDismissed = true;
  persist();
}
```

在 `@media(prefers-reduced-motion:reduce)` 下隐藏移动副本，仅保留箭头和目标高亮。

- [ ] **Step 4: 运行静态与卡牌认识浏览器测试**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
node mfu-demo/card-array-v01.browser.cjs
```

Expected: 卡牌介绍和动画相关断言 PASS；后续风险或结算断言仍可失败。

---

### Task 3: 实现自由编排、风险提醒和贯穿整单的当前目标

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Test: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Produces: `assignmentAssessment(assignments): {level: string, title: string, detail: string}`
- Produces: `currentObjective(state): {title: string, detail: string}`
- Produces DOM: `#assignment-risk`, `#current-objective`

- [ ] **Step 1: 用纯函数计算分工风险**

实现三个最小分支：

```js
function assignmentAssessment(assignments) {
  const values = Object.values(assignments);
  const hasPlayerCheck = assignments.check === "player";
  const allPlayer = values.length === 3 && values.every(id => id === "player");

  if (!hasPlayerCheck) {
    return {
      level: "high",
      title: "可能产生需求误解",
      detail: "当前没有安排本人检查。你可以调整，也可以承担风险继续执行。"
    };
  }

  if (allPlayer) {
    return {
      level: "medium",
      title: "质量可控，但本人投入较多",
      detail: "全部由本人完成会占用更多时间。"
    };
  }

  return {
    level: "steady",
    title: "分工较稳妥",
    detail: "本人负责关键判断和检查，小角负责快速执行。"
  };
}
```

风险卡显示在阵列预估区。填满三个位置后，无论风险等级如何都允许执行。

- [ ] **Step 2: 让卡牌可以重复承担任务**

保留 `assignments[slotId] = cardId`，不要在分配新位置时删除同一 `cardId` 的旧位置。拖拽和“先点卡牌、再点位置”都必须遵循同一规则。

- [ ] **Step 3: 实现当前目标条**

`currentObjective(state)` 根据场景和细分状态返回唯一目标：

```js
const objectives = {
  briefing: "看懂订单背景和你负责的步骤",
  build: "安排你自己和小角，然后确认执行",
  firstRun: "等待小角完成第一版成果",
  inspect: "检查成果并把需求偏差反馈给小角",
  tune: state.agent.formInstalled
    ? "写下守则，让小角知道何时向你确认"
    : "购买并安装 Form 工具",
  clarify: "回答小角通过 Form 提出的问题",
  secondRun: "等待小角完成修正版",
  stepDelivered: "确认自己的步骤与完整订单的不同状态",
  settlement: "查看本轮结算与评价"
};
```

所有非欢迎页在主要内容上方渲染 `#current-objective`。目标随操作自动更新，不增加“下一步”按钮。

- [ ] **Step 4: 为关键节点增加短 Tour**

首次进入 `tune`、`stepDelivered`、`settlement` 时显示不遮挡主要按钮的短提示；关闭后把标识加入 `tutorial.completedTours`。刷新后不再重复已经完成的提示。

- [ ] **Step 5: 运行完整浏览器流程**

Run:

```bash
node mfu-demo/card-array-v01.browser.cjs
```

Expected:

- 自由编排和高风险提示 PASS；
- 高风险编排仍可开始执行；
- 从背景页到结算每个场景都有当前目标；
- 刷新后不重复卡牌介绍。

---

### Task 4: 实现结算评价并同步 living docs

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/doc/core-gameplay-card-array.md`
- Modify: `mfu-demo/doc/student-opc-lifecycle-roadmap.md`
- Test: `mfu-demo/test-card-array-v01.mjs`
- Test: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: `assignmentAssessment(state.assignments)`
- Produces: `settlementAssessment(state): Array<{name: string, grade: string, reason: string}>`
- Produces DOM: `#settlement-assessment`

- [ ] **Step 1: 计算三项结算评价**

实现：

```js
function settlementAssessment(state) {
  const assignment = assignmentAssessment(state.assignments);

  return [
    {
      name: "分工评价",
      grade: assignment.level === "steady" ? "稳妥" : "有风险",
      reason: assignment.detail
    },
    {
      name: "资源评价",
      grade: state.resources.compute >= 12 ? "可控" : "消耗较高",
      reason: `剩余 ${state.resources.compute} 点算力、${state.resources.personalHours} 小时本人时间和 ¥${state.resources.cash}。`
    },
    {
      name: "改进评价",
      grade: state.agent.ruleVerified ? "已验证" : "未验证",
      reason: state.agent.ruleVerified
        ? "你通过反馈、Form 和守则解决了真实需求偏差。"
        : "新工具或守则还没有在真实执行中验证。"
    }
  ];
}
```

在结算页渲染为三个并列评价卡，每张卡显示名称、等级和原因。

- [ ] **Step 2: 同步核心玩法 living doc**

在 `core-gameplay-card-array.md` 的 v0.3 后增加 v0.3.1 小节，写明：

```text
认识卡牌
→ 动画示范拖拽
→ 自由编排与风险提醒
→ 当前目标贯穿首单
→ 结算解释分工、资源和改进
```

明确高风险安排不阻止执行、卡牌可以重复承担多个位置、刷新不重复已完成引导。

- [ ] **Step 3: 同步生命周期 roadmap**

在阶段 1 中补充：

- 先认识本人和第一个 Agent；
- 通过示意动画学会编排；
- 每个页面只显示一个当前目标；
- 结算获得分工、资源和改进评价。

- [ ] **Step 4: 运行全部专项验证**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
node mfu-demo/card-array-v01.browser.cjs
```

提取 HTML 中的最后一个脚本块后运行：

```bash
node --check /tmp/mfu-card-array-v031.js
```

Expected: 三项均 PASS。

- [ ] **Step 5: 运行仓库与格式检查**

Run:

```bash
git diff --check
mix precommit
```

Expected:

- `git diff --check` PASS；
- 若当前 worktree 仍因缺少 Phoenix / Hex 依赖导致 `mix precommit` 无法启动，记录原始错误，不安装或清理依赖。

- [ ] **Step 6: 桌面视觉验收**

使用 1440×900 截取并检查：

- 卡牌介绍；
- 拖拽动画；
- 高风险编排；
- 调教 Agent Tour；
- 步骤交付 Tour；
- 三项结算评价。

确认没有浮层遮挡角色卡牌、任务位置、表单或主要按钮，并确认常用桌面宽度无横向滚动。

- [ ] **Step 7: 请求 ruihua 试玩**

提供当前局域网试玩链接，请重点检查：

1. 不读说明能否理解拖拽；
2. 是否知道小角是第一个 Agent；
3. 自由编排和风险提醒是否自然；
4. 完成拖拽后是否始终知道下一步；
5. 结算评价是否容易理解。

在 ruihua 明确允许前不执行 `git commit` 或 `git push`。
