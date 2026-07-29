# MFU 首个猎人教学订单 v0.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前协作阵列原型改成聚焦“完成自己的步骤”的首个猎人教学订单，并用一次真实返工教会玩家编排本人和 Agent、检查成果、购买 Form、写守则和完成整单结算。

**Architecture:** 继续使用单文件 HTML/CSS/原生 JavaScript，以显式场景状态驱动“昵称—背景—编排—错误成果—调教—Form—重试—步骤交付—整单结算”。浏览器 `localStorage` 保存玩家昵称、资源、调教和执行进度；静态契约测试检查必要界面与函数，Playwright 覆盖完整用户流程和恢复场景。

**Tech Stack:** 单文件 HTML、CSS、原生 JavaScript、LocalStorage、Node.js、Playwright。

## Global Constraints

- 设计事实源：`docs/superpowers/specs/2026-07-29-mfu-hunter-tutorial-v03-design.md`。
- 继续修改 `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`，本轮不重命名文件。
- 不修改 `mfu-demo/MFU-v0.14-可试玩原型.html` 和 `mfu-demo/MFU-v0.15-可试玩原型.html`。
- 首关只教授猎人完成自己的步骤，不出现邀请伙伴、建立组织或拆单教学。
- 教学订单不限时；正式订单与现实世界时间同步的规则必须在页面中说明。
- 初始本人时间为 `2` 小时、Agent 算力为 `24` 点、公司现金为 `200` 元。
- Form 工具售价为 `80` 元；购买后现金必须显示为 `120` 元。
- 写守则必须由玩家填写或编辑，并消耗本人时间。
- Agent 第一次必须产生可见的错误成果；第二次必须调用 Form 后修正成果。
- 玩家步骤交付与完整订单结算是两个不同场景。
- 所有状态保存在当前浏览器；重置教学后回到昵称输入。
- 改 HTML 后必须提取脚本并运行 `node --check`。
- 每次 `git commit` / `git push` 前必须先询问 ruihua。

---

## File Map

| 文件 | 职责 |
|---|---|
| `mfu-demo/doc/core-gameplay-card-array.md` | 把 v0.2 教学方向演进为已确认的 v0.3 猎人教学规则 |
| `mfu-demo/doc/student-opc-lifecycle-roadmap.md` | 修订阶段 1、阶段 2、伙伴卡牌和组织者 / 拆单方分支 |
| `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html` | 可直接打开的完整教学关卡 |
| `mfu-demo/test-card-array-v01.mjs` | 单文件结构、必要文案和函数的静态契约 |
| `mfu-demo/card-array-v01.browser.cjs` | 昵称到整单结算、刷新恢复和桌面布局的浏览器回归 |

---

### Task 1: 同步核心玩法与生命周期 Living Docs

**Files:**
- Modify: `mfu-demo/doc/core-gameplay-card-array.md`
- Modify: `mfu-demo/doc/student-opc-lifecycle-roadmap.md`

**Interfaces:**
- Consumes: `docs/superpowers/specs/2026-07-29-mfu-hunter-tutorial-v03-design.md`
- Produces: v0.3 教学规则和组织者分支，供后续实现与验收引用

- [ ] **Step 1: 在核心玩法文档新增 v0.3 章节**

在 `core-gameplay-card-array.md` 的 v0.2 之后新增：

```markdown
## 21. v0.3：聚焦猎人完成自己的步骤

### 21.1 首关边界

首关只教授：

编排本人和 Agent
→ 检查 Agent 的真实成果
→ 花资源调教 Agent
→ 重新执行并完成自己的步骤
→ 等待整单完成后结算

主动连接、保存真人卡牌、成立组织和拆单进入独立的组织者教学关卡。
```

继续写明昵称、Tour、独立资源区、教学不限时、错误成果、Form 购买、守则输入、步骤交付和整单结算规则。保留 v0.1/v0.2 作为历史演进记录，不回改其原始章节。

- [ ] **Step 2: 修订生命周期阶段 1**

将 `student-opc-lifecycle-roadmap.md` 阶段 1 的行动改为：

