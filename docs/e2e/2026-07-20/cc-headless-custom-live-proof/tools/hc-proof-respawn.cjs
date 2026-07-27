const {chromium} = require("playwright");
const BASE = "http://127.0.0.1:10101";
const SHOTS = "/tmp/ez-hc-proof/shots";
const mention = process.argv[2] || "@hc-kc-f4";
const expected = process.argv[3] || "kc-pong-2";
(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 950}});
  try {
    await page.goto(`${BASE}/login`, {waitUntil: "networkidle"});
    await page.locator('input[type="email"], input[name*="email"]').first().fill("admin@ezagent.chat");
    await page.locator('input[type="password"]').first().fill("hc-proof-admin-pw");
    await page.locator('button[type="submit"]').first().click();
    await page.waitForLoadState("networkidle");
    await page.goto(`${BASE}/sessions`, {waitUntil: "networkidle"});
    await page.waitForTimeout(1200);
    await page.locator(':has-text("Default/Hc-Proof")').first().click();
    await page.waitForTimeout(800);
    await page.locator('button:has-text("打开对话")').first().click();
    await page.waitForTimeout(2000);
    const composer = page.locator('textarea, [contenteditable="true"], input[type="text"]').last();
    await composer.click();
    await page.keyboard.type(`${mention} please reply with exactly: ${expected}`, {delay: 15});
    await page.keyboard.press("Enter");
    console.log(`sent ${mention}, awaiting ${expected} after sidecar kill ...`);
    await page.waitForFunction((token) => {
      const hits = Array.from(document.querySelectorAll("body *")).filter(
        (el) => el.children.length === 0 && [token, `${token}.`, `"${token}"`].includes(el.textContent.trim())
      );
      return hits.length >= 1;
    }, expected, {timeout: 150_000});
    await page.waitForTimeout(1500);
    await page.screenshot({path: `${SHOTS}/12-respawn-reply.png`});
    console.log(`RESPAWN REPLY OK: ${expected}`);
  } catch (e) {
    console.log("RESPAWN PROOF FAILED:", String(e).slice(0, 300));
    await page.screenshot({path: `${SHOTS}/98-respawn-failure.png`});
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
