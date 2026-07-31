# MFU 首个教学订单 v0.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把协作阵列原型改造成玩家进入 MFU 后可以独立完成、离开并恢复的首个教学订单。

**Architecture:** 继续维护单文件原型，以有限状态机驱动“背景—编排—执行—判断—结果—升级—邀请—第二幕”。持久状态写入 `localStorage`，执行开始时间使用真实时间戳；页面恢复时根据已过去的毫秒数计算进度，并在人工判断节点停止。现有 Node 静态契约和浏览器流程测试同步扩展。

**Tech Stack:** 单文件 HTML/CSS/原生 JavaScript、LocalStorage、真实时间戳、Node.js、Playwright。

## Global Constraints

- 不修改 MFU v0.15。
- 第一页不显示可操作卡牌、连接选择或完整资源面板。
- 点击“准备好了，开始闯关”后进入独立编排页。
- 第一轮只开放串行；结果后开放检查；第二幕开放并行。
- 教学订单不消耗真实信用，可重试。
- 暂存、刷新和关闭页面后可以恢复。
- Agent 执行到歧义节点必须暂停等待人判断。
- 首次升级只增加“小角：需求不清时暂停并提醒主人”。
- 保留邀请上下游、三人阵列和最终交付包。
- commit / push 前必须先询问 ruihua。

---

### Task 1: 关卡背景与独立编排

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Produces: scenes `briefing`、`build1`
- Produces: `saveDraft()`、`clearAssignments()`、`removeAssignment(slotId)`
- Produces: persisted `assignments` and `relations`

- [x] **Step 1:** 扩展静态测试，要求出现“准备好了，开始闯关”“暂存编排”“清空编排”“教学订单，不消耗真实信用”。
- [x] **Step 2:** 运行静态测试，确认因缺少新文案而失败。
- [x] **Step 3:** 新增只含订单委托书、四项背景和只读项目链的 `briefing` 首屏。
- [x] **Step 4:** 恢复独立 `build1` 页面，不在棋盘上方重复完整项目链。
- [x] **Step 5:** 实现暂存、拿回单格卡牌、覆盖卡牌和清空编排。
- [x] **Step 6:** 第一轮隐藏并行和检查按钮，只显示“串行 · 先做，再交给下一位”。
- [x] **Step 7:** 浏览器测试确认首屏无 `[data-card]`，点击主按钮后才出现卡牌。

### Task 2: 真实时间驱动的离线执行

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/card-array-v01.browser.cjs`

**Interfaces:**
- Produces: scene `running`
- Produces: `startExecution()`、`executionProgress(now)`、`resumeExecution()`、`renderRunning()`
- Produces: persisted `execution: {startedAt, durationMs, decisionAtMs, status}`

- [x] **Step 1:** 扩展静态测试，要求执行时间戳、进度计算和恢复函数。
- [x] **Step 2:** 实现“确认编排，让 Agent 开始执行”，记录真实 `Date.now()`。
- [x] **Step 3:** 执行页显示当前卡牌、进度、已耗算力、预计完成时间和“可以暂时离开”。
- [x] **Step 4:** 执行在演示用短时间后进入 `event`，状态变为 `waiting-human`。
- [x] **Step 5:** 页面初始化读取本地状态；处于执行中时根据当前时间恢复，处于判断节点时保持等待。
- [x] **Step 6:** 浏览器测试通过注入旧时间戳验证刷新恢复和判断暂停。

### Task 3: 结果重试、卡牌升级与最终回归

**Files:**
- Modify: `mfu-demo/MFU-协作阵列-v0.1-可玩原型.html`
- Modify: `mfu-demo/test-card-array-v01.mjs`
- Modify: `mfu-demo/card-array-v01.browser.cjs`
- Modify: `mfu-demo/doc/core-gameplay-card-array.md`

**Interfaces:**
- Produces: scene `upgrade`
- Produces: `retryActOne()`、`upgradeAgent()`
- Produces: persisted `agentUpgraded: boolean`

- [x] **Step 1:** 结果页增加“调整阵列，再试一次”和“复盘并升级小角”。
- [x] **Step 2:** 升级页对比升级前后，并由玩家确认新增守则。
- [x] **Step 3:** 升级后小角卡显示“需求不清时暂停并提醒主人”。
- [x] **Step 4:** 升级完成后继续原有邀请与第二幕，不新增其他成长系统。
- [x] **Step 5:** 浏览器自动走完“背景—编排—执行恢复—判断—结果—升级—邀请—第二幕”。
- [x] **Step 6:** 在 1280×800 和 1440×900 检查无横向溢出，脚本通过 `node --check`。
- [x] **Step 7:** 更新设计文档状态为“v0.2 已实现，待试玩”。
- [x] **Step 8:** 汇报改动和验证结果，等待 commit / push 授权。