```markdown
1. 输入自己的昵称；
2. 看懂自己在完整订单中的位置；
3. 在 Tour 引导下把本人和 Agent 放入任务位置；
4. 检查 Agent 第一次产生的错误成果；
5. 花钱安装 Form、花本人时间写守则；
6. 回答 Form 并让 Agent 重新执行；
7. 交付自己的步骤；
8. 等待完整订单完成后统一结算。
```

删除阶段 1 中“邀请上下游”和“第一次体验组成组织”的要求；将验证重点从“时间压力”改为“能否理解返工、调教与资源成本”。

- [ ] **Step 3: 修订生命周期阶段 2**

明确第一份自由订单才首次教授：

```markdown
- 正式订单与现实世界时间同步；
- 页面关闭后倒计时继续；
- Agent 离线执行；
- 等待本人判断会消耗真实时间；
- 截止临近提醒。
```

- [ ] **Step 4: 重写阶段 4 并增加角色分支**

阶段 4 先定义：

```text
看见同单协作者表现
→ 保存可信协作者卡牌
→ 形成可联系的能力网络
```

在阶段 4 和阶段 5 之间新增“组织者 / 拆单方角色分支”：

```text
获得成立组织资质
→ 解锁组织与拆单教学
→ 邀请真人并获得接受
→ 给组织命名
→ 拆解完整订单
→ 分配给成员和 Agent
```

写明孵化器、协会等已认证组织可以直接解锁该教学，普通学生 / OPC 需要先取得资质。

- [ ] **Step 5: 验证文档**

Run:

```bash
git diff --check
rg -n "v0.3|Form|教学关卡不限时|组织者 / 拆单方" \
  mfu-demo/doc/core-gameplay-card-array.md \
  mfu-demo/doc/student-opc-lifecycle-roadmap.md
```

Expected:

- `git diff --check` exit 0；
- 两份文档都能找到新增规则；
- 阶段 1 不再要求邀请上下游。

- [ ] **Step 6: 请求 ruihua 允许后提交文档同步**

Suggested commit:

```text
docs(mfu): focus first tutorial on hunter delivery
```

---

### Task 2: 建立 v0.3 静态契约、场景和状态

**Files:**
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`

**Interfaces:**
- Produces: `SCENES`
- Produces: `state.nickname`, `state.resources`, `state.tour`, `state.agent`, `state.feedback`, `state.formAnswers`
- Produces: `saveNickname(nickname)`, `spendResource(kind, amount)`
- Removes: `ambiguityChoice`, `invited`, `accepted`, `actTwoSlots`

- [ ] **Step 1: 先把静态测试改成 v0.3 契约**

删除对以下旧内容的要求：

```js
"主动连接"
"正式平台需真人确认"
"让 Agent 自行继续"
"由本人确认"
"询问上游猎人"
"inviteHunter"
"simulateAcceptance"
```

新增：

```js
for (const phrase of [
  "输入你的昵称",
  "准备好了，开始闯关",
  "教学关卡不限时",
  "正式订单与现实世界时间同步",
  "公司现金",
  "调教 Agent",
  "Form 工具",
  "购买并安装 · ¥80",
  "缺少必要信息时，先用 Form 向我确认",
  "你的成果已交付",
  "完整订单仍在进行",
  "领取第一份自由订单"
]) {
  assert.ok(html.includes(phrase), `missing v0.3 copy: ${phrase}`);
}

for (const token of [
  "saveNickname",
  "spendResource",
  "startFirstRun",
  "submitFeedback",
  "purchaseFormTool",
  "saveAgentRule",
  "submitClarificationForm",
  "startSecondRun",
  "completePlayerStep",
  "completeWholeOrder"
]) {
  assert.ok(html.includes(token), `missing v0.3 interaction: ${token}`);
}
```

增加负向契约：

```js
for (const removed of [
  "第二幕：用连接组成一个新组织",
  "邀请长期合作",
  "让 Agent 自行继续",
  "询问上游猎人"
]) {
  assert.ok(!html.includes(removed), `removed first-tutorial content remains: ${removed}`);
}
```

- [ ] **Step 2: 运行静态测试并确认失败**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
```

Expected: FAIL，首先报告缺少“输入你的昵称”或新的交互函数。

- [ ] **Step 3: 替换场景集合**

使用：

