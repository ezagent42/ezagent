const {chromium} = require("playwright");
const assert = require("node:assert/strict");
const {pathToFileURL} = require("node:url");
const path = require("node:path");

const demoUrl = pathToFileURL(path.join(__dirname, "MFU-协作阵列-v0.1-可玩原型.html")).href;

async function assign(page, cardId, slotId) {
  await page.locator(`[data-card="${cardId}"]`).last().click();
  await page.locator(`[data-slot="${slotId}"]`).click();
}

async function assertNoHorizontalOverflow(page, scene) {
  const sizes = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth
  }));
  assert.ok(sizes.document <= sizes.viewport, `${scene} overflows horizontally: ${sizes.document} > ${sizes.viewport}`);
}

(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});

  await page.goto(demoUrl);
  assert.match(await page.locator("#scene-title").textContent(), /第一关/);
  assert.equal(await page.locator("[data-card]").count(), 0);
  await page.locator("#primary-action").click();
  assert.match(await page.locator("#scene-title").textContent(), /小阵列/);

  await assign(page, "player", "understand");
  await page.getByRole("button", {name: "暂存编排"}).click();
  await page.reload();
  assert.match(await page.locator('[data-slot="understand"]').textContent(), /小满/);
  await assign(page, "agent", "make");
  await assign(page, "player", "check");
  assert.equal(await page.locator('[data-relation="review"]').count(), 0);
  assert.equal(await page.locator("#primary-action").isEnabled(), true);
  await page.locator("#primary-action").click();

  assert.match(await page.locator("#scene-title").textContent(), /正在真实时间中执行/);
  assert.match(await page.locator("#scene-content").textContent(), /可以暂时离开/);
  await page.evaluate(() => {
    const saved = JSON.parse(localStorage.getItem("mfu-card-array-v01"));
    saved.execution.startedAt -= 5000;
    localStorage.setItem("mfu-card-array-v01", JSON.stringify(saved));
  });
  await page.reload();
  await page.waitForSelector(".event-box");
  await page.getByRole("button", {name: /由本人确认/}).click();
  assert.match(await page.locator("#scene-content").textContent(), /无方向返工/);
  await page.locator("#primary-action").click();
  assert.match(await page.locator("#scene-title").textContent(), /新能力/);
  await page.locator("#primary-action").click();
  assert.match(await page.locator("#scene-content").textContent(), /正式平台需真人确认/);

  await page.getByRole("button", {name: "邀请长期合作"}).first().click();
  await page.getByRole("button", {name: "邀请长期合作"}).click();
  await page.waitForFunction(() => document.body.innerText.match(/已成为长期伙伴/g)?.length === 2);
  await page.locator("#primary-action").click();

  await assign(page, "paper", "visual");
  await assign(page, "tail", "content");
  await assign(page, "player", "validate");
  await page.locator("#primary-action").click();
  const finalCopy = await page.locator(".final-message").textContent();
  assert.match(finalCopy, /上一单，你完成了大项目中的一步/);
  assert.match(finalCopy, /这一单，你连接了三个人/);
  const deliveryPack = await page.locator(".delivery-pack").textContent();
  assert.match(deliveryPack, /旧书换新主人/);
  assert.match(deliveryPack, /校园群首轮点击率/);
  assert.match(deliveryPack, /客户可直接使用/);

  await page.goto(`${demoUrl}?scene=event`);
  await page.getByRole("button", {name: /让 Agent 自行继续/}).click();
  const fastResult = await page.locator("#scene-content").textContent();
  assert.match(fastResult, /提前半天/);
  assert.match(fastResult, /返工 1 次/);
  assert.match(fastResult, /自行猜测了目标用户/);

  await page.setViewportSize({width: 1280, height: 800});
  for (const scene of ["briefing", "build1", "running", "event", "result1", "upgrade", "invite", "build2", "result2"]) {
    await page.goto(`${demoUrl}?scene=${scene}`);
    await assertNoHorizontalOverflow(page, scene);
  }

  await browser.close();
  console.log("MFU card-array v0.1 browser flows passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
