// World agent-config MVP demo recorder (world plugin React island, Ezagent LiveView).
//
// POST-REVIEW re-record (task-7): records off the STATIC bundle
// (`/assets/world/main.js`) to prove the React island mounts there after the
// vite.config.ts `process.env.NODE_ENV` fix (commit 7e05bb90), and adds a
// second successful no-bot flavor (echo, no PTY).
//
// Scenarios on /identities/agents/new (served via the STATIC bundle):
//   0. STATIC-MOUNT PROOF — capture browser console; assert the contract-shaped
//      form mounted (not the loading spinner) and there is NO
//      `process is not defined` / `WorldRenderer failed to mount`.
//   1. the contract-shaped create form + new caps help `kind.behavior（action 默认 any）`
//   2. create an `echo` agent, NO PTY, empty cwd -> succeeds -> labeled detail
//      (Flavor shows `echo`, not unknown; granted-caps chips)
//   3. create a `curl` agent (no project_cwd) -> succeeds -> labeled detail (Flavor `curl`)
//   4. `cc` agent with EMPTY project_cwd -> server rejects with a VISIBLE
//      operator message ("cc 需要 project_cwd ...") -> no silent drop
//
// World routes are host-scoped (`host: "world."`), so ORIGIN must be the
// world.<host> vhost. Login is the controller-rendered email+password form
// (#email + #password, plain POST). Records the browser compositor -> webm +
// numbered PNGs; ffmpeg transcodes to GIF + MP4.
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