```js
const SCENES = [
  "welcome",
  "briefing",
  "build",
  "firstRun",
  "inspect",
  "tune",
  "clarify",
  "secondRun",
  "stepDelivered",
  "settlement"
];
```

删除第二幕相关场景、卡牌和关系。页面顶部阶段标签统一为“首个猎人教学订单”，不再显示“第一幕 / 第二幕”。

- [ ] **Step 4: 建立最小 v0.3 状态**

```js
const initialState = {
  scene: "welcome",
  nickname: "",
  selectedCard: null,
  assignments: {},
  relation: "serial",
  resources: {
    personalHours: 2,
    compute: 24,
    cash: 200
  },
  tour: {
    active: true,
    step: "drag-player",
    skipped: false
  },
  agent: {
    formInstalled: false,
    rule: "",
    ruleVerified: false
  },
  firstRun: null,
  feedback: "",
  formAnswers: {
    audience: "",
    action: ""
  },
  secondRun: null,
  playerStepStatus: "not-started",
  wholeOrderStatus: "in-progress"
};
```

提供：

```js
function saveNickname(nickname) {
  const clean = String(nickname || "").trim().slice(0, 20);
  if (!clean) return false;
  state.nickname = clean;
  persist();
  setScene("briefing");
  return true;
}

function spendResource(kind, amount) {
  if (!(kind in state.resources) || state.resources[kind] < amount) return false;
  state.resources[kind] -= amount;
  persist();
  return true;
}
```

- [ ] **Step 5: 更新持久化和测试场景直达数据**

`persist()` 保存全部 v0.3 状态。`restoreState()` 对旧的 `mfu-card-array-v01` 数据进行安全迁移：如果存档没有 `nickname` 或 `resources`，丢弃旧存档并使用 `initialState`，避免旧第二幕状态污染新流程。

`?scene=` 只用于开发检查；直达中后段场景时，`seedForScene()` 填入昵称“测试玩家”和该场景必需的最小前置数据。

- [ ] **Step 6: 运行静态测试和脚本检查**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
perl -0777 -ne 'print $1 if /<script>(.*?)<\/script>/s' \
  mfu-demo/MFU-协作阵列-v0.1-可玩原型.html > /tmp/mfu-hunter-v03.js
node --check /tmp/mfu-hunter-v03.js
```

Expected: 静态测试仍可能因页面尚未实现而失败；`node --check` 必须 PASS。

---

### Task 3: 昵称、背景按钮、资源区和拖拽 Tour

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: `state.nickname`, `state.resources`, `state.tour`
- Produces: `renderWelcome()`, `renderOrderResources()`, `renderTour()`, `advanceTour(action)`
- Produces DOM: `#nickname-form`, `#nickname-input`, `#order-resources`, `#tour-overlay`, `[data-tour-target]`

- [ ] **Step 1: 把浏览器测试的开头改为昵称流程**

```js
await page.goto(demoUrl);
assert.match(await page.locator("#scene-title").textContent(), /欢迎来到 MFU/);
await page.locator("#nickname-input").fill("阿禾");
await page.locator("#nickname-form").getByRole("button").click();
assert.match(await page.locator("#scene-content").textContent(), /你 · 阿禾/);
assert.equal(await page.locator("[data-card]").count(), 0);
await page.locator("#primary-action").click();
assert.match(await page.locator("#scene-title").textContent(), /小阵列/);
```

- [ ] **Step 2: 运行浏览器测试并确认失败**

Run:

```bash
node mfu-demo/card-array-v01.browser.cjs
```

Expected: FAIL，找不到 `#nickname-input`。

- [ ] **Step 3: 实现昵称页**

```html
<form id="nickname-form" class="nickname-form">
  <label for="nickname-input">输入你的昵称</label>
  <input id="nickname-input" maxlength="20" placeholder="例如：小满" autocomplete="nickname">
  <button class="btn primary" type="submit">进入教学订单</button>
</form>
```

提交时调用 `saveNickname()`。空值时显示就地错误，不跳页。

- [ ] **Step 4: 更新背景页和主按钮布局**

- 使用 `state.nickname` 替换所有“小满”玩家称呼；
- 截止信息改为“教学关卡不限时”；
- `#primaryRow` 在 `briefing` 场景增加 `primary-row--centered`；
- 主按钮文案为“准备好了，开始闯关”；
- 背景页不显示资源区和可操作卡牌。

