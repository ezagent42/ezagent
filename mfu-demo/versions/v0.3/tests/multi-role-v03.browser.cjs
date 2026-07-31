const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {pathToFileURL} = require("node:url");
const path = require("node:path");

const demoUrl = pathToFileURL(path.join(__dirname, "../demo/MFU-多角色组织世界-v0.3.html")).href;

(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  await page.goto(`${demoUrl}?role=incubator`);
  await page.evaluate(() => localStorage.clear());
  await page.goto(`${demoUrl}?role=incubator`);

  assert.match(await page.locator("#demo-role-controller").textContent(), /仅用于演示不同用户视角/);
  assert.equal(await page.locator("#demo-role-select").inputValue(), "incubator");
  assert.match(await page.locator(".brand").textContent(), /孵化器/);
  assert.equal(await page.locator("#role-view-notice").count(), 0);
  assert.equal(await page.locator('.topbar button:has-text("重置")').count(), 0);
  assert.match(await page.locator("#organization-pasture").textContent(), /我的 MVO/);

  const pastureHeaderBefore = await page.locator(".pasture-head").boundingBox();
  await page.locator(".org-scroll").evaluate(node => node.scrollTop = node.scrollHeight);
  const pastureHeaderAfter = await page.locator(".pasture-head").boundingBox();
  assert.equal(Math.round(pastureHeaderBefore.y), Math.round(pastureHeaderAfter.y));

  await page.locator('[data-org-id="growth"]').click();
  assert.equal(await page.locator('[data-org-tab="task"]').count(), 0);
  assert.match(await page.locator("#organization-current-project").textContent(), /当前项目.*旧书店新生增长方案/s);
  await page.locator("#close-organization").click();

  await page.locator("#cash-shortcut").click();
  const incubatorFunds = await page.locator("#cash-stat").textContent();
  await page.locator("#inventory-toggle").click();

  await page.locator("#demo-role-select").selectOption("school");
  assert.match(page.url(), /role=school/);
  assert.match(await page.locator(".brand").textContent(), /学校|课程/);
  const schoolFunds = await page.locator("#cash-stat").textContent();
  assert.notEqual(schoolFunds, incubatorFunds);

  await page.locator('[data-main-tab="world"]').click();
  assert.equal(await page.locator("#world-view").isVisible(), true);
  await page.locator('[data-market-filter="教育与校园"]').click();
  assert.equal(await page.locator('[data-market-order]').count() > 0, true);
  for (const card of await page.locator('[data-market-order]').allTextContents()) assert.match(card, /教育与校园/);

  const worldBefore = await page.locator("[data-market-order]").count();
  await page.locator("#demo-role-select").selectOption("enterprise");
  assert.equal(await page.locator("#world-view").isVisible(), true);
  await page.locator('[data-market-filter="全部"]').click();
  assert.equal(await page.locator("[data-market-order]").count() >= worldBefore, true);

  await page.locator("#post-market-order").click();
  await page.locator("#confirm-market-order").click();
  assert.match(await page.locator("#market-orders").textContent(), /我发布的 · 等待承接/);
  await page.locator("#demo-role-select").selectOption("student");
  await page.locator('[data-market-filter="全部"]').click();
  assert.match(await page.locator("#market-orders").textContent(), /校园创业周传播方案/);

  const studentCash = await page.locator("#cash-stat").textContent();
  await page.locator("#reset-current-role").click();
  assert.equal(await page.locator("#cash-stat").textContent(), studentCash);

  const size = await page.evaluate(() => ({
    viewportWidth: innerWidth,
    viewportHeight: innerHeight,
    documentWidth: document.documentElement.scrollWidth,
    controller: document.querySelector("#demo-role-controller").getBoundingClientRect(),
    game: document.querySelector("#pasture-game").getBoundingClientRect()
  }));
  assert.ok(size.documentWidth <= size.viewportWidth, "v0.3 overflows horizontally");
  assert.ok(size.game.bottom <= size.viewportHeight, "v0.3 game exceeds viewport");
  assert.ok(size.controller.bottom <= size.game.top + 1, "demo controller must stay outside the game");

  await browser.close();
  console.log("MFU multi-role v0.3 browser flow passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
