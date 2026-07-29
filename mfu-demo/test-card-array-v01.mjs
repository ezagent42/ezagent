import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("./MFU-协作阵列-v0.1-可玩原型.html", import.meta.url);
assert.ok(fs.existsSync(file), "prototype HTML must exist");

const html = fs.readFileSync(file, "utf8");

for (const id of ["app", "scene-title", "scene-content", "primary-action"]) {
  assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);
}

for (const phrase of ["大项目中的一步", "主动连接", "正式平台需真人确认"]) {
  assert.ok(html.includes(phrase), `missing copy: ${phrase}`);
}

for (const token of [
  "data-card",
  "data-slot",
  "data-relation",
  "assignCard",
  "selectCard",
  "setRelation",
  "getEstimate",
  "runArray",
  "saveDraft",
  "clearAssignments",
  "removeAssignment",
  "startExecution",
  "executionProgress",
  "resumeExecution",
  "renderRunning",
  "retryActOne",
  "upgradeAgent",
  "chooseAmbiguity",
  "buildResultOne",
  "inviteHunter",
  "simulateAcceptance"
]) {
  assert.ok(html.includes(token), `missing interaction token: ${token}`);
}

for (const phrase of [
  "让 Agent 自行继续",
  "由本人确认",
  "询问上游猎人",
  "上一单，你完成了大项目中的一步",
  "这一单，你连接了三个人",
  "纸飞机",
  "长尾巴",
  "小角",
  "旧书换新主人",
  "校园群首轮点击率",
  "客户可直接使用",
  "准备好了，开始闯关",
  "暂存编排",
  "清空编排",
  "教学订单，不消耗真实信用",
  "确认编排，让 Agent 开始执行",
  "可以暂时离开",
  "需求不清时暂停并提醒主人",
  "串行",
  "并行",
  "检查"
]) {
  assert.ok(html.includes(phrase), `missing final copy: ${phrase}`);
}

assert.ok(!html.includes("总战力"), "must not expose total power");

const inlineScripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
assert.equal(inlineScripts.length, 1, "prototype must contain exactly one inline script");

console.log("MFU card-array v0.1 static contract passed");
