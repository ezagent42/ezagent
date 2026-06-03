// Record a .webm of operator <-> orchestrator live conversation.
// Usage: node lv-record.js <outDir>
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const OUTDIR = process.argv[2] || '/tmp/rec';
const ORCH = 'entity://agent/system/cc_orchestrator-main';

const SIZE = { width: 1440, height: 900 };

// Each step: a message to send + how long to wait (ms) for the live reply.
const SCRIPT = [
  { msg: `@${ORCH} 你好，请列出我当前可用的 agent 模板和 session 模板。`, wait: 45000 },
  { msg: `@${ORCH} 请用 add_managed_member 从 template://agent/system/cc-orchestrator 启动一个 VIP 售前客服坐席，role_name=vip_presale，in_session_template=true。加好后简短确认。`, wait: 80000 },
];

async function login(page) {
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.fill('input[name="entity_uri"]', USER);
  await page.fill('input[name="secret"]', PASS);
  await page.click('button[type="submit"]', { noWaitAfter: true });
  await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 15000 }).catch(() => {});
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(1500);
}

async function sendMsg(page, text) {
  const input = page.locator('textarea, input[placeholder*="message"], input[placeholder*="mention"]').first();
  await input.click();
  await input.fill(text);
  await page.waitForTimeout(500);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  await page.click('button:has-text("Send")', { noWaitAfter: true }).catch(async () => { await input.press('Enter'); });
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: SIZE, recordVideo: { dir: OUTDIR, size: SIZE } });
  const page = await ctx.newPage();

  await login(page);
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);

  for (const step of SCRIPT) {
    await sendMsg(page, step.msg);
    console.log('sent:', step.msg.slice(0, 40), '... waiting', step.wait / 1000, 's');
    // keep scrolling to bottom periodically so the live reply stays visible
    const end = Date.now() + step.wait;
    while (Date.now() < end) {
      await page.waitForTimeout(4000);
      await page.evaluate(() => {
        const el = document.querySelector('[class*="overflow"], main, [class*="messages"]');
        if (el) el.scrollTop = el.scrollHeight;
        window.scrollTo(0, document.body.scrollHeight);
      }).catch(() => {});
    }
  }
  await page.waitForTimeout(2000);

  const video = page.video();
  await ctx.close(); // finalizes the video
  const path = video ? await video.path() : null;
  console.log('VIDEO:', path);
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