- [ ] **Step 5: 把资源移到步骤区域外**

建立：

```js
function renderOrderResources() {
  return `<section id="order-resources" class="order-resources" aria-label="本单资源">
    <div><small>截止时间</small><b>教学关卡不限时</b></div>
    <div><small>本人可投入</small><b>${state.resources.personalHours} 小时</b></div>
    <div><small>Agent 算力</small><b>${state.resources.compute} 点</b></div>
    <div><small>公司现金</small><b>¥${state.resources.cash}</b></div>
    <p>正式订单与现实世界时间同步。离开平台后，订单和 Agent 仍会继续推进。</p>
  </section>`;
}
```

资源区位于工作区上方、任务步骤面板之外。删除原 `.resource-pills` 中的“截止剩 4 / 本人可用 2 / Agent 算力 24”。

- [ ] **Step 6: 实现第一次拖拽 Tour**

```js
function advanceTour(action) {
  if (!state.tour.active) return;
  if (state.tour.step === "drag-player" && action === "assigned-player") {
    state.tour.step = "drag-agent";
  } else if (state.tour.step === "drag-agent" && action === "assigned-agent") {
    state.tour.active = false;
  }
  persist();
  render();
}
```

Tour 的两个步骤只高亮当前卡牌和目标位置，包含“跳过教学”按钮。`assignCard()` 成功后调用 `advanceTour()`。

- [ ] **Step 7: 验证昵称恢复和 Tour**

浏览器测试补充：

```js
await page.reload();
assert.match(await page.locator('[data-slot="understand"]').textContent(), /阿禾/);
assert.equal(await page.locator("#nickname-input").count(), 0);
assert.match(await page.locator("#order-resources").textContent(), /2 小时/);
assert.match(await page.locator("#order-resources").textContent(), /24 点/);
assert.match(await page.locator("#order-resources").textContent(), /¥200/);
```

Run:

```bash
node mfu-demo/card-array-v01.browser.cjs
```

Expected: 流程通过昵称、背景和编排阶段；后续旧断言可以暂时失败。

---

### Task 4: 用可见的错误成果替换判断选择题

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: `state.resources.compute`, `state.firstRun`
- Produces: `startFirstRun()`, `completeFirstRun()`, `renderFirstRun()`, `renderInspect()`, `submitFeedback(text)`
- Produces DOM: `.draft-poster--wrong`, `#feedback-form`, `#feedback-input`

- [ ] **Step 1: 为错误成果和反馈写浏览器断言**

```js
await page.locator("#primary-action").click();
await page.waitForSelector(".draft-poster--wrong");
const wrongDraft = await page.locator(".draft-poster--wrong").textContent();
assert.match(wrongDraft, /全校同学/);
assert.match(await page.locator("#scene-content").textContent(), /目标人群：新生/);
assert.match(await page.locator("#scene-content").textContent(), /已消耗 6 点算力/);
await page.locator("#feedback-input").fill("目标人群应为刚入学的新生，请先确认必要信息。");
await page.locator("#feedback-form").getByRole("button").click();
```

- [ ] **Step 2: 运行浏览器测试并确认失败**

Expected: FAIL，找不到 `.draft-poster--wrong`。

- [ ] **Step 3: 实现首次执行**

```js
function startFirstRun() {
  if (Object.keys(state.assignments).length < actOneSlots.length) return false;
  if (!spendResource("compute", 6)) return false;
  state.firstRun = {
    status: "running",
    startedAt: Date.now(),
    completesAfterMs: 2400
  };
  persist();
  setScene("firstRun");
  return true;
}
```

`completeFirstRun()` 将状态设为 `completed-with-mismatch` 并进入 `inspect`。

- [ ] **Step 4: 可视化第一版错误成果**

第一版海报必须直接包含错误目标：

```html
<article class="draft-poster draft-poster--wrong">
  <small>旧书换新主人 · 校园推广</small>
  <h2>全校同学都来淘旧书</h2>
  <p>覆盖全校社群与所有年级</p>
</article>
```

旁边对照订单：

```text
订单要求：首先触达刚入学的新生
Agent 成果：面向全校所有年级
影响：下游会根据错误人群继续制作和投放
本次消耗：6 点算力
```

