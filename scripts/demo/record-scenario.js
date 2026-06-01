// Multi-scenario browser-native demo recorder for the ezagent PoC (Playwright).
//
// Fixes the three broken demos:
//   - chat:     was single-turn       -> now multi-turn conversation
//   - operator: was a static frame    -> now drives a real take-over (2 contexts)
//   - soul:     was a static frame    -> now shows edit-soul before/after
//
// WHY Playwright: records the browser's own compositor (no macOS Screen-Recording
// permission, page-only, reproducible). Output: <OUTDIR>/demo.webm + numbered PNGs.
// record-scenario.sh converts to GIF/MP4 with ffmpeg.
//
// Cold-start handling: a per-conversation cc agent is COLD on first load and the
// composer (#cc-input) stays disabled until the agent binds its bridge (can take
// 30-90s; first ChatLive bootstrap often times out -> the documented "refresh
// once" fix). We exploit that conv_id is URL-pinnable (`?conv=<id>`) and that
// merely LOADING the page spawns+binds the agent — so we PREWARM the agent
// out-of-band (throwaway page, reload-retry until the composer enables), then
// record on the now-warm conv with a clean, empty transcript.
//
// Env:
//   DEMO_MODE      chat | operator | soul          (default chat)
//   DEMO_TENANT    tenant slug                      (default cinnox)
//   DEMO_OUTDIR    output dir                       (default ./demo-out)
//   DEMO_ORIGIN    server origin                    (default http://127.0.0.1:10142)
//   DEMO_QUESTIONS '||'-separated turns (chat mode) (default 3 cinnox turns)
//   DEMO_HEADED    1 -> headed window               (default headless)
//   DEMO_W/DEMO_H  viewport                         (default 1100x820)
//   DEMO_REPLY_TIMEOUT_MS  per-reply wait           (default 90000)
//   DEMO_WARM_TRIES / DEMO_WARM_WAIT_MS  prewarm reload-retry (default 6 / 22000)
//   DEMO_USER / DEMO_PASS  operator/admin login     (default entity://user/system/admin / ezagent-dev)
const { chromium } = require('playwright');
const fs = require('fs');

const MODE = process.env.DEMO_MODE || 'chat';
const TENANT = process.env.DEMO_TENANT || 'cinnox';
const OUT = process.env.DEMO_OUTDIR || './demo-out';
const ORIGIN = process.env.DEMO_ORIGIN || 'http://127.0.0.1:10142';
const HEADED = process.env.DEMO_HEADED === '1';
const W = Number(process.env.DEMO_W || 1100), H = Number(process.env.DEMO_H || 820);
const REPLY_TIMEOUT = Number(process.env.DEMO_REPLY_TIMEOUT_MS || 90000);
// Cold cc-agent bring-up on this machine takes >2.5 min (claude boot + onboarding
// screens + MCP init + esr-bridge join). Budget generously; reload only sparingly
// (each reload restarts ChatLive's own bootstrap retry, which doesn't speed the
// underlying agent boot). Once bound the agent stays warm.
const WARM_BUDGET = Number(process.env.DEMO_WARM_BUDGET_MS || 300000);
const WARM_RELOAD_EVERY = Number(process.env.DEMO_WARM_RELOAD_MS || 75000);
const LOGIN_USER = process.env.DEMO_USER || 'entity://user/system/admin';
const LOGIN_PASS = process.env.DEMO_PASS || 'ezagent-dev';

