const {chromium} = require("playwright");
const BASE = "http://127.0.0.1:10101";
const SHOTS = "/tmp/ez-hc-proof/shots";
(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 1200}});
  try {
    await page.goto(`${BASE}/login`, {waitUntil: "networkidle"});
    await page.locator('input[type="email"], input[name*="email"]').first().fill("admin@ezagent.chat");
    await page.locator('input[type="password"]').first().fill("hc-proof-admin-pw");
    await page.locator('button[type="submit"]').first().click();
    await page.waitForLoadState("networkidle");
    await page.goto(`${BASE}/identities/agents/new`, {waitUntil: "networkidle"});
    await page.waitForTimeout(1500);
    await page.locator("select").first().selectOption("cc-headless-custom");
    await page.waitForTimeout(1200);
    await page.locator('input[placeholder*="zhang"]').first().fill("hc-ds-f3");
    await page.locator("select").nth(3).selectOption("deepseek");
    await page.waitForTimeout(400);
    await page.screenshot({path: `${SHOTS}/22-form-filled.png`, fullPage: true});
    await page.locator('button:has-text("Create")').first().click();
    await page.waitForTimeout(8000);
    await page.screenshot({path: `${SHOTS}/23-form-submitted.png`, fullPage: true});
    console.log("URL AFTER SUBMIT:", page.url());
  } catch (e) {
    console.log("F3 FORM FAILED:", String(e).slice(0, 400));
    await page.screenshot({path: `${SHOTS}/96-f3-failure.png`});
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