- [ ] **Step 5: 实现可编辑反馈**

```js
function submitFeedback(text) {
  const clean = String(text || "").trim().slice(0, 240);
  if (!clean) return false;
  state.feedback = clean;
  persist();
  setScene("tune");
  return true;
}
```

反馈框提供建议文本，但允许玩家编辑。删除 `ambiguityChoices`、`chooseAmbiguity()` 和全部三选一界面。

- [ ] **Step 6: 验证刷新恢复**

在 `inspect` 刷新后仍应看到错误海报、剩余 `18` 点算力和已经填写的反馈（若已保存）。

Run:

```bash
node mfu-demo/card-array-v01.browser.cjs
```

Expected: 新流程通过 `inspect`，后续调教断言尚可失败。

---

### Task 5: 实现付费 Form、守则输入与真实 Form 调用

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: `state.resources`, `state.agent`, `state.feedback`
- Produces: `purchaseFormTool()`, `saveAgentRule(rule)`, `submitClarificationForm(answers)`
- Produces DOM: `#buy-form-tool`, `#agent-rule-form`, `#agent-rule-input`, `#clarification-form`

- [ ] **Step 1: 为调教资源变化写浏览器断言**

```js
assert.match(await page.locator("#scene-title").textContent(), /调教 Agent/);
assert.match(await page.locator("#order-resources").textContent(), /¥200/);
await page.locator("#buy-form-tool").click();
assert.match(await page.locator("#order-resources").textContent(), /¥120/);
await page.locator("#agent-rule-input").fill("缺少必要信息时，先用 Form 向我确认");
await page.locator("#agent-rule-form").getByRole("button").click();
assert.match(await page.locator("#order-resources").textContent(), /1 小时/);
```

- [ ] **Step 2: 运行测试并确认失败**

Expected: FAIL，找不到 `#buy-form-tool`。

- [ ] **Step 3: 实现 Form 购买**

```js
function purchaseFormTool() {
  if (state.agent.formInstalled) return true;
  if (!spendResource("cash", 80)) return false;
  state.agent.formInstalled = true;
  persist();
  render();
  return true;
}
```

购买按钮文案：

> 购买并安装 · ¥80

购买前显示“工具负责收集信息；守则决定什么时候调用”。购买后按钮变为“已安装”，不得重复扣款。

- [ ] **Step 4: 实现玩家输入守则**

```js
function saveAgentRule(rule) {
  const clean = String(rule || "").trim().slice(0, 160);
  if (!state.agent.formInstalled || !clean) return false;
  if (!state.agent.rule && !spendResource("personalHours", 1)) return false;
  state.agent.rule = clean;
  persist();
  setScene("clarify");
  return true;
}
```

文本框预填：

> 缺少必要信息时，先用 Form 向我确认

玩家可以编辑；首次保存扣除 1 小时，刷新或重复保存不得再次扣除。

- [ ] **Step 5: 呈现平台内 Form**

```html
<form id="clarification-form" class="tool-form">
  <span class="tool-badge">小角调用了 Form</span>
  <label>本次推广首先面向谁？</label>
  <select name="audience">
    <option value="">请选择</option>
    <option value="freshmen">刚入学的新生</option>
    <option value="all">全校所有年级</option>
  </select>
  <label>最希望用户采取什么行动？</label>
  <input name="action" placeholder="例如：到店完成第一次购买">
  <button type="submit">提交给小角</button>
</form>
```

- [ ] **Step 6: 保存 Form 答案并开始第二次执行**

```js
function submitClarificationForm(answers) {
  const audience = String(answers.audience || "");
  const action = String(answers.action || "").trim().slice(0, 120);
  if (!audience || !action) return false;
  state.formAnswers = {audience, action};
  persist();
  startSecondRun();
  return true;
}
```

`startSecondRun()` 再消耗 `6` 点算力；如果算力不足则显示明确错误并停留，不静默前进。

- [ ] **Step 7: 验证调教刷新和防重复扣款**

购买后刷新，现金仍为 ¥120；守则保存后刷新，本人时间仍为 1 小时；再次进入调教页不会再次扣款。

Run:

```bash
node mfu-demo/card-array-v01.browser.cjs
```

