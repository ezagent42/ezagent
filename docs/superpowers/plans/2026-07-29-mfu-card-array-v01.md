# MFU 协作卡牌阵列 v0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建一个 5–8 分钟可独立玩完的单文件 HTML，让不了解 MFU 的体验者亲手经历“被动加入大项目 → 主动连接真人 → 组成更大阵列”。

**Architecture:** 新建独立单文件原型，不修改 v0.15。页面由一个轻量状态机驱动六个连续场景；卡牌、任务槽、连接和结果均由同一份 JavaScript 状态渲染。另建一个 Node 验证脚本，检查页面结构、关键文案、核心函数、按钮死链和内嵌脚本语法。

**Tech Stack:** 单文件 HTML、CSS、原生 JavaScript、HTML Drag and Drop API、Node.js 静态验证。

## Global Constraints

- 唯一产品文件为 `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`，浏览器直接打开即可运行。
- 不修改 `mfu-demo/MFU-v0.15-可试玩原型.html`。
- 沿用 `.claude/skills/mfu-design-system/SKILL.md` 的羊皮纸、纸卡、印章和语义色。
- 只面向桌面端；常用桌面尺寸无横向滚动。
- 拖放和点击选择必须都能完成组阵。
- 第一幕只有本人“小满”和 Agent“小角”；第二幕加入模拟接受邀请的真人猎人“纸飞机”和“长尾巴”。
- 真人卡必须显示“需要本人接受”；Demo 自动接受时必须显示“正式平台需真人确认”。
- 阵列关系只包含串行、并行、检查三种。
- 只设置一次执行中歧义决策。
- 结果必须可解释，不使用总战力或单一总分。
- 不加入现金流、商店、认证、成长树、孵化器工作台、真实 AI 或多人服务。
- 每次 git commit / push 前必须先获得 ruihua 明确授权。

---

### Task 1: 六场景壳层与第一幕任务上下文

**Files:**
- Create: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Create: `mfu-demo/test-card-array-v01.mjs`

**Interfaces:**
- Produces: `state.scene: "match" | "context" | "build1" | "event" | "result1" | "invite" | "build2" | "result2"`
- Produces: `setScene(sceneName)`、`render()`、`resetDemo()`
- Produces: DOM anchors `#app`、`#scene-title`、`#scene-content`、`#primary-action`

- [x] **Step 1: 写静态契约测试**

在 `test-card-array-v01.mjs` 中读取 HTML，并断言：

```js
import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("./MFU-协作阵列-v0.1-可玩原型.html", import.meta.url);
const html = fs.readFileSync(file, "utf8");

for (const id of ["app", "scene-title", "scene-content", "primary-action"]) {
  assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);
}
for (const phrase of ["大项目中的一步", "主动连接", "正式平台需真人确认"]) {
  assert.ok(html.includes(phrase), `missing copy: ${phrase}`);
}
```

- [x] **Step 2: 运行测试并确认首次失败**

Run: `node mfu-demo/test-card-array-v01.mjs`
Expected: FAIL，提示目标 HTML 不存在。

- [x] **Step 3: 建立单文件壳层**

HTML 必须包含：

```html
<main id="app" class="app-shell">
  <header class="topbar">...</header>
  <section class="stage">
    <h1 id="scene-title"></h1>
    <div id="scene-content"></div>
    <button id="primary-action" class="btn btn-primary"></button>
  </section>
</main>
```

JavaScript 必须以显式状态驱动：

```js
const state = {
  scene: "match",
  act: 1,
  assignments: {},
  relation: "serial",
  ambiguityChoice: null,
  invited: [],
  accepted: []
};

function setScene(sceneName) {
  state.scene = sceneName;
  render();
}

function resetDemo() {
  localStorage.removeItem("mfu-card-array-v01");
  location.reload();
}
```

- [x] **Step 4: 实现“匹配进入大项目”和“查看完整位置”**

完整项目阵列固定展示五个位置：

```js
const projectSteps = [
  ["用户洞察", "阿青"],
  ["视觉方案", "纸飞机"],
  ["内容表达", "长尾巴"],
  ["增长验证", "我 · 小满"],
  ["整合交付", "北辰"]
];
```

小满节点必须高亮，并显示：

> 你不需要完成整个项目。先把“增长验证”这一步做好。

- [x] **Step 5: 运行契约测试和脚本语法检查**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
perl -0777 -ne 'print $1 if /<script>(.*?)<\/script>/s' mfu-demo/MFU-协作阵列-v0.1-可玩原型.html > /tmp/mfu-card-array-v01.js
node --check /tmp/mfu-card-array-v01.js
```

Expected: 两条命令均 exit 0。

---

### Task 2: 半开放任务棋盘与双输入方式

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`

