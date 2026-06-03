// Send a chat message into a session and wait for replies.
// Usage: node lv-chat.js "<message>" <waitSeconds> <outPng>
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const MSG = process.argv[2] || 'hello';
const WAIT = parseInt(process.argv[3] || '25', 10);
const out = process.argv[4] || '/tmp/chat.png';

async function login(page) {
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.fill('input[name="entity_uri"]', USER);
  await page.fill('input[name="secret"]', PASS);
  await page.click('button[type="submit"]', { noWaitAfter: true });
  await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 15000 }).catch(() => {});
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(1500);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await login(page);
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1500);

  const input = page.locator('textarea, input[placeholder*="message"], input[placeholder*="mention"]').first();
  await input.click();
  await input.fill(MSG);
  await page.waitForTimeout(400);
  await page.keyboard.press('Escape'); // dismiss any @-mention autocomplete
  await page.waitForTimeout(200);
  await page.click('button:has-text("Send")', { noWaitAfter: true }).catch(async () => {
    await input.press('Enter');
  });
  console.log('sent:', MSG.slice(0, 60));

  // poll: print message count over time
  for (let i = 0; i < WAIT; i += 5) {
    await page.waitForTimeout(5000);
    const n = await page.locator('[class*="message"], .prose, article').count().catch(() => -1);
    console.log(`  +${i + 5}s ... nodes=${n}`);
  }
  await page.screenshot({ path: out, fullPage: true });
  console.log('shot:', out);
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