Expected: 调教与 Form 提交流程 PASS。

---

### Task 6: 步骤交付、完整订单路线与统一结算

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: `state.secondRun`, `state.formAnswers`, `state.agent`
- Produces: `startSecondRun()`, `completePlayerStep()`, `completeWholeOrder()`
- Produces DOM: `.draft-poster--correct`, `#whole-order-route`, `.settlement-sheet`

- [ ] **Step 1: 为正确成果和两阶段完成状态写浏览器断言**

```js
await page.waitForSelector(".draft-poster--correct");
assert.match(await page.locator(".draft-poster--correct").textContent(), /新生/);
assert.match(await page.locator("#scene-title").textContent(), /你的成果已交付/);
const routeBefore = await page.locator("#whole-order-route").textContent();
assert.match(routeBefore, /内容表达.*进行中/s);
assert.match(routeBefore, /整合交付.*等待中/s);
assert.match(await page.locator("#scene-content").textContent(), /完整订单仍在进行/);
await page.locator("#primary-action").click();
assert.match(await page.locator("#scene-title").textContent(), /完整订单已完成/);
```

- [ ] **Step 2: 实现第二次执行和正确成果**

```js
function startSecondRun() {
  if (!state.agent.formInstalled || !state.agent.rule || !state.formAnswers.audience) return false;
  if (!spendResource("compute", 6)) return false;
  state.secondRun = {
    status: "running",
    startedAt: Date.now(),
    completesAfterMs: 2400
  };
  persist();
  setScene("secondRun");
  return true;
}

function completePlayerStep() {
  state.secondRun.status = "completed";
  state.agent.ruleVerified = true;
  state.playerStepStatus = "delivered";
  persist();
  setScene("stepDelivered");
}
```

正确海报使用 Form 答案，至少清楚显示“新生”和目标行动。

- [ ] **Step 3: 显示完整订单路线**

```html
<div id="whole-order-route" class="order-route">
  <div class="done">用户洞察 <b>✓</b></div>
  <div class="done">视觉方案 <b>✓</b></div>
  <div class="working">内容表达 <b>进行中</b></div>
  <div class="done mine">你的增长验证 <b>✓</b></div>
  <div class="waiting">整合交付 <b>等待中</b></div>
</div>
```

标题固定为“你的成果已交付”，正文固定包含“你的步骤已经完成，但完整订单仍在进行”。

- [ ] **Step 4: 完成整单并进入结算**

```js
function completeWholeOrder() {
  state.wholeOrderStatus = "completed";
  persist();
  setScene("settlement");
}
```

Demo 中可以由“查看完整订单结果”按钮推进，不使用真实倒计时。

- [ ] **Step 5: 建立结算单**

`.settlement-sheet` 显示：

```text
完整订单：旧书店开学推广 ✓
你的贡献：增长验证素材与目标人群确认
客户反馈：目标清楚，成果已进入最终推广包
本人时间：使用 1 / 2 小时
Agent 算力：使用 12 / 24 点
公司现金：使用 ¥80，剩余 ¥120
小角新增工具：Form
小角新增守则：玩家实际填写的文本
验证结果：本次重试已成功避免同类误解
```

同时可视化完整订单最终交付物，但不展示邀请伙伴或建立组织。

主要按钮：“领取第一份自由订单”；次要按钮：“重新体验教学”。

- [ ] **Step 6: 删除第二幕遗留**

删除：

- `actTwoSlots`；
- `paper`、`tail` 真人卡牌；
- `inviteHunter()`、`simulateAcceptance()`、`upgradeAgent()`；
- `invite`、`build2`、`result2` 场景；
- “第一幕 / 第二幕”顶部标签；
- 邀请、组织阵列和第二份完整订单的 CSS / HTML / JS 死代码。

- [ ] **Step 7: 运行静态、语法和浏览器测试**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
perl -0777 -ne 'print $1 if /<script>(.*?)<\/script>/s' \
  mfu-demo/MFU-协作阵列-v0.1-可玩原型.html > /tmp/mfu-hunter-v03.js