// Per-tenant demo content. The features shown (multi-turn chat, operator
// takeover, soul before/after) are tenant-agnostic; only the scripted text +
// the soul fact we toggle differ. acme is the synthetic English fixture; cinnox
// is the (local-only) zh fixture.
const TENANT_DEFAULTS = {
  acme: {
    questions: [
      'Hi! What kind of products does Acme sell?',
      'How long is the warranty on a laptop?',
      'And what about the Pro line?',
    ],
    soulQuestion: 'How long is the warranty on an Acme laptop?',
    soulFind: /12-month/g,
    soulReplace: '18-month',
    operatorAsk: "Hi, I've got an issue I'd rather sort out with a human — is that possible?",
    operatorReply: "Hello! This is Lily from Acme support — I've taken over your chat. What can I help with? 😊",
  },
  cinnox: {
    questions: ['你好,请问 CINNOX 是做什么的?', '你们支持哪些沟通渠道?', '标准版多少钱?'],
    soulQuestion: '标准版多少钱?',
    soulFind: /USD\s*39/g,
    soulReplace: 'USD 88',
    operatorAsk: '你好,我遇到一个问题,想直接找人工客服处理可以吗?',
    operatorReply: '您好,我是人工客服 Lily,已经接手您的咨询,请问遇到什么问题了呢? 😊',
  },
};
const DEF = TENANT_DEFAULTS[TENANT] || TENANT_DEFAULTS.cinnox;
const CHAT_QUESTIONS = (process.env.DEMO_QUESTIONS || DEF.questions.join('||')).split('||');

const log = (...a) => console.log('[record-scenario]', ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- login (throwaway context; carry only the session cookie) ---------------
async function loginState(browser) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  const loginUrl = ORIGIN + '/login';
  log('logging in at', loginUrl, 'as', LOGIN_USER);
  await p.goto(loginUrl, { waitUntil: 'load', timeout: 30000 });
  const uSel = '#entity_uri, input[name="entity_uri"]';
  const pSel = '#secret, input[name="secret"]';
  await p.waitForSelector(uSel, { state: 'visible', timeout: 15000 });
  await p.waitForTimeout(1200);
  for (let i = 0; i < 4; i++) {
    await p.fill(uSel, LOGIN_USER);
    await p.fill(pSel, LOGIN_PASS);
    await p.waitForTimeout(300);
    if ((await p.inputValue(uSel)) === LOGIN_USER && (await p.inputValue(pSel)) === LOGIN_PASS) break;
  }
  await Promise.all([
    p.waitForURL((u) => !String(u).includes('/login'), { timeout: 30000 }).catch(() => {}),
    p.locator(pSel).press('Enter').catch(() => {}),
  ]);
  log(p.url().includes('/login') ? 'WARN: still on /login' : 'logged in -> ' + p.url());
  const state = await ctx.storageState();
  await ctx.close();
  return state;
}

// ---- composer enabled? (reload-retry, mirrors the human "refresh once") ------
const COMPOSER = '#cc-input';
async function composerEnabled(page) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    return !!el && !el.disabled;
  }, COMPOSER).catch(() => false);
}
async function waitComposer(page, label = '') {
  const t0 = Date.now();
  let lastReload = Date.now();
  while (Date.now() - t0 < WARM_BUDGET) {
    if (await composerEnabled(page)) {
      log(`composer ready ${label} after ${Math.round((Date.now() - t0) / 1000)}s`);
      return true;
    }
    if (Date.now() - lastReload > WARM_RELOAD_EVERY) {
      log(`${label} still connecting (${Math.round((Date.now() - t0) / 1000)}s) — reloading…`);
      await page.reload({ waitUntil: 'domcontentloaded' }).catch(() => {});
      lastReload = Date.now();
    }
    await page.waitForTimeout(2000);
  }
  return composerEnabled(page);
}

// ---- prewarm a conv's agent out-of-band (throwaway page) --------------------
async function prewarm(browser, conv, storageState) {
  const ctx = await browser.newContext(storageState ? { storageState } : {});
  const p = await ctx.newPage();
  const url = `${ORIGIN}/chat/${TENANT}?conv=${conv}`;
  log('prewarming agent for conv', conv, '…');
  await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
  const ok = await waitComposer(p, `(prewarm ${conv})`);
  await ctx.close();
  if (!ok) throw new Error(`prewarm failed: agent for ${conv} never bound`);
  log('prewarm OK for', conv);
}

