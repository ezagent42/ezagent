import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("../demo/MFU-MVO孵化总览-v0.1-可玩原型.html", import.meta.url);
assert.ok(fs.existsSync(file), "MVO incubator prototype HTML must exist");

const html = fs.readFileSync(file, "utf8");

for (const id of [
  "incubator-dashboard",
  "resource-inventory",
  "opportunity-board",
  "mvo-portfolio",
  "mvo-running",
  "incubate-three",
  "create-mvo"
]) {
  assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);
}

for (const phrase of [
  "12 名学生",
  "6 个可运行的 MVO",
  "再孵化 3 个 MVO",
  "可以创造什么",
  "正在运行",
  "认证 MVO",
  "校园增长 MVO",
  "短视频交付 MVO",
  "用户研究 MVO"
]) {
  assert.ok(html.includes(phrase), `missing MVO overview copy: ${phrase}`);
}

for (const token of [
  "incubateRecommendedMvos",
  "confirmIncubation",
  "advanceMvos",
  "openMvoDetail",
  "resetDemo",
  "openMvoBuilder",
  "addBuilderNode",
  "startBuilderLink",
  "validateBuilder",
  "saveBuilderMvo",
  "localStorage",
  "prefers-reduced-motion"
]) {
  assert.ok(html.includes(token), `missing MVO interaction: ${token}`);
}

for (const graphType of ["linear", "fork", "merge", "hub", "loop"]) {
  assert.ok(html.includes(`graphType:"${graphType}"`), `missing ${graphType} organization graph`);
}

for (const id of [
  "mvo-builder-overlay",
  "org-builder-canvas",
  "builder-add-node",
  "builder-connect",
  "builder-validate",
  "builder-save"
]) {
  assert.ok(html.includes(`id="${id}"`), `missing MVO builder contract #${id}`);
}

const inlineScripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
assert.equal(inlineScripts.length, 1, "prototype must contain exactly one inline script");

console.log("MFU MVO incubator v0.1 static contract passed");
