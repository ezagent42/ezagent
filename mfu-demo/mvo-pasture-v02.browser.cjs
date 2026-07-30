const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {pathToFileURL} = require("node:url");
const path = require("node:path");

const demoUrl = pathToFileURL(path.join(__dirname, "MFU-MVO组织牧场-v0.2-可玩原型.html")).href;

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

  await page.locator("#office-tab").click();
  assert.equal(await page.locator("#incubator-office").isVisible(), true);
  await page.locator("#pasture-tab").click();
  await page.locator('[data-org-id="growth"]').click();
  assert.equal(await page.locator("#organization-overlay").isVisible(), true);
  for (const tab of ["task", "assets", "records", "finance", "logs", "site"]) {
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

  await page.locator("#advance-work").click();
  await page.locator("#advance-work").click();
  await page.locator("#advance-work").click();
  assert.match(await page.locator("#action-sidebar").textContent(), /待验收/);
  await page.locator("[data-action-type='review']").first().click();
  await page.locator("#accept-delivery").click();
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

  await page.locator("#open-erp").click();
  assert.equal(await page.locator("#erp-overlay").isVisible(), true);
  for (const tab of ["tasks", "organizations", "resources", "finance", "logs"]) {
    await page.locator(`[data-erp-tab="${tab}"]`).click();
    assert.ok((await page.locator("#erp-body").textContent()).trim().length > 0);
  }

  const width = await page.evaluate(() => ({viewport: innerWidth, document: document.documentElement.scrollWidth}));
  assert.ok(width.document <= width.viewport, "pasture game overflows horizontally");

  await browser.close();
  console.log("MFU organization pasture v0.2 browser flow passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
