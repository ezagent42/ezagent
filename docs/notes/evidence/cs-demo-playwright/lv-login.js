// LV login + screenshot smoke. Usage: node lv-login.js <outPng>
const { chromium } = require('playwright');

const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'admin';
const PASS = process.env.LV_PASS || '8bdemo';
const out = process.argv[2] || '/tmp/lv-after-login.png';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.fill('input[name="entity_uri"]', USER);
  await page.fill('input[name="secret"]', PASS);
  await page.click('button[type="submit"]');
  // post-login is LiveView (persistent WS) → networkidle never settles; wait for URL leave /login
  await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 15000 }).catch(() => {});
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(1500);
  const err = await page.locator('text=Invalid URI or credentials').count();
  console.log('login error shown:', err > 0);

  console.log('final url:', page.url());
  console.log('title   :', await page.title());
  await page.screenshot({ path: out, fullPage: true });
  console.log('shot    :', out);
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