**Interfaces:**
- Consumes: `state.assignments`、`state.relation`、`render()`
- Produces: `assignCard(cardId, slotId)`、`selectCard(cardId)`、`setRelation(relation)`
- Produces: `getEstimate(): {time: number, compute: number, risk: string[]}`
- Produces: DOM data attributes `[data-card]`、`[data-slot]`、`[data-relation]`

- [x] **Step 1: 扩充静态契约测试**

```js
for (const token of [
  "data-card", "data-slot", "data-relation",
  "assignCard", "selectCard", "setRelation", "getEstimate"
]) {
  assert.ok(html.includes(token), `missing interaction token: ${token}`);
}
for (const relation of ["serial", "parallel", "review"]) {
  assert.ok(html.includes(relation), `missing relation: ${relation}`);
}
```

- [x] **Step 2: 实现第一幕三格任务棋盘**

任务槽固定为：

```js
const actOneSlots = [
  {id: "understand", title: "理解实验目标", needs: "判断", output: "实验目标"},
  {id: "make", title: "制作实验素材", needs: "执行", output: "三版素材"},
  {id: "check", title: "检查并提交", needs: "判断", output: "可交付版本"}
];
```

可用卡固定为：

```js
const cards = {
  player: {name: "小满", kind: "本人", time: 1, skills: ["客户理解", "最终判断"]},
  agent: {name: "小角", kind: "Agent", compute: 12, skills: ["快速制作", "版本整理"]}
};
```

- [x] **Step 3: 实现拖放与点击选择**

拖放路径：

```js
card.addEventListener("dragstart", event => {
  event.dataTransfer.setData("text/card-id", card.dataset.card);
});
slot.addEventListener("drop", event => {
  event.preventDefault();
  assignCard(event.dataTransfer.getData("text/card-id"), slot.dataset.slot);
});
```

点击路径：

```js
function selectCard(cardId) {
  state.selectedCard = state.selectedCard === cardId ? null : cardId;
  render();
}
```

点击任务槽时，若 `state.selectedCard` 存在，则调用 `assignCard`。

- [x] **Step 4: 实现三种连接和实时预估**

连接按钮只允许：

```js
const relations = {
  serial: "先做，再交给下一位",
  parallel: "同时开始，最后汇总",
  review: "执行完成后，由下一位检查"
};
```

`getEstimate()` 必须根据卡牌重复使用和连接关系返回时间、算力和风险文本；右栏不能显示单一总分。

- [x] **Step 5: 验证核心操作**

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
node --check /tmp/mfu-card-array-v01.js
```

Manual:

- 卡牌可拖入三格；
- 选择卡后点击任务格也可放入；
- 切换三种连接时，时间、算力或风险至少一项发生变化；
- 未填满三个位置时，“开始执行”不可用。

---

### Task 3: 执行事件、结果单与主动邀请

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`

**Interfaces:**
- Consumes: 第一幕 `state.assignments`、`state.relation`
- Produces: `runArray()`、`chooseAmbiguity(choice)`、`buildResultOne()`
- Produces: `inviteHunter(hunterId)`、`simulateAcceptance(hunterId)`
- Produces: `state.ambiguityChoice`、`state.invited`、`state.accepted`

- [x] **Step 1: 增加事件与邀请契约测试**

```js
for (const token of [
  "runArray", "chooseAmbiguity", "buildResultOne",
  "inviteHunter", "simulateAcceptance",
  "让 Agent 自行继续", "由本人确认", "询问上游猎人"
]) {
  assert.ok(html.includes(token), `missing event token: ${token}`);
}
```

- [x] **Step 2: 实现一次执行中歧义**

固定事件：

> 客户写了“面向校园用户”，但没有说明是新生还是全校学生。Agent 正在等待下一步。

三种选择：

```js
const ambiguityChoices = {
  agent: {label: "让 Agent 自行继续", effect: "更快，但可能偏离客户目标"},
  self: {label: "由本人确认", effect: "消耗 1 时间，避免方向错误"},
  upstream: {label: "询问上游猎人", effect: "等待回复，获得完整背景"}
};
```

- [x] **Step 3: 生成可解释结果单**

`buildResultOne()` 返回：

