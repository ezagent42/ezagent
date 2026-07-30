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

  await page.locator("#incubate-three").click();
  assert.equal(await page.locator("#incubation-overlay").isVisible(), true);
  assert.equal(await page.locator("#incubation-overlay [data-recommendation]").count(), 3);
  await page.locator("#confirm-incubation").click();
  await page.waitForSelector("#incubation-complete");

  assert.match(await page.locator("#mvo-summary").textContent(), /已孵化\s*9/);
  assert.equal(await page.locator("#mvo-running [data-new-mvo]").count(), 3);

  await page.locator("#advance-mvos").click();
  await page.waitForFunction(() => document.body.textContent.includes("认证 MVO"));
  assert.match(await page.locator("#completion-toast").textContent(), /认证 MVO/);
  assert.match(await page.locator("#mvo-running").textContent(), /Done/);

  await page.reload();
  assert.match(await page.locator("#mvo-summary").textContent(), /已孵化\s*9/);

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
