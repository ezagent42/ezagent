import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("./MFU-MVO组织牧场-v0.2-可玩原型.html", import.meta.url);
assert.ok(fs.existsSync(file), "organization pasture v0.2 must exist");
const html = fs.readFileSync(file, "utf8");

for (const id of [
  "pasture-game",
  "todo-sidebar",
  "organization-pasture",
  "action-sidebar",
  "inventory-dock",
  "inventory-toggle",
  "office-tab",
  "pasture-tab",
  "open-erp",
  "open-workshop"
]) assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);

for (const id of [
  "workshop-overlay",
  "org-builder-canvas",
  "builder-add-node",
  "builder-connect",
  "save-workshop-mvo"
]) assert.ok(html.includes(`id="${id}"`), `missing full workshop #${id}`);

for (const phrase of [
  "孵化中的组织",
  "订单板",
  "待处理",
  "资源栏",
  "分配已选订单",
  "待验收",
  "可升级"
]) assert.ok(html.includes(phrase), `missing game copy: ${phrase}`);

for (const phrase of [
  "办公室",
  "组织图工坊",
  "人才",
  "Agent",
  "工具",
  "IP / 数据",
  "孵化器 ERP",
  "进行中的项目",
  "官网",
  "喂范例",
  "写守则",
  "复盘"
]) assert.ok(html.includes(phrase), `missing playable system copy: ${phrase}`);

assert.ok(!html.includes("12 名学生 → 6 个可运行的 MVO"), "pitch outcome must not appear in game UI");

for (const fn of [
  "selectTask",
  "assignTask",
  "advanceWork",
  "acceptDelivery",
  "toggleInventory",
  "openOrganization",
  "setCenterTab",
  "openWorkshop",
  "saveWorkshopMvo",
  "setResourceTab",
  "openResource",
  "trainAgent",
  "openErp",
  "setErpTab"
]) assert.ok(html.includes(fn), `missing interaction ${fn}`);

for (const fn of [
  "addBuilderNode",
  "toggleBuilderConnect",
  "selectBuilderNode",
  "renderBuilderCanvas"
]) assert.ok(html.includes(fn), `missing workshop interaction ${fn}`);

for (const fn of [
  "openOrgTab",
  "sendOrgChat",
  "subcontractTask",
  "rejectDelivery",
  "resolveRisk"
]) assert.ok(html.includes(fn), `missing migrated MVO interaction ${fn}`);

for (const fn of [
  "openResourceMarket",
  "buyResource",
  "buyCoachTime",
  "postTask"
]) assert.ok(html.includes(fn), `missing migrated incubator interaction ${fn}`);

console.log("MFU organization pasture v0.2 static contract passed");
