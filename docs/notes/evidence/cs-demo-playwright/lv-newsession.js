// Login, open the +New session form, dump template options + screenshot.
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const out = process.argv[2] || '/tmp/newsession.png';

async function login(page) {
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.fill('input[name="entity_uri"]', USER);
  await page.fill('input[name="secret"]', PASS);
  await page.click('button[type="submit"]', { noWaitAfter: true });
  await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 15000 }).catch(() => {});
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(1200);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await login(page);

  // The new-session form is behind "+ New" on the chat/sessions page.
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1000);
  const newBtn = page.locator('text=/\\+\\s*New/').first();
  if (await newBtn.count()) {
    await newBtn.click().catch((e) => console.log('click +New err', e.message));
    await page.waitForTimeout(1000);
  } else {
    console.log('no +New found');
  }

  // Dump any <select> options + any "template_class"/"new_session" controls.
  const selects = await page.$$eval('select', (els) =>
    els.map((s) => ({ name: s.name, options: Array.from(s.options).map((o) => o.value).filter(Boolean) }))
  );
  console.log('SELECTS:', JSON.stringify(selects));

  const inputs = await page.$$eval('input,select,button', (els) =>
    els.map((e) => ({ tag: e.tagName, name: e.name || '', type: e.type || '', text: (e.innerText || '').slice(0, 30) }))
       .filter((e) => /session|template|new/i.test(e.name + e.text))
  );
  console.log('CONTROLS:', JSON.stringify(inputs));

  await page.screenshot({ path: out, fullPage: true });
  console.log('shot:', out, 'url:', page.url());
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
