// World agent-config MVP demo recorder (world plugin React island, ESR LiveView).
//
// Demonstrates the re-shaped CREATE page (/identities/agents/new) and DETAIL
// page (/identities/agents/:uri) on branch `socialware-creator-agent-config`:
//   1. land on the contract-shaped create form + "Contract coverage" list
//   2. create a `curl` agent (no project_cwd) -> succeeds -> labeled detail
//      page with granted-caps chips (NOT a raw JSON dump)
//   3. create a `cc` agent with EMPTY project_cwd -> server rejects with a
//      VISIBLE operator message ("cc 需要 project_cwd ...") -> no silent drop
//
// World routes are host-scoped (`host: "world."`), so ORIGIN must be the
// world.<host> vhost. Login is the controller-rendered email+password form
// (#email + #password, plain POST). Records the browser compositor -> webm +
// numbered PNGs; record-clean.sh / ffmpeg transcodes to GIF + MP4.
//
// Env:
//   DEMO_ORIGIN   default http://world.localhost:10052
//   DEMO_OUTDIR   default ./demo-out
//   DEMO_USER / DEMO_PASS  admin@ezagent.chat / worlddev (seed-provisioned)

const { chromium } = require('playwright');
const fs = require('fs');

const OUT = process.env.DEMO_OUTDIR || './demo-out';
const ORIGIN = process.env.DEMO_ORIGIN || 'http://world.localhost:10052';
const HEADED = process.env.DEMO_HEADED === '1';
const W = Number(process.env.DEMO_W || 1180), H = Number(process.env.DEMO_H || 900);
const LOGIN_EMAIL = process.env.DEMO_USER || 'admin@ezagent.chat';
const LOGIN_PASS = process.env.DEMO_PASS || 'worlddev';
const TS = Date.now();

const log = (...a) => console.log('[record-agentcfg]', ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// React island root for each surface.
const NEW_FORM = '[data-world-component="agent_new_form"]';
const DETAIL = '[data-world-component="agent_detail"]';

async function login(browser) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  log('login at', ORIGIN + '/login', 'as', LOGIN_EMAIL);
  await p.goto(ORIGIN + '/login', { waitUntil: 'load', timeout: 30000 });
  await p.waitForSelector('#email', { state: 'visible', timeout: 15000 });
  await p.fill('#email', LOGIN_EMAIL);
  await p.fill('#password', LOGIN_PASS);
  await Promise.all([
    p.waitForURL((u) => !String(u).includes('/login'), { timeout: 30000 }).catch(() => {}),
    p.locator('#password').press('Enter').catch(() => {}),
  ]);
  log(p.url().includes('/login') ? 'WARN: still on /login' : 'logged in -> ' + p.url());
  const state = await ctx.storageState();
  await ctx.close();
  return state;
}

async function liveConnected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null,
    { timeout: 20000 }).catch(() => log('WARN: liveSocket not connected within 20s'));
}

async function gotoNew(page) {
  await page.goto(`${ORIGIN}/identities/agents/new`, { waitUntil: 'domcontentloaded' });
  await liveConnected(page);
  await page.waitForSelector(NEW_FORM, { state: 'visible', timeout: 20000 });
  await page.waitForTimeout(800);
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  for (const f of fs.readdirSync(OUT)) {
    if (/\.webm$|\.gif$|\.mp4$|^\d\d-.*\.png$/.test(f)) fs.rmSync(`${OUT}/${f}`, { force: true });
  }
  const browser = await chromium.launch({ headless: !HEADED });
  let shot = 0;
  const snap = async (page, name) => {
    const f = `${OUT}/${String(++shot).padStart(2, '0')}-${name}.png`;
    await page.screenshot({ path: f });
    log('snap', f);
  };

  const state = await login(browser);
  const ctx = await browser.newContext({
    storageState: state,
    viewport: { width: W, height: H },
    recordVideo: { dir: OUT, size: { width: W, height: H } },
  });
  const page = await ctx.newPage();

  // --- Scenario 1: the contract-shaped create form + coverage list ---
  log('scenario 1: create form');
  await gotoNew(page);
  await snap(page, 'create-form-contract-shaped');

  // --- Scenario 2: create a curl agent (no cwd) -> detail page ---
  const curlName = `demo-curl-${TS}`;
  log('scenario 2: create curl agent', curlName);
  // flavor select -> curl
  await page.selectOption(`${NEW_FORM} select`, 'curl').catch(async () => {
    // fall back: click + choose by label
    await page.getByRole('combobox').selectOption('curl').catch(() => {});
  });
  await page.fill(`${NEW_FORM} input[placeholder="storefront-greeter"]`, curlName);
  await page.fill(`${NEW_FORM} input[placeholder*="chat.send"]`, 'chat.send, workspace.read');
  // leave project_cwd EMPTY
  await page.waitForTimeout(500);
  await snap(page, 'curl-form-filled');
  // submit
  await page.locator(`${NEW_FORM} button[type="submit"]`).click();
  // success navigates to the detail page
  await page.waitForSelector(DETAIL, { state: 'visible', timeout: 20000 })
    .catch(() => log('WARN: detail island not seen — capturing whatever rendered'));
  await liveConnected(page);
  await page.waitForTimeout(1200);
  await snap(page, 'curl-detail-labeled');

  // --- Scenario 3: cc agent, EMPTY cwd -> visible error (no silent drop) ---
  const ccName = `demo-cc-${TS}`;
  log('scenario 3: cc agent empty cwd ->', ccName);
  await gotoNew(page);
  await page.selectOption(`${NEW_FORM} select`, 'cc').catch(() => {});
  await page.fill(`${NEW_FORM} input[placeholder="storefront-greeter"]`, ccName);
  // leave project_cwd EMPTY (cc requires it)
  await page.waitForTimeout(400);
  await snap(page, 'cc-form-empty-cwd');
  // The Create button is client-disabled when cwd is required+empty, by design.
  // To prove the SERVER-side no-silent-drop guard, dispatch the form submit
  // through the LiveView hook the same way the button would, bypassing the
  // disabled attribute (the server still runs the authoritative validation).
  await page.evaluate(() => {
    const form = document.querySelector('#world-agent-new-form');
    if (form) form.requestSubmit
      ? form.requestSubmit()
      : form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  // server rejects -> create_error rendered in the alert
  await page.waitForFunction(
    (sel) => {
      const el = document.querySelector(sel);
      return el && /project_cwd|需要/.test(el.textContent || '');
    },
    `${NEW_FORM} [role="alert"]`, { timeout: 15000 }
  ).catch(() => log('WARN: create_error alert not detected — capturing whatever rendered'));
  await page.waitForTimeout(900);
  await snap(page, 'cc-empty-cwd-error');

  await page.waitForTimeout(1200);
  const video = page.video();
  await ctx.close();
  if (video) {
    const vp = await video.path();
    fs.renameSync(vp, `${OUT}/demo.webm`);
  }
  await browser.close();
  log('VIDEO:', fs.existsSync(`${OUT}/demo.webm`) ? `${OUT}/demo.webm` : '(none)');
  log('SHOTS:', fs.readdirSync(OUT).filter((f) => f.endsWith('.png')).join(', '));
})().catch((e) => { console.error('[record-agentcfg] FATAL', e); process.exit(1); });
