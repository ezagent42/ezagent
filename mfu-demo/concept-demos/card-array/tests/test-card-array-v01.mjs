import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("../demo/MFU-协作阵列-v0.1-可玩原型.html", import.meta.url);
assert.ok(fs.existsSync(file), "prototype HTML must exist");

const html = fs.readFileSync(file, "utf8");

for (const id of ["app", "scene-title", "scene-content", "primary-action"]) {
  assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);
}

for (const phrase of [
  "输入你的昵称",
  "准备好了，开始闯关",
  "教学关卡不限时",
  "正式订单与现实世界时间同步",
  "公司现金",
  "调教 Agent",
  "Form 工具",
  "购买并安装 Form · ¥80",
  "缺少必要信息时，先用 Form 向我确认",
  "你的成果已交付",
  "完整订单仍在进行",
  "完整订单已完成",
  "领取第一份自由订单",
  "这是你现在可以编排的角色",
  "把角色卡牌拖到任务的某一个环节",
  "创业教练提示",
  "🍱 喂范例",
  "📏 写守则",
  "🔍 复盘",
  "🧰 安装工具"
]) {
  assert.ok(html.includes(phrase), `missing v0.3 copy: ${phrase}`);
}

for (const expectedText of [
  "data-card",
  "data-slot",
  "assignCard",
  "selectCard",
  "getEstimate",
  "saveDraft",
  "clearAssignments",
  "removeAssignment",
  "saveNickname",
  "spendResource",
  "startFirstRun",
  "completeFirstRun",
  "submitFeedback",
  "purchaseFormTool",
  "saveAgentRule",
  "submitClarificationForm",
  "startSecondRun",
  "completePlayerStep",
  "completeWholeOrder",
  "renderOrderResources",
  "renderTour",
  "acknowledgeRoleTour",
  "dismissDragGhost",
  "coachAdvice",
  "selectTrainingMethod"
]) {
  assert.ok(html.includes(expectedText), `missing v0.3 interaction: ${expectedText}`);
}

for (const removed of [
  "第二幕：用连接组成一个新组织",
  "邀请长期合作",
  "让 Agent 自行继续",
  "询问上游猎人",
  "你当前拥有的角色卡牌",
  "当前目标",
  "分工评价",
  "资源评价",
  "改进评价"
]) {
  assert.ok(!html.includes(removed), `removed first-tutorial content remains: ${removed}`);
}

assert.ok(!html.includes("总战力"), "must not expose total power");

const inlineScripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
assert.equal(inlineScripts.length, 1, "prototype must contain exactly one inline script");

console.log("MFU hunter tutorial v0.3 static contract passed");
