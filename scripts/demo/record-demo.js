// Browser-native demo recorder for ezagent PoC (Playwright).
//
// WHY Playwright: it records the *browser's own* compositor output via CDP, so it needs
// NO macOS "Screen Recording" (TCC) permission, captures only the page (no other windows /
// wallpaper), and is fully reproducible from the CLI. See docs/notes/2026-05-31-local-demo-recording.md.
//
// Output: <OUTDIR>/demo.webm  (+ numbered PNG screenshots). Convert to GIF/MP4 with ffmpeg
// (the wrapper record-demo.sh does this for you).
//
// Modes:
//   AUTO (default for the cinnox chat flow): drives /chat/cinnox programmatically —
//       types a question, submits, waits for the AI reply, screenshots the beats.
//   TIMED: set DEMO_SECONDS=N to just record the URL for N seconds (no driving) — use this
//       for flows this script doesn't know how to drive, while you watch/drive a HEADED window.
//
// Env:
//   DEMO_URL       (default http://127.0.0.1:10142/chat/cinnox)
//   DEMO_OUTDIR    (default ./demo-out)
//   DEMO_QUESTION  (default "CINNOX 是做什么的?")
//   DEMO_SECONDS   (if set -> TIMED mode, record this many seconds then stop)
//   DEMO_HEADED    (1 -> headed window; default headless)
//   DEMO_REPLY_TIMEOUT_MS (default 60000 — AI replies take ~20-40s)
//   DEMO_W / DEMO_H (viewport, default 1100x780)
//   --- login (for pages behind /login, e.g. /operator/* and /plugins/*) ---
//   DEMO_LOGIN     (1 -> log in before recording; auto-on if DEMO_USER is set)
//   DEMO_USER      (default "admin")            DEMO_PASS (default "ezagent-dev")
//   DEMO_LOGIN_URL (default <origin>/login)
//   Login runs in a THROWAWAY context; only the session cookie is carried into the recording
//   context, so the login screen is NOT in the video. Typical combo for authed flows:
//     DEMO_LOGIN=1 DEMO_URL=…/operator/cinnox DEMO_SECONDS=15 DEMO_HEADED=1 record-demo.sh
const { chromium } = require('playwright');
const fs = require('fs');

const URL = process.env.DEMO_URL || 'http://127.0.0.1:10142/chat/cinnox';
const OUT = process.env.DEMO_OUTDIR || './demo-out';
const QUESTION = process.env.DEMO_QUESTION || 'CINNOX 是做什么的?';
const SECONDS = process.env.DEMO_SECONDS ? Number(process.env.DEMO_SECONDS) : null;
const HEADED = process.env.DEMO_HEADED === '1';
const REPLY_TIMEOUT = Number(process.env.DEMO_REPLY_TIMEOUT_MS || 60000);
const W = Number(process.env.DEMO_W || 1100), H = Number(process.env.DEMO_H || 780);
const DO_LOGIN = process.env.DEMO_LOGIN === '1' || !!process.env.DEMO_USER;
// NOTE: the bare handle "admin" is NOT accepted by /login on this build (re-renders with an
// error); the FULL entity URI works. Default to it. Override with DEMO_USER if needed.
const LOGIN_USER = process.env.DEMO_USER || 'entity://user/system/admin';
const LOGIN_PASS = process.env.DEMO_PASS || 'ezagent-dev';

const log = (...a) => console.log('[record-demo]', ...a);

