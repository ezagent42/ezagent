import fs from "node:fs";
import assert from "node:assert/strict";

const file = new URL("../demo/MFU-MVO组织牧场-v0.2-可玩原型.html", import.meta.url);
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
  "post-market-order",
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
  "trainAgent"
]) assert.ok(html.includes(fn), `missing interaction ${fn}`);

for (const removed of [
  'id="open-erp"',
  "孵化器 ERP",
  "openErp",
  "setErpTab",
  "erpTabs",
  'id="erp-overlay"'
]) assert.ok(!html.includes(removed), `standalone ERP remains: ${removed}`);

for (const fn of [
  "addBuilderNode",
  "toggleBuilderConnect",
  "selectBuilderNode",
  "renderBuilderCanvas"
]) assert.ok(html.includes(fn), `missing workshop interaction ${fn}`);

for (const fn of [
  "openOrgTab",
  "sendOrgChat",
  "rejectDelivery",
  "resolveRisk"
]) assert.ok(html.includes(fn), `missing migrated MVO interaction ${fn}`);

for (const fn of [
  "openResourceMarket",
  "buyResource",
  "buyCoachTime",
  "postTask"
]) assert.ok(html.includes(fn), `missing migrated incubator interaction ${fn}`);

for (const token of [
  "normalizeState",
  "recordLedger",
  "setOrderStatus",
  "ledger:",
  "paymentStatus",
  "assignedOrgId"
]) assert.ok(html.includes(token), `missing shared operating record: ${token}`);

for (const token of [
  "待确认",
  "待分配",
  "进行中",
  "待结算",
  "已完成",
  "setOrderFilter",
  "openOrder"
]) assert.ok(html.includes(token), `missing order lifecycle: ${token}`);

for (const token of [
  "funds-resource-view",
  "compute-resource-view",
  "待收款",
  "待付款",
  "本周利润",
  "算力消耗记录"
]) assert.ok(html.includes(token), `missing resource finance/compute feature: ${token}`);

for (const token of [
  "allResources",
  "assignResourcesToOrg",
  "releaseOrderResources",
  "calculateOrgEconomics",
  "交付",
  "经营记录",
  "成长"
]) assert.ok(html.includes(token), `missing organization operation: ${token}`);

for (const token of [
  "issueInvoice",
  "receivePayment",
  "completeSettlement",
  "addPendingAction",
  "resolvePendingAction",
  "应收款逾期",
  "即将超预算",
  "资源冲突"
]) assert.ok(html.includes(token), `missing operating loop: ${token}`);

for (const token of [
  "activeMainTab",
  "setMainTab",
  "renderMainView",
  "我的工作台",
  "世界",
  'id="main-tabs"',
  'id="workspace-view"',
  'id="world-view"'
]) assert.ok(html.includes(token), `missing main world shell: ${token}`);

for (const token of [
  "marketOrders",
  "worldFeed",
  "renderWorld",
  "acceptMarketOrder",
  "订单市场",
  "世界动态",
  "新闻与公告"
]) assert.ok(html.includes(token), `missing world market: ${token}`);

for (const token of [
  "nodeStates",
  "normalizeNodeStates",
  "projectGraphMarkup",
  "openProjectNode",
  "已完成",
  "正在运行",
  "未开始",
  "等待外部承接"
]) assert.ok(html.includes(token), `missing node execution state: ${token}`);

assert.ok(!html.includes(">📮 外包子任务</button>"), "old instant outsourcing button remains");

for (const token of [
  "openNodeOutsourceForm",
  "publishNodeOrder",
  "simulateExternalAcceptance",
  "completeExternalNodeOrders",
  "发布为订单",
  "模拟外部玩家承接"
]) assert.ok(html.includes(token), `missing node outsourcing: ${token}`);

console.log("MFU organization pasture v0.2 static contract passed");
