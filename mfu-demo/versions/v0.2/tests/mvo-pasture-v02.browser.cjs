const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {pathToFileURL} = require("node:url");
const path = require("node:path");

const demoUrl = pathToFileURL(path.join(__dirname, "../demo/MFU-MVO组织牧场-v0.2-可玩原型.html")).href;

(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});
  await page.goto(demoUrl);
  await page.evaluate(() => localStorage.clear());
  await page.reload();

  assert.equal(await page.locator("#todo-sidebar").isVisible(), true);
  assert.equal(await page.locator("#organization-pasture").isVisible(), true);
  assert.equal(await page.locator("#action-sidebar").isVisible(), true);
  assert.equal(await page.locator("#inventory-dock").isVisible(), true);
  const workspaceTabBox = await page.locator("#main-tabs").boundingBox();
  const viewportHeight = await page.evaluate(() => innerHeight);
  const gameBox = await page.locator("#pasture-game").boundingBox();
  const resourceBox = await page.locator("#inventory-dock").boundingBox();
  assert.equal(Math.round(gameBox.height), viewportHeight - 20);
  assert.equal(Math.round(resourceBox.y + resourceBox.height), viewportHeight - 10);

  const unassignedBeforeMarket = await page.locator('[data-order-filter="unassigned"]').textContent();
  await page.locator('[data-main-tab="world"]').click();
  assert.equal(await page.locator("#world-view").isVisible(), true);
  assert.equal(await page.locator("#workspace-view").isVisible(), false);
  assert.match(await page.locator("#market-orders").textContent(), /订单市场/);
  const worldTabBox = await page.locator("#main-tabs").boundingBox();
  const worldStatusBox = await page.locator(".world-status").boundingBox();
  assert.equal(Math.round(worldTabBox.x), Math.round(workspaceTabBox.x));
  assert.equal(Math.round(worldTabBox.y), Math.round(workspaceTabBox.y));
  assert.equal(Math.round(worldStatusBox.y + worldStatusBox.height), viewportHeight - 10);
  const marketCount = await page.locator("[data-market-order]").count();
  await page.locator("[data-accept-market]").first().click();
  assert.equal(await page.locator("[data-market-order]").count(), marketCount - 1);
  await page.locator("#post-market-order").click();
  await page.locator("#confirm-market-order").click();
  assert.match(await page.locator("#market-orders").textContent(), /我发布的 · 等待承接/);
  await page.locator('[data-main-tab="workspace"]').click();
  assert.equal(await page.locator("#workspace-view").isVisible(), true);
  assert.equal(await page.locator("#world-view").isVisible(), false);
  assert.notEqual(await page.locator('[data-order-filter="unassigned"]').textContent(), unassignedBeforeMarket);

  await page.locator("#office-tab").click();
  assert.equal(await page.locator("#incubator-office").isVisible(), true);
  await page.locator("#pasture-tab").click();

  await page.locator('[data-org-id="research"]').click();
  await page.locator('[data-org-tab="task"]').click();
  assert.equal(await page.locator('[data-node-status="completed"]').count() > 0, true);
  assert.equal(await page.locator('[data-node-status="running"]').count() > 0, true);
  assert.equal(await page.locator('[data-node-status="pending"]').count() > 0, true);
  await page.locator('[data-node-status="pending"]').first().click();
  await page.locator("#publish-node-order").click();
  await page.locator("#confirm-node-outsource").click();
  await page.locator('[data-main-tab="world"]').click();
  assert.match(await page.locator("#market-orders").textContent(), /用户研究 MVO/);
  await page.locator("[data-simulate-accept]").first().click();
  await page.locator("#advance-work").click();
  await page.locator('[data-main-tab="workspace"]').click();
  await page.locator('[data-org-id="research"]').click();
  await page.locator('[data-org-tab="task"]').click();
  await page.locator('[data-project-node="research-node-2"]').click();
  assert.match(await page.locator("#project-node-detail").textContent(), /远山协作 MVO/);
  await page.evaluate(() => closeOverlay());

  await page.locator('[data-org-id="growth"]').click();
  assert.equal(await page.locator("#organization-overlay").isVisible(), true);
  for (const tab of ["task", "assets", "delivery", "operations", "growth", "records", "logs", "site"]) {
    await page.locator(`[data-org-tab="${tab}"]`).click();
    assert.ok((await page.locator("#organization-body").textContent()).trim().length > 0);
  }
  await page.locator('[data-org-tab="task"]').click();
  await page.locator("#org-chat-input").fill("请确认交付接口");
  await page.locator("#send-org-chat").click();
  assert.match(await page.locator("#organization-body").textContent(), /请确认交付接口/);
  await page.locator("#close-organization").click();

  const originalOrgCount = await page.locator("[data-org-id]").count();
  await page.locator("[data-task-id]").first().click();
  assert.equal(await page.locator("#order-detail").isVisible(), true);
  assert.match(await page.locator("#order-detail").textContent(), /客户与需求/);
  await page.locator("#select-order-assignment").click();
  assert.equal(await page.locator("#todo-sidebar #open-workshop").count(), 0);
  await page.locator("#organization-pasture #open-workshop").click();
  assert.equal(await page.locator("#workshop-overlay").isVisible(), true);
  await page.locator("#builder-add-node").click();
  const step = page.locator('#org-builder-canvas [data-builder-node^="step-"]');
  await step.click();
  await page.locator('[data-workshop-resource="person-ahe"]').click();
  await page.locator('[data-workshop-resource="agent-data"]').click();
  const ids = await page.locator("[data-builder-node]").evaluateAll(nodes => {
    const values = nodes.map(node => node.dataset.builderNode);
    return ["start", values.find(id => id.startsWith("step-")), "end"];
  });
  await page.locator("#builder-connect").click();
  await page.locator(`[data-builder-node="${ids[0]}"]`).click();
  await page.locator(`[data-builder-node="${ids[1]}"]`).click();
  await page.locator("#builder-connect").click();
  await page.locator(`[data-builder-node="${ids[1]}"]`).click();
  await page.locator(`[data-builder-node="${ids[2]}"]`).click();
  await page.locator("#save-workshop-mvo").click();
  assert.equal(await page.locator("[data-org-id]").count(), originalOrgCount + 1);
  assert.match(await page.locator("#organization-pasture").textContent(), /正在执行/);
  await page.locator("#inventory-toggle").click();
  await page.locator('[data-resource-tab="people"]').click();
  await page.locator('[data-resource-id="person-ahe"]').click();
  assert.match(await page.locator(".modal-box").textContent(), /属于 .*MVO.*正在执行/);
  await page.locator("#close-resource").click();
  await page.locator("#inventory-toggle").click();

  await page.locator("#advance-work").click();
  await page.locator("#advance-work").click();
  await page.locator("#advance-work").click();
  assert.match(await page.locator("#action-sidebar").textContent(), /待验收/);
  await page.locator("[data-action-type='review']").last().click();
  await page.locator("#accept-delivery").click();
  assert.match(await page.locator("#todo-sidebar").textContent(), /待结算/);
  assert.equal(await page.locator('[data-order-filter="settlement"].on').count(), 1);
  const cashBeforeSettlement = await page.locator("#cash-stat").textContent();
  await page.locator("#todo-sidebar [data-task-id]").first().click();
  await page.locator("#issue-invoice").click();
  assert.match(await page.locator("#action-sidebar").textContent(), /待收款/);
  await page.locator("#receive-payment").click();
  assert.equal(await page.locator('[data-order-filter="completed"].on').count(), 1);
  assert.notEqual(await page.locator("#cash-stat").textContent(), cashBeforeSettlement);
  assert.match(await page.locator("#action-sidebar").textContent(), /可升级/);

  await page.locator("#inventory-toggle").click();
  assert.equal(await page.locator("#inventory-drawer").isVisible(), true);
  assert.equal(await page.locator("#inventory-drawer .resource-tabs").count(), 0);
  await page.locator('[data-resource-tab="agents"]').click();
  await page.locator('[data-resource-id="agent-insight"]').click();
  const beforeAbility = await page.locator("#agent-ability").textContent();
  await page.locator('[data-train-method="example"]').click();
  const afterAbility = await page.locator("#agent-ability").textContent();
  assert.notEqual(afterAbility, beforeAbility);
  await page.locator("#close-resource").click();

  await page.locator("#cash-shortcut").click();
  assert.equal(await page.locator("#funds-resource-view").isVisible(), true);
  assert.equal(await page.locator('[data-resource-tab="funds"].on').count(), 1);
  assert.match(await page.locator("#funds-resource-view").textContent(), /收支记录.*校园阅读节增长/s);
  const fundsDrawerHeight = await page.locator("#inventory-drawer").evaluate(node => node.getBoundingClientRect().height);
  await page.locator("#compute-shortcut").click();
  assert.equal(await page.locator("#compute-resource-view").isVisible(), true);
  assert.equal(await page.locator('[data-resource-tab="compute"].on').count(), 1);
  const computeDrawerHeight = await page.locator("#inventory-drawer").evaluate(node => node.getBoundingClientRect().height);
  await page.locator('[data-resource-tab="people"]').click();
  const peopleDrawerHeight = await page.locator("#inventory-drawer").evaluate(node => node.getBoundingClientRect().height);
  assert.equal(computeDrawerHeight, fundsDrawerHeight);
  assert.equal(peopleDrawerHeight, fundsDrawerHeight);

  assert.equal(await page.locator("#open-erp").count(), 0);
  assert.equal(await page.locator("#erp-overlay").count(), 0);

  const width = await page.evaluate(() => ({viewport: innerWidth, document: document.documentElement.scrollWidth}));
  assert.ok(width.document <= width.viewport, "pasture game overflows horizontally");

  await browser.close();
  console.log("MFU organization pasture v0.2 browser flow passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