// Log in via a throwaway context and return its storageState (session cookie), so the
// recording context starts already authenticated and the login screen never hits the video.
async function loginAndGetState(browser) {
  const origin = new global.URL(URL).origin;
  const loginUrl = process.env.DEMO_LOGIN_URL || origin + '/login';
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  log('logging in at', loginUrl, 'as', LOGIN_USER);
  await p.goto(loginUrl, { waitUntil: 'load', timeout: 30000 });
  // ezagent /login is a LiveView-served page whose POST form is #entity_uri + #secret + "Sign in".
  // The socket connect can wipe inputs filled too early, so settle first, fill, then VERIFY the
  // values stuck (refill if a re-render cleared them) before submitting.
  const uSel = '#entity_uri, input[name="entity_uri"]';
  const pSel = '#secret, input[name="secret"]';
  await p.waitForSelector(uSel, { state: 'visible', timeout: 15000 });
  await p.waitForTimeout(1200); // let LiveView connect & settle
  for (let i = 0; i < 4; i++) {
    await p.fill(uSel, LOGIN_USER);
    await p.fill(pSel, LOGIN_PASS);
    await p.waitForTimeout(300);
    if ((await p.inputValue(uSel)) === LOGIN_USER && (await p.inputValue(pSel)) === LOGIN_PASS) break;
    log('inputs were cleared by a re-render, refilling…');
  }
  await Promise.all([
    p.waitForURL((u) => !String(u).includes('/login'), { timeout: 30000 }).catch(() => {}),
    p.locator(pSel).press('Enter').catch(() =>
      p.getByRole('button', { name: /sign in|登录|登入/i }).click()
        .catch(() => p.locator('button[type="submit"]').click())),
  ]);
  if (p.url().includes('/login')) {
    log('WARN: still on /login after submit — check DEMO_USER/DEMO_PASS (admin/ezagent-dev?)');
  } else {
    log('logged in, landed at', p.url());
  }
  const state = await ctx.storageState();
  await ctx.close();
  return state;
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  // Clean prior artifacts so we never convert/keep a stale recording from a previous run.
  for (const f of fs.readdirSync(OUT)) {
    if (/\.webm$|\.gif$|\.mp4$|^\d\d-.*\.png$/.test(f)) fs.rmSync(`${OUT}/${f}`, { force: true });
  }
  const browser = await chromium.launch({ headless: !HEADED });
  const storageState = DO_LOGIN ? await loginAndGetState(browser) : undefined;
  const context = await browser.newContext({
    viewport: { width: W, height: H },
    recordVideo: { dir: OUT, size: { width: W, height: H } },
    ...(storageState ? { storageState } : {}),
  });
  const page = await context.newPage();
  let shot = 0;
  const snap = async (name) => { await page.screenshot({ path: `${OUT}/${String(++shot).padStart(2,'0')}-${name}.png` }); };

  log('navigating to', URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(e => log('goto warn:', e.message));
  await page.waitForTimeout(1500);
  await snap('loaded');

  if (SECONDS != null) {
    log(`TIMED mode: recording ${SECONDS}s (drive the page yourself if headed)…`);
    await page.waitForTimeout(SECONDS * 1000);
    await snap('end');
  } else {
    // AUTO mode: drive the cinnox chat flow. Selectors are resilient with fallbacks;
    // adjust here if the chat DOM differs.
    try {
      // ezagent chat input (#cc-input) starts DISABLED until the LiveView socket connects and the
      // agent bridge binds — wait for it to become enabled before typing. Falls back to generic.
      const sel = '#cc-input, textarea, input[type="text"], [contenteditable="true"], [role="textbox"]';
      const input = page.locator(sel).first();
      await input.waitFor({ state: 'visible', timeout: 30000 });
      await page.waitForFunction(() => {
        const el = document.querySelector('#cc-input') ||
          document.querySelector('textarea, input[type="text"], [contenteditable="true"], [role="textbox"]');
        return el && !el.disabled;
      }, { timeout: 30000 }).catch(() => log('input still disabled after 30s — trying anyway'));
      await input.click();
      await input.fill(QUESTION).catch(async () => { await input.type(QUESTION, { delay: 30 }); });
      await snap('typed');

      // Submit: prefer a Send button, else press Enter.
      const sendBtn = page.getByRole('button', { name: /send|发送|提交/i }).first();
      if (await sendBtn.count().then(c => c > 0).catch(() => false)) {
        await sendBtn.click();
      } else {
        await input.press('Enter');
      }
      await page.waitForTimeout(800);
      await snap('sent');

      // Wait for the AI reply. ezagent renders messages as children of #cc-messages
      // (phx-update="stream"); the agent reply is a NEW child appended after the user's
      // message. Wait for the child count to grow, THEN for the last bubble's text to stop
      // streaming. (The naive "body text stopped growing" heuristic fires on the user echo —
      // before the 20-40s reply — so don't use it when #cc-messages exists.)
      const hasStream = await page.evaluate(() => !!document.querySelector('#cc-messages'));
      log(`waiting up to ${REPLY_TIMEOUT}ms for AI reply…`);
      if (hasStream) {
        await page.waitForTimeout(1500); // let the user-message echo settle
        const base = await page.evaluate(() => document.querySelector('#cc-messages')?.childElementCount ?? 0);
        log(`messages after send: ${base} — waiting for agent bubble…`);
        await page.waitForFunction(
          (b) => (document.querySelector('#cc-messages')?.childElementCount ?? 0) > b,
          base, { timeout: REPLY_TIMEOUT, polling: 1000 }
        ).catch(() => log('no new bubble within timeout — capturing whatever is there'));
        // wait for the last (agent) bubble to finish streaming
        let last = 0, stableSince = null; const t0 = Date.now();
        while (Date.now() - t0 < 20000) {
          const len = await page.evaluate(() => {
            const el = document.querySelector('#cc-messages')?.lastElementChild;
            return el ? el.innerText.length : 0;
          }).catch(() => last);
          if (len > last + 5) { last = len; stableSince = null; }
          else if (last > 0) { stableSince = stableSince || Date.now(); if (Date.now() - stableSince > 2500) break; }
          await page.waitForTimeout(800);
        }
        await page.evaluate(() => document.querySelector('#cc-messages')?.lastElementChild?.scrollIntoView({ block: 'end' }));
      } else {
        // generic page fallback: body-text growth heuristic
        const start = Date.now(); let lastLen = 0, stableSince = null;
        while (Date.now() - start < REPLY_TIMEOUT) {
          const len = await page.evaluate(() => document.body.innerText.length).catch(() => lastLen);
          if (len > lastLen + 20) { lastLen = len; stableSince = null; }
          else if (lastLen > 0) { stableSince = stableSince || Date.now(); if (Date.now() - stableSince > 3000) break; }
          await page.waitForTimeout(1000);
        }
      }
      await page.waitForTimeout(800);
      await snap('reply');
    } catch (e) {
      log('AUTO driving failed (', e.message, ') — falling back to a 6s passive record.');
      await page.waitForTimeout(6000);
      await snap('fallback-end');
    }
  }

  await context.close();   // finalizes the webm
  await browser.close();

  // Pick the NEWEST webm (Playwright names it with a random hash) and canonicalize to demo.webm.
  const vids = fs.readdirSync(OUT).filter(f => f.endsWith('.webm') && f !== 'demo.webm')
    .map(f => ({ f, m: fs.statSync(`${OUT}/${f}`).mtimeMs })).sort((a, b) => b.m - a.m);
  if (vids.length) { fs.renameSync(`${OUT}/${vids[0].f}`, `${OUT}/demo.webm`); }
  log('VIDEO:', fs.existsSync(`${OUT}/demo.webm`) ? `${OUT}/demo.webm` : '(none produced)');
  log('SHOTS:', fs.readdirSync(OUT).filter(f => f.endsWith('.png')).join(', '));
})().catch(e => { console.error('[record-demo] FATAL', e); process.exit(1); });