// React island root for each surface. Scope to <section> — the LiveView mount
// <div id="world-root"> carries the same data-world-component attribute, so a
// bare attribute selector is ambiguous (strict-mode violation).
const NEW_FORM = 'section[data-world-component="agent_new_form"]';
const DETAIL = 'section[data-world-component="agent_detail"]';

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
    if (/\.webm$|\.gif$|\.mp4$|^s\d\d-.*\.png$|^console-log\.txt$/.test(f)) {
      fs.rmSync(`${OUT}/${f}`, { force: true });
    }
  }
  const browser = await chromium.launch({ headless: !HEADED });
  let shot = 0;
  const snap = async (page, name) => {
    const f = `${OUT}/s${String(++shot).padStart(2, '0')}-${name}.png`;
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

  // --- Console capture for the STATIC-MOUNT proof (#3) ---
  const consoleLines = [];
  page.on('console', (msg) => consoleLines.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err) => consoleLines.push(`[pageerror] ${err.message}`));

  // --- Scenario 0+1: static mount proof + contract-shaped form ---
  log('scenario 0/1: static-bundle mount + create form');
  await gotoNew(page);
  // assert the form mounted (not the spinner) by reading the live DOM
  const mounted = await page.locator(NEW_FORM).isVisible();
  const bodyText = await page.locator('body').innerText();
  const sawSpinner = /loading|加载中/i.test(bodyText) && !mounted;
  log('mounted=', mounted, 'sawSpinner=', sawSpinner);
  await snap(page, 'static-form');

  // --- Scenario 2: create an echo agent (no PTY, empty cwd) -> detail ---
  const echoName = `demo-echo-${TS}`;
  log('scenario 2: create echo agent (no pty)', echoName);
  await page.selectOption(`${NEW_FORM} select`, 'echo').catch(() => {});
  await page.fill(`${NEW_FORM} input[placeholder="storefront-greeter"]`, echoName);
  // Leave Requested caps EMPTY for echo. The Echo Kind (Ezagent.Entity.Echo)
  // composes only Behavior.Echo — it does NOT mount the Identity behavior, so
  // dispatching `identity.grant_cap` to it fails `{:unknown_action,:grant_cap}`.
  // (curl reuses the shared Entity.Agent, which DOES mount Identity, so curl
  // tolerates requested caps.) Filed as a follow-up; with no requested caps the
  // create skips the grant step (grant_initial_caps([]) -> :ok) and succeeds —
  // a clean second no-bot flavor. See task-7 report.
  // leave project_cwd EMPTY; with_pty stays UNCHECKED -> cwd not required
  await page.waitForTimeout(500);
  await page.locator(`${NEW_FORM} button[type="submit"]`).click();
  await page.waitForSelector(DETAIL, { state: 'visible', timeout: 20000 })
    .catch(() => log('WARN: echo detail island not seen'));
  await liveConnected(page);
  await page.waitForTimeout(1200);
  await snap(page, 'echo-detail');

  // --- Scenario 3: create a curl agent (no cwd) -> detail ---
  const curlName = `demo-curl-${TS}`;
  log('scenario 3: create curl agent', curlName);
  await gotoNew(page);
  await page.selectOption(`${NEW_FORM} select`, 'curl').catch(() => {});
  await page.fill(`${NEW_FORM} input[placeholder="storefront-greeter"]`, curlName);
  await page.fill(`${NEW_FORM} input[placeholder*="chat.send"]`, 'chat.send, workspace.read');
  await page.waitForTimeout(500);
  await page.locator(`${NEW_FORM} button[type="submit"]`).click();
  await page.waitForSelector(DETAIL, { state: 'visible', timeout: 20000 })
    .catch(() => log('WARN: curl detail island not seen'));
  await liveConnected(page);
  await page.waitForTimeout(1200);
  await snap(page, 'curl-detail');

  // --- Scenario 4: cc agent, EMPTY cwd -> visible error (no silent drop) ---
  const ccName = `demo-cc-${TS}`;
  log('scenario 4: cc agent empty cwd ->', ccName);
  await gotoNew(page);
  await page.selectOption(`${NEW_FORM} select`, 'cc').catch(() => {});
  await page.fill(`${NEW_FORM} input[placeholder="storefront-greeter"]`, ccName);
  // leave project_cwd EMPTY (cc requires it)
  await page.waitForTimeout(400);
  // The Create button is client-disabled when cwd is required+empty, by design.
  // Submit through the form's requestSubmit to prove the SERVER-side guard.
  await page.evaluate(() => {
    const form = document.querySelector('#world-agent-new-form');
    if (form) form.requestSubmit
      ? form.requestSubmit()
      : form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  await page.waitForFunction(
    (sel) => {
      const el = document.querySelector(sel);
      return el && /project_cwd|需要/.test(el.textContent || '');
    },
    `${NEW_FORM} [role="alert"]`, { timeout: 15000 }
  ).catch(() => log('WARN: create_error alert not detected'));
  await page.waitForTimeout(900);
  await snap(page, 'cc-error');

  await page.waitForTimeout(1200);

  // --- Persist the console log for the static-mount proof ---
  const badRe = /process is not defined|WorldRenderer failed to mount|ReferenceError/i;
  const offenders = consoleLines.filter((l) => badRe.test(l));
  const header = [
    `# Static-bundle (/assets/world/main.js) console capture`,
    `# origin: ${ORIGIN}`,
    `# form mounted: ${mounted}  spinner-stuck: ${sawSpinner}`,
    `# offending lines (process/ReferenceError/mount-fail): ${offenders.length}`,
    offenders.length ? `# OFFENDERS:\n${offenders.join('\n')}` : `# OFFENDERS: none (clean mount)`,
    `# --- full console ---`,
  ].join('\n');
  fs.writeFileSync(`${OUT}/console-log.txt`, header + '\n' + consoleLines.join('\n') + '\n');
  log('CONSOLE: mounted=', mounted, 'offenders=', offenders.length);

  const video = page.video();
  await ctx.close();
  if (video) {
    const vp = await video.path();
    fs.renameSync(vp, `${OUT}/demo.webm`);
  }
  await browser.close();
  log('VIDEO:', fs.existsSync(`${OUT}/demo.webm`) ? `${OUT}/demo.webm` : '(none)');
  log('SHOTS:', fs.readdirSync(OUT).filter((f) => f.endsWith('.png')).join(', '));
  if (offenders.length) { console.error('[record-agentcfg] STATIC-MOUNT OFFENDERS PRESENT'); }
})().catch((e) => { console.error('[record-agentcfg] FATAL', e); process.exit(1); });
