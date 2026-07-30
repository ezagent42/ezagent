const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {pathToFileURL} = require("node:url");
const path = require("node:path");

const demoUrl = pathToFileURL(path.join(__dirname, "MFU-MVO孵化总览-v0.1-可玩原型.html")).href;

async function assertNoHorizontalOverflow(page, label) {
  const sizes = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth
  }));
  assert.ok(sizes.document <= sizes.viewport, `${label} overflows horizontally`);
}

(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});

  await page.goto(demoUrl);
  await page.evaluate(() => localStorage.clear());
  await page.reload();
  for (const selector of [
    "#resource-inventory",
    "#opportunity-board",
    "#mvo-portfolio",
    "#mvo-running"
  ]) {
    assert.equal(await page.locator(selector).isVisible(), true);
  }

  assert.match(await page.locator("#hero-outcome").textContent(), /12 名学生.*6 个可运行的 MVO/s);
  assert.match(await page.locator("#mvo-summary").textContent(), /正在运行\s*3/);

  await page.locator("[data-mvo-id]").first().click();
  assert.equal(await page.locator("#mvo-detail-overlay").isVisible(), true);
  assert.match(await page.locator("#mvo-detail-overlay").textContent(), /组织图/);
  await page.locator("#close-detail").click();

  const initialMvoCount = await page.locator("[data-mvo-id]").count();
  await page.locator("#create-mvo").click();
  assert.equal(await page.locator("#mvo-builder-overlay").isVisible(), true);
  await page.locator("#builder-name").fill("校园洞察实验室");
  await page.locator("#builder-add-node").click();
  assert.equal(await page.locator("#org-builder-canvas [data-builder-node]").count(), 3);
  await page.locator('#org-builder-canvas [data-builder-node^="step-"]').click();
  await page.locator("#builder-node-name").fill("分析需求");
  await page.locator("#builder-node-name").dispatchEvent("change");
  await page.locator('#builder-resource-list input[value="human-growth"]').check();

  const nodeIds = await page.locator("#org-builder-canvas [data-builder-node]").evaluateAll(nodes => {
    const ids = nodes.map(node => node.dataset.builderNode);
    return ["start", ids.find(id => id.startsWith("step-")), "end"];
  });
  await page.locator("#builder-connect").click();
  await page.locator(`[data-builder-node="${nodeIds[0]}"]`).click();
  await page.locator(`[data-builder-node="${nodeIds[1]}"]`).click();
  await page.locator("#builder-connect").click();
  await page.locator(`[data-builder-node="${nodeIds[1]}"]`).click();
  await page.locator(`[data-builder-node="${nodeIds[2]}"]`).click();
  assert.equal(await page.locator("#org-builder-canvas .builder-edge").count(), 2);
  await page.locator("#builder-validate").click();
  assert.match(await page.locator("#builder-validation").textContent(), /验证通过/);
  await page.locator("#builder-save").click();
  assert.equal(await page.locator("[data-mvo-id]").count(), initialMvoCount + 1);
  assert.match(await page.locator("#mvo-portfolio").textContent(), /校园洞察实验室/);

  await page.locator("#incubate-three").click();
  assert.equal(await page.locator("#incubation-overlay").isVisible(), true);
  assert.equal(await page.locator("#incubation-overlay [data-recommendation]").count(), 3);
  await page.locator("#confirm-incubation").click();
  await page.waitForSelector("#incubation-complete");

  assert.match(await page.locator("#mvo-summary").textContent(), /已孵化\s*10/);
  assert.equal(await page.locator("#mvo-running [data-new-mvo]").count(), 3);

  await page.locator("#advance-mvos").click();
  await page.waitForFunction(() => document.body.textContent.includes("认证 MVO"));
  assert.match(await page.locator("#completion-toast").textContent(), /认证 MVO/);
  assert.match(await page.locator("#mvo-running").textContent(), /Done/);

  await page.reload();
  assert.match(await page.locator("#mvo-summary").textContent(), /已孵化\s*10/);

  await page.setViewportSize({width: 1280, height: 800});
  await assertNoHorizontalOverflow(page, "1280 desktop");

  await page.locator("#reset-demo").click();
  assert.match(await page.locator("#mvo-summary").textContent(), /已孵化\s*6/);

  await browser.close();
  console.log("MFU MVO incubator v0.1 browser flows passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
