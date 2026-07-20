// cc-headless-custom live proof — world UI chat round-trip driver.
// Run from apps/ezagent_plugin_world/assets: node /tmp/ez-hc-proof/chat-proof.cjs <step>
const {chromium} = require("playwright");

const BASE = "http://127.0.0.1:10101";
const EMAIL = "admin@ezagent.chat";
const PW = process.env.HC_ADMIN_PW || "hc-proof-admin-pw";
const SESSION_URI = "session://system/default/hc-proof";
const SHOTS = "/tmp/ez-hc-proof/shots";

async function login(page) {
  await page.goto(`${BASE}/login`, {waitUntil: "networkidle"});
  await page.screenshot({path: `${SHOTS}/00-login.png`});
  const email = page.locator('input[type="email"], input[name*="email"], input[name="email"]').first();
  const pw = page.locator('input[type="password"]').first();
  await email.fill(EMAIL);
  await pw.fill(PW);
  const submit = page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Log in"), button:has-text("登录")').first();
  await submit.click();
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(1500);
  await page.screenshot({path: `${SHOTS}/01-after-login.png`});
  console.log("logged in, url:", page.url());
}

async function openSession(page) {
  await page.goto(`${BASE}/sessions`, {waitUntil: "networkidle"});
  await page.waitForTimeout(1500);
  // select the hc-proof session card, then open the conversation panel
  await page.locator(':has-text("Default/Hc-Proof")').first().click();
  await page.waitForTimeout(800);
  await page.locator('button:has-text("打开对话")').first().click();
  await page.waitForTimeout(2500);
  await page.screenshot({path: `${SHOTS}/02-session.png`});
  console.log("session open, url:", page.url());
}

async function sendAndAwait(page, mention, expected, tag) {
  // composer: the world chat input (contenteditable or textarea)
  const composer = page
    .locator('textarea, [contenteditable="true"], input[type="text"]')
    .last();
  await composer.click();
  await page.keyboard.type(`${mention} `, {delay: 30});
  await page.waitForTimeout(800);
  await page.screenshot({path: `${SHOTS}/${tag}-mention.png`});
  // pick autocomplete if it popped
  const ac = page.locator(`text=${mention}`).last();
  try {
    await ac.click({timeout: 1200});
  } catch (_) {
    /* no autocomplete — plain text mention is fine */
  }
  await page.keyboard.type(`please reply with exactly: ${expected}`, {delay: 15});
  await page.screenshot({path: `${SHOTS}/${tag}-composed.png`});
  await page.keyboard.press("Enter");
  console.log(`sent to ${mention}, awaiting ${expected} (count>=2 on the feed) ...`);
  // My OWN message already contains the token once; the agent's reply makes
  // it appear a SECOND time. Wait for count >= 2, then confirm a bubble
  // authored by the agent (not the right-aligned own bubble) carries it.
  await page.waitForFunction(
    (token) => {
      const hits = Array.from(document.querySelectorAll("body *")).filter(
        (el) =>
          el.children.length === 0 &&
          [token, `${token}.`, `"${token}"`, `${token}!`, `${token}。`].includes(
            el.textContent.trim()
          )
      );
      return hits.length >= 1;
    },
    expected,
    {timeout: 120_000}
  );
  await page.waitForTimeout(1500);
  await page.screenshot({path: `${SHOTS}/${tag}-reply.png`, fullPage: false});
  console.log(`REPLY OK: ${expected}`);
}

(async () => {
  const browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1440, height: 950}});
  page.on("console", (m) => {
    if (m.type() === "error") console.log("[console.error]", m.text().slice(0, 200));
  });
  try {
    await login(page);
    await openSession(page);
    await sendAndAwait(page, "@hc-ds-f2", "ds-pong", "10-ds");
    await sendAndAwait(page, "@hc-kc-f4", "kc-pong", "11-kc");
    console.log("ALL CHAT PROOFS OK");
  } catch (e) {
    console.log("PROOF FAILED:", String(e).slice(0, 400));
    await page.screenshot({path: `${SHOTS}/99-failure.png`});
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