// ---- send a customer message + wait for the agent reply to finish -----------
async function sendAndWaitReply(page, text) {
  const input = page.locator(COMPOSER);
  await input.click();
  await input.fill(text);
  const base = await page.evaluate(() => document.querySelector('#cc-messages')?.childElementCount ?? 0);
  const send = page.getByRole('button', { name: /send|发送/i }).first();
  if (await send.count().then((c) => c > 0).catch(() => false)) await send.click();
  else await input.press('Enter');
  // wait for a NEW bubble beyond the user echo (agent reply), then streaming settle
  await page.waitForTimeout(1500);
  await page.waitForFunction(
    (b) => (document.querySelector('#cc-messages')?.childElementCount ?? 0) > b + 1,
    base, { timeout: REPLY_TIMEOUT, polling: 1000 }
  ).catch(() => log('no agent bubble within timeout — capturing what is there'));
  let last = 0, stableSince = null; const t0 = Date.now();
  while (Date.now() - t0 < 25000) {
    const len = await page.evaluate(() =>
      document.querySelector('#cc-messages')?.lastElementChild?.innerText?.length ?? 0).catch(() => last);
    if (len > last + 5) { last = len; stableSince = null; }
    else if (last > 0) { stableSince = stableSince || Date.now(); if (Date.now() - stableSince > 2500) break; }
    await page.waitForTimeout(700);
  }
  await page.evaluate(() => document.querySelector('#cc-messages')?.lastElementChild?.scrollIntoView({ block: 'end' }));
  await page.waitForTimeout(600);
}

// ---- per-mode drivers -------------------------------------------------------
async function driveChat(browser, snap) {
  const conv = `chat-demo-${TENANT}`;
  await prewarm(browser, conv);
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, recordVideo: { dir: OUT, size: { width: W, height: H } } });
  const page = await ctx.newPage();
  await page.goto(`${ORIGIN}/chat/${TENANT}?conv=${conv}`, { waitUntil: 'domcontentloaded' });
  await waitComposer(page, '(chat record)');
  await page.waitForTimeout(800); await snap(page, 'loaded');
  for (let i = 0; i < CHAT_QUESTIONS.length; i++) {
    log(`chat turn ${i + 1}/${CHAT_QUESTIONS.length}: ${CHAT_QUESTIONS[i]}`);
    await sendAndWaitReply(page, CHAT_QUESTIONS[i].trim());
    await snap(page, `turn-${i + 1}`);
  }
  await page.waitForTimeout(1200);
  return ctx;
}

async function driveOperator(browser, snap) {
  const conv = `op-demo-${TENANT}`;
  const opState = await loginState(browser);
  await prewarm(browser, conv);
  // recording context = the CUSTOMER side (so the video shows the take-over land)
  const custCtx = await browser.newContext({ viewport: { width: W, height: H }, recordVideo: { dir: OUT, size: { width: W, height: H } } });
  const cust = await custCtx.newPage();
  await cust.goto(`${ORIGIN}/chat/${TENANT}?conv=${conv}`, { waitUntil: 'domcontentloaded' });
  await waitComposer(cust, '(operator: customer)');
  await cust.waitForTimeout(800); await snap(cust, 'loaded');
  // customer asks for a human
  const input = cust.locator(COMPOSER);
  await input.click(); await input.fill(DEF.operatorAsk);
  await (cust.getByRole('button', { name: /send|发送/i }).first().click().catch(() => input.press('Enter')));
  await cust.waitForTimeout(2500); await snap(cust, 'customer-asked');
  // operator (separate context, not recorded) takes over + replies
  const opCtx = await browser.newContext({ storageState: opState, viewport: { width: 1100, height: 820 } });
  const op = await opCtx.newPage();
  await op.goto(`${ORIGIN}/operator/${TENANT}/${conv}`, { waitUntil: 'domcontentloaded' });
  await op.locator('#take-over-button').waitFor({ state: 'visible', timeout: 20000 });
  await op.click('#take-over-button');
  await op.waitForTimeout(1500);
  const opInput = op.locator('#chat_text');
  await opInput.waitFor({ state: 'visible', timeout: 10000 });
  await opInput.fill(DEF.operatorReply);
  await op.getByRole('button', { name: /send/i }).first().click().catch(() => opInput.press('Enter'));
  await opCtx.close();
  // back on the customer side: the "客服已接管" badge + operator bubble land live
  await cust.waitForFunction(() => document.body.innerText.includes('客服已接管'), null, { timeout: 20000 }).catch(() => log('takeover badge not seen'));
  await cust.waitForTimeout(2500); await snap(cust, 'taken-over');
  await cust.waitForTimeout(1200);
  return custCtx;
}

