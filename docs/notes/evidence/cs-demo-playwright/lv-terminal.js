// Open a session's Terminal tab, optionally send Enter N times to clear onboarding.
// Usage: node lv-terminal.js <enterCount> <outPng>
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const ENTERS = parseInt(process.argv[2] || '0', 10);
const out = process.argv[3] || '/tmp/terminal.png';

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

  // Click the Terminal tab.
  const term = page.locator('text=/Terminal/').first();
  if (await term.count()) { await term.click(); console.log('clicked Terminal tab'); }
  await page.waitForTimeout(1500);

  // Report any agent picker / xterm presence.
  const xterm = await page.locator('.xterm, .xterm-helper-textarea, textarea').count();
  console.log('xterm-ish nodes:', xterm);
  const selects = await page.$$eval('select', (els) => els.map((s) => ({ name: s.name, opts: Array.from(s.options).map((o)=>o.value) })));
  console.log('SELECTS:', JSON.stringify(selects));

  if (ENTERS > 0) {
    // focus the xterm input and press Enter to answer onboarding prompts
    const ta = page.locator('.xterm-helper-textarea, textarea').first();
    await ta.click({ timeout: 3000 }).catch(() => page.locator('.xterm').first().click().catch(()=>{}));
    for (let i = 0; i < ENTERS; i++) {
      await page.keyboard.press('Enter');
      await page.waitForTimeout(700);
    }
    console.log('pressed Enter x', ENTERS);
    await page.waitForTimeout(1500);
  }

  await page.screenshot({ path: out, fullPage: true });
  console.log('shot:', out, 'url:', page.url());
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
