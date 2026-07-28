// G5 error mechanism E2E — uses pre-seeded session
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const BASE = 'http://world.localhost:10042';
const DIR = path.join(__dirname, 'g5-screenshots');
if (!fs.existsSync(DIR)) fs.mkdirSync(DIR, { recursive: true });
let seq = 0;
function ss(page, label) { seq++; return page.screenshot({ path: path.join(DIR, `${String(seq).padStart(2,'0')}-${label}.png`), fullPage: true }); }

(async () => {
  const browser = await chromium.launch({ headless: false, slowMo: 50 });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  try {
    // ═══ 1. Login ═══
    // Seeded G5 user (fresh DBs have no admin@ezagent.chat). The founder holds
    // durable join+send caps for the pre-seeded session (see g5_e2e_seed.exs).
    console.log('[1] Login...');
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="email"]', process.env.G5_LOGIN_EMAIL || 'g5-founder@e2e.local');
    await page.fill('input[name="password"]', process.env.G5_LOGIN_PASSWORD || 'e2etest123');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/sessions', { timeout: 15000 });
    console.log('[1] Logged in');
    await ss(page, '01-logged-in');

    // ═══ 2. Navigate to pre-seeded session ═══
    console.log('[2] Opening pre-seeded session...');
    const sessUrl = `${BASE}/sessions?session=${encodeURIComponent('session://system/default/g5-e2e-test')}`;
    await page.goto(sessUrl, { waitUntil: 'networkidle', timeout: 15000 });
    await page.waitForTimeout(3000);
    await ss(page, '02-session-page');

    // ═══ 3. Send message ═══
    const composer = page.locator('textarea, [contenteditable="true"]').last();
    const hasComposer = await composer.isVisible().catch(() => false);
    console.log('[3] Composer visible:', hasComposer);
    await ss(page, '03-pre-send');

    if (hasComposer) {
      // The curl agent only ACTS on @mention (world activation rule) — a bare
      // "hello" is accepted but never reaches the agent, so no error card.
      // Pass the seeded agent URI: G5_AGENT_URI=entity://system/agent/g5-e2e-agent-...
      const agentUri = process.env.G5_AGENT_URI;
      const text = agentUri ? `@${agentUri} hello` : 'hello';
      console.log('[3] Sending:', text);
      await composer.click();
      await composer.fill(text);
      await page.waitForTimeout(300);
      await ss(page, '04-message-typed');

      // Try clicking send button first (more reliable than Enter)
      const sendBtn = page.locator('button[type="submit"], button:has-text("Send"), button[aria-label*="Send"], button:has-text("发送")').first();
      if (await sendBtn.isVisible().catch(() => false)) {
        await sendBtn.click();
      } else {
        await page.keyboard.press('Enter');
      }
      // Agent turn + structured error card render can take >10s.
      await page.waitForTimeout(15000);
      await ss(page, '05-after-send');
      console.log('[3] Message sent — check 05-after-send for G5 error card');
    } else {
      console.log('[3] No composer — trying to click session in sidebar');
      // Try clicking session name
      const sessionBtn = page.locator('text=g5-e2e-test, [data-session-uri*="g5-e2e-test"]').first();
      if (await sessionBtn.isVisible().catch(() => false)) {
        await sessionBtn.click();
        await page.waitForTimeout(5000);
        await ss(page, '03b-session-clicked');
      }
    }

    console.log(`[Done] Screenshots in ${DIR}`);

  } catch (err) {
    console.error('ERROR:', err.message);
    await ss(page, '99-error');
  } finally {
    await page.waitForTimeout(1000);
    await browser.close();
  }
})();