async function driveSoul(browser, snap) {
  const adminState = await loginState(browser);
  const convA = `soul-before-${TENANT}`;
  await prewarm(browser, convA, adminState);
  const ctx = await browser.newContext({ storageState: adminState, viewport: { width: W, height: H }, recordVideo: { dir: OUT, size: { width: W, height: H } } });
  const page = await ctx.newPage();
  // BEFORE: ask price with the baseline soul
  await page.goto(`${ORIGIN}/chat/${TENANT}?conv=${convA}`, { waitUntil: 'domcontentloaded' });
  await waitComposer(page, '(soul before)');
  await page.waitForTimeout(800); await snap(page, 'before-loaded');
  await sendAndWaitReply(page, DEF.soulQuestion);
  await snap(page, 'before-reply');
  // EDIT: open the soul editor and change the price fact 39 -> 88
  await page.goto(`${ORIGIN}/plugins/customer-chat/${TENANT}/config`, { waitUntil: 'domcontentloaded' });
  const ta = page.locator('textarea').first();
  await ta.waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForTimeout(800); await snap(page, 'editor');
  const before = await ta.inputValue();
  const after = before.replace(DEF.soulFind, DEF.soulReplace);
  await ta.fill(after);
  await snap(page, 'edited');
  await page.getByRole('button', { name: /save|保存/i }).first().click().catch(() => {});
  await page.waitForTimeout(2000); await snap(page, 'saved');
  // AFTER: a NEW conversation gets a fresh agent that reads the edited soul
  const convB = `soul-after-${TENANT}`;
  await prewarm(browser, convB, adminState); // spawns AFTER the edit -> new soul
  await page.goto(`${ORIGIN}/chat/${TENANT}?conv=${convB}`, { waitUntil: 'domcontentloaded' });
  await waitComposer(page, '(soul after)');
  await page.waitForTimeout(800);
  await sendAndWaitReply(page, DEF.soulQuestion);
  await snap(page, 'after-reply');
  await page.waitForTimeout(1200);
  return ctx;
}

// ---- main -------------------------------------------------------------------
(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  for (const f of fs.readdirSync(OUT)) {
    if (/\.webm$|\.gif$|\.mp4$|^\d\d-.*\.png$/.test(f)) fs.rmSync(`${OUT}/${f}`, { force: true });
  }
  const browser = await chromium.launch({ headless: !HEADED });
  let shot = 0;
  const snap = async (page, name) => { await page.screenshot({ path: `${OUT}/${String(++shot).padStart(2, '0')}-${name}.png` }); };

  log(`MODE=${MODE} TENANT=${TENANT} -> ${OUT}`);
  let recCtx;
  if (MODE === 'chat') recCtx = await driveChat(browser, snap);
  else if (MODE === 'operator') recCtx = await driveOperator(browser, snap);
  else if (MODE === 'soul') recCtx = await driveSoul(browser, snap);
  else throw new Error(`unknown DEMO_MODE: ${MODE}`);

  await recCtx.close(); // finalizes the webm
  await browser.close();

  const vids = fs.readdirSync(OUT).filter((f) => f.endsWith('.webm') && f !== 'demo.webm')
    .map((f) => ({ f, m: fs.statSync(`${OUT}/${f}`).mtimeMs })).sort((a, b) => b.m - a.m);
  if (vids.length) fs.renameSync(`${OUT}/${vids[0].f}`, `${OUT}/demo.webm`);
  log('VIDEO:', fs.existsSync(`${OUT}/demo.webm`) ? `${OUT}/demo.webm` : '(none)');
  log('SHOTS:', fs.readdirSync(OUT).filter((f) => f.endsWith('.png')).join(', '));
})().catch((e) => { console.error('[record-scenario] FATAL', e); process.exit(1); });
