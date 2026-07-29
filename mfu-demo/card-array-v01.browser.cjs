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
  assert.match(await page.locator("#scene-title").textContent(), /欢迎来到 MFU/);
  await page.locator("#nickname-input").fill("阿禾");
  await page.locator("#nickname-form").getByRole("button").click();
  assert.match(await page.locator("#scene-content").textContent(), /你 · 阿禾/);
  assert.equal(await page.locator("[data-card]").count(), 0);

  const briefingButton = page.locator("#primary-action");
  assert.equal(await briefingButton.isVisible(), true);
  await briefingButton.click();
  assert.match(await page.locator("#scene-title").textContent(), /小阵列/);
  assert.match(await page.locator("#order-resources").textContent(), /教学关卡不限时/);
  assert.match(await page.locator("#order-resources").textContent(), /2 小时/);
  assert.match(await page.locator("#order-resources").textContent(), /24 点/);
  assert.match(await page.locator("#order-resources").textContent(), /¥200/);
  assert.equal(await page.locator("[data-slot]").count(), 3);
  assert.equal(await page.locator("[data-card]").count(), 2);
  assert.equal(await page.locator("#role-tour").isVisible(), true);
  assert.match(await page.locator("#role-tour").textContent(), /第一个 Agent 小角/);
  await page.locator("#acknowledge-role-tour").click();
  assert.equal(await page.locator("#drag-ghost").isVisible(), true);
  assert.match(await page.locator("#drag-ghost").textContent(), /任务的某一个环节/);

  await assign(page, "player", "understand");
  await assign(page, "agent", "make");
  await assign(page, "agent", "check");
  assert.match(await page.locator("#coach-tip").textContent(), /需求误解|没有安排本人检查/);
  assert.equal(await page.locator("#primary-action").isEnabled(), true);
  assert.equal(await page.locator("#drag-ghost").count(), 0);

  await page.getByRole("button", {name: "暂存编排"}).click();
  await page.reload();
  assert.match(await page.locator('[data-slot="understand"]').textContent(), /阿禾/);
  assert.equal(await page.locator("#nickname-input").count(), 0);
  assert.equal(await page.locator("#role-tour").count(), 0);

  await page.locator("#primary-action").click();
  await page.waitForSelector(".draft-poster--wrong");
  const wrongDraft = await page.locator(".draft-poster--wrong").textContent();
  assert.match(wrongDraft, /全校同学/);
  assert.match(await page.locator("#scene-content").textContent(), /目标人群：刚入学的新生/);
  assert.match(await page.locator("#scene-content").textContent(), /已消耗 6 点算力/);
  assert.match(await page.locator("#order-resources").textContent(), /18 点/);

  await page.locator("#feedback-input").fill("目标人群应为刚入学的新生，请先确认必要信息。");
  await page.locator("#feedback-form").getByRole("button").click();
  assert.match(await page.locator("#scene-title").textContent(), /调教 Agent/);
  assert.match(await page.locator("#order-resources").textContent(), /¥200/);
  assert.equal(await page.locator("#agent-training-card").isVisible(), true);
  assert.equal(await page.locator("#training-methods button").count(), 4);
  await page.locator('[data-training-method="examples"]').click();
  assert.match(await page.locator("#training-detail").textContent(), /二选一鉴别/);
  await page.locator('[data-training-method="review"]').click();
  assert.match(await page.locator("#training-detail").textContent(), /复盘素材 0/);
  await page.locator('[data-training-method="tool"]').click();
  await page.locator("#buy-form-tool").click();
  assert.match(await page.locator("#order-resources").textContent(), /¥120/);
  assert.match(await page.locator("#scene-title").textContent(), /调教 Agent/);
  await page.locator('[data-training-method="rule"]').click();
  await page.locator("#agent-rule-input").fill("缺少必要信息时，先用 Form 向我确认");
  await page.locator("#agent-rule-form").getByRole("button").click();
  assert.match(await page.locator("#order-resources").textContent(), /1 小时/);
  assert.match(await page.locator("#scene-content").textContent(), /小角调用了 Form/);

  await page.locator('#clarification-form select[name="audience"]').selectOption("freshmen");
  await page.locator('#clarification-form input[name="action"]').fill("到店完成第一次购买");
  await page.locator("#clarification-form").getByRole("button").click();
  await page.waitForSelector(".draft-poster--correct");
  assert.match(await page.locator(".draft-poster--correct").textContent(), /新生/);
  assert.match(await page.locator("#scene-title").textContent(), /你的成果已交付/);
  const routeBefore = await page.locator("#whole-order-route").textContent();
  assert.match(routeBefore, /内容表达.*进行中/s);
  assert.match(routeBefore, /整合交付.*等待中/s);
  assert.match(await page.locator("#scene-content").textContent(), /完整订单仍在进行/);
  assert.match(await page.locator("#order-resources").textContent(), /12 点/);

  await page.reload();
  assert.match(await page.locator("#scene-title").textContent(), /你的成果已交付/);
  await page.locator("#primary-action").click();
  assert.match(await page.locator("#scene-title").textContent(), /完整订单已完成/);
  const settlement = await page.locator(".settlement-sheet").textContent();
  assert.match(settlement, /使用 1 \/ 2 小时/);
  assert.match(settlement, /使用 12 \/ 24 点/);
  assert.match(settlement, /剩余 ¥120/);
  assert.match(settlement, /Form/);
  assert.match(settlement, /经过本次重试验证/);
  assert.equal(await page.locator("#settlement-assessment").count(), 0);
  assert.equal(await page.getByText("邀请长期合作").count(), 0);
  assert.equal(await page.getByText("第二幕").count(), 0);
  assert.equal(await page.getByRole("button", {name: "领取第一份自由订单"}).isVisible(), true);

  await page.evaluate(() => localStorage.clear());
  await page.goto(demoUrl);
  assert.equal(await page.locator("#nickname-input").count(), 1);

  await page.setViewportSize({width: 1280, height: 800});
  for (const scene of [
    "welcome", "briefing", "build", "firstRun", "inspect",
    "tune", "clarify", "secondRun", "stepDelivered", "settlement"
  ]) {
    await page.goto(`${demoUrl}?scene=${scene}`);
    await assertNoHorizontalOverflow(page, scene);
  }

  await browser.close();
  console.log("MFU hunter tutorial v0.3 browser flows passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