```js
{
  artifact: "校园旧书推广实验包",
  goal: "部分解决",
  timing: "按时 / 晚 1 天",
  resource: "时间与算力明细",
  rework: "发生位置或无",
  responsibility: "关键判断由谁作出",
  explanation: "卡牌与连接如何导致结果",
  feedback: "客户或拆单方的具体反馈"
}
```

不允许返回 `score`、`power` 或 `战力` 字段。

- [x] **Step 4: 实现真人邀请与模拟接受**

邀请对象固定为：

```js
const hunters = {
  paper: {name: "纸飞机", role: "视觉猎人"},
  tail: {name: "长尾巴", role: "内容猎人"}
};
```

点击邀请后先显示“等待本人接受”，再通过短暂动画进入“已接受”。接受区必须持续显示：

> Demo 中由系统模拟接受；正式平台需真人确认。

- [x] **Step 5: 验证不同选择产生不同反馈**

Manual:

- 三种歧义选择分别产生不同的时间、风险或反馈；
- 结果单能指出影响结果的卡牌或连接；
- 两名猎人均需分别点击邀请；
- 两人接受后才能进入第二幕。

---

### Task 4: 第二幕完整订单、结尾与交付验收

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/doc/core-gameplay-card-array.md`

**Interfaces:**
- Consumes: `state.accepted`、Task 2 的棋盘函数
- Produces: `actTwoSlots`、`buildResultTwo()`、最终总结场景
- Produces: URL query `?scene=` 供逐场景视觉检查

- [x] **Step 1: 实现第二幕卡组和任务**

第二幕完整订单使用三名真人猎人：

```js
const actTwoSlots = [
  {id: "visual", title: "视觉表达", recommended: "paper"},
  {id: "content", title: "内容表达", recommended: "tail"},
  {id: "validate", title: "增长验证与总负责", recommended: "player"}
];
```

小满所在位置可以继续展开本人 + Agent 的内部安排，但第一版只用一个简洁展开层，不同时展示更多嵌套阵列。

- [x] **Step 2: 复用棋盘完成第二次组阵**

第二幕允许“纸飞机”“长尾巴”“小满”三张真人卡；小角只出现在小满卡的展开区。玩家必须亲手把三张卡放入任务位置后才能执行。

- [x] **Step 3: 生成完整交付与身份变化**

结果页必须展示：

- 一份可见的完整交付物缩略预览；
- 三名猎人分别贡献了什么；
- 本人和 Agent 在“小满”内部如何分工；
- 哪条连接经过了本次验证；
- 最终句：

> 上一单，你完成了大项目中的一步；这一单，你连接了三个人，共同完成了一份完整订单。

- [x] **Step 4: 补齐无障碍与视觉约束**

- 所有按钮有可见焦点；
- 拖放区域同时可点击；
- `prefers-reduced-motion` 下关闭非必要动画；
- 正文不小于 9.5px；
- 删除至少一个不服务理解的装饰元素；
- 1440×900 与 1280×800 下无横向滚动。

- [x] **Step 5: 扩充并运行最终契约测试**

最终测试增加：

```js
for (const phrase of [
  "上一单，你完成了大项目中的一步",
  "这一单，你连接了三个人",
  "纸飞机", "长尾巴", "小角",
  "串行", "并行", "检查"
]) {
  assert.ok(html.includes(phrase), `missing final copy: ${phrase}`);
}
assert.ok(!html.includes("总战力"), "must not expose total power");
```

Run:

```bash
node mfu-demo/test-card-array-v01.mjs
perl -0777 -ne 'print $1 if /<script>(.*?)<\/script>/s' mfu-demo/MFU-协作阵列-v0.1-可玩原型.html > /tmp/mfu-card-array-v01.js
node --check /tmp/mfu-card-array-v01.js
git diff --check
```

Expected: 全部 exit 0。

- [x] **Step 6: 浏览器逐场景验证**

使用 `?scene=match`、`?scene=build1`、`?scene=event`、`?scene=result1`、`?scene=invite`、`?scene=build2`、`?scene=result2` 截图检查。

人工走完两条路径：

1. 本人确认歧义 → 按时、高质量结果；
2. Agent 自行判断 → 更快但发生方向偏差，结果单能解释原因。

- [x] **Step 7: 同步设计文档实现状态**

在 `core-gameplay-card-array.md` 顶部把状态从“待实现”更新为“v0.1 已实现，待试玩”，并附上原型路径和验证命令。

- [x] **Step 8: 准备提交但不自行提交**

运行：

```bash
git status --short
git diff --stat
git diff --check
```

向 ruihua 汇报目标文件、验证结果和建议提交信息；获得明确授权后再 commit / push。