node --check /tmp/mfu-hunter-v03.js
node mfu-demo/card-array-v01.browser.cjs
```

Expected: 三项全部 exit 0。

---

### Task 7: 恢复、无障碍和桌面视觉回归

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Consumes: 全部 v0.3 场景和持久状态
- Produces: 完整刷新恢复、键盘备用操作、桌面无横向溢出

- [ ] **Step 1: 为关键恢复点增加测试**

至少覆盖：

```js
// nickname/build
// inspect: firstRun + compute 18
// tune: formInstalled + cash 120
// clarify: rule + personalHours 1
// stepDelivered: player done but whole order in progress
// settlement: ruleVerified + whole order complete
```

每个恢复点都通过写入 `localStorage` 后 `page.reload()` 验证，不依赖页面内存状态。

- [ ] **Step 2: 保留非拖拽备用操作**

确认以下路径仍存在：

```text
点击卡牌
→ 点击任务位置
→ 卡牌完成放置
```

任务位置支持 Enter / Space；Tour 不阻断键盘操作；昵称、反馈、守则和 Form 都有显式 `<label>`。

- [ ] **Step 3: 检查所有 v0.3 场景桌面溢出**

```js
for (const viewport of [
  {width: 1280, height: 800},
  {width: 1440, height: 900}
]) {
  await page.setViewportSize(viewport);
  for (const scene of [
    "welcome", "briefing", "build", "firstRun", "inspect",
    "tune", "clarify", "secondRun", "stepDelivered", "settlement"
  ]) {
    await page.goto(`${demoUrl}?scene=${scene}`);
    await assertNoHorizontalOverflow(page, `${viewport.width}:${scene}`);
  }
}
```

本轮不处理移动端。

- [ ] **Step 4: 清理旧文案和死代码**

Run:

```bash
rg -n "第二幕|邀请长期合作|让 Agent 自行继续|由本人确认|询问上游猎人|小价值进入" \
  mfu-demo/MFU-协作阵列-v0.1-可玩原型.html \
  mfu-demo/test-card-array-v01.mjs \
  mfu-demo/card-array-v01.browser.cjs
```

Expected: 无匹配。

- [ ] **Step 5: 完整验证**

Run:

```bash
git diff --check
node mfu-demo/test-card-array-v01.mjs
perl -0777 -ne 'print $1 if /<script>(.*?)<\/script>/s' \
  mfu-demo/MFU-协作阵列-v0.1-可玩原型.html > /tmp/mfu-hunter-v03.js
node --check /tmp/mfu-hunter-v03.js
node mfu-demo/card-array-v01.browser.cjs
mix precommit
```

Expected:

- 文档、静态契约、JavaScript 语法和浏览器流程全部通过；
- `mix precommit` 若仍因当前 worktree 缺少既有 Hex / Phoenix 依赖而无法启动，记录完整阻塞，不为静态 Demo 临时更改依赖。

- [ ] **Step 6: 人工试玩检查**

使用一个全新浏览器存储完成一次 5–8 分钟流程，确认：

- 不需要解释“小满是谁”；
- 背景按钮醒目；
- 第一次拖拽有清晰提示；
- 错误海报的错误可被肉眼看出；
- 玩家理解算力为什么被浪费；
- Form 购买和守则输入都是真实操作；
- 步骤交付与整单结算的边界清楚；
- 首关结束前没有出现组织或拆单概念。

- [ ] **Step 7: 请求 ruihua 试玩**

提供可直接打开的 HTML 链接，并说明本轮重点观察：

```text
1. 是否理解自己是谁；
2. 是否会第一次拖拽；
3. 是否看懂错误成果；
4. 是否理解调教 Agent 的资源成本；
5. 是否理解自己的步骤与完整订单是两个完成状态。
```

- [ ] **Step 8: ruihua 确认后再提交与推送**

Suggested commit:

```text
feat(mfu): focus first tutorial on hunter delivery
```

---

## Completion Gate

只有以下条件同时满足，本计划才算完成：

- 两份 living doc 已同步；
- v0.3 首关从昵称输入一直可玩到整单结算；
- 首次错误、付费 Form、守则输入、Form 调用和正确重试全部真实发生；
- 第二幕和组织教学已从首关删除；
- 静态契约、`node --check` 和 Playwright 全部通过；
- ruihua 已完成试玩并确认；
- 获得 ruihua 明确许可后才 commit / push。
