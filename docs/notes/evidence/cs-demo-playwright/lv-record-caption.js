// Record a CAPTIONED .webm of the operator <-> orchestrator demo.
// Captions + a view-label are injected as fixed overlays so they bake into the video.
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const OUTDIR = process.argv[2] || '/tmp/rec';
const ORCH = 'entity://agent/system/cc_orchestrator-main';
const SIZE = { width: 1440, height: 900 };

const STEPS = [
  {
    cap: '① OPERATOR 对编排器说：「列出我可用的模板」',
    msg: `@${ORCH} 你好，请列出我当前可用的 agent 模板和 session 模板。`,
    done: '→ 编排器调用 list_templates 工具，返回真实模板（真 cc-agent + 真 MCP 调用）',
  },
  {
    cap: '② OPERATOR：「加一个 VIP 售前客服坐席」（一句自然语言）',
    msg: `@${ORCH} 请用 add_managed_member 从 template://agent/system/cc-orchestrator 启动一个 VIP 售前客服坐席，role_name=vip_presale_demo，in_session_template=true。加好后简短确认。`,
    done: '→ 编排器调用 add_managed_member、SPAWN 出真 cc 客服 worker、确认成功（右侧 MEMBERS 实时多出成员）',
  },
];

async function setCaption(page, text, sub) {
  await page.evaluate(({ text, sub }) => {
    let bar = document.getElementById('__demo_cap');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = '__demo_cap';
      bar.style.cssText =
        'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;pointer-events:none;background:rgba(8,12,24,.9);' +
        'color:#fff;font:600 25px/1.35 -apple-system,system-ui,sans-serif;padding:18px 30px 96px;' +
        'text-align:center;letter-spacing:.3px;border-top:3px solid #34d399;';
      document.body.appendChild(bar);
      const label = document.createElement('div');
      label.id = '__demo_label';
      label.textContent = '👤 OPERATOR 视角 · 与编排器对话（同一会话；客户→AI 视角待 G-worker）';
      label.style.cssText =
        'position:fixed;left:0;right:0;top:0;z-index:2147483647;pointer-events:none;background:rgba(37,99,235,.92);' +
        'color:#fff;font:600 18px/1.4 -apple-system,system-ui,sans-serif;padding:10px 18px;text-align:center;';
      document.body.appendChild(label);
    }
    bar.innerHTML = text + (sub ? `<div style="font-size:18px;font-weight:400;opacity:.85;margin-top:6px;">${sub}</div>` : '');
  }, { text, sub: sub || '' });
}

async function login(page) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="entity_uri"]', USER);
    await page.fill('input[name="secret"]', PASS);
    await page.click('button[type="submit"]', { noWaitAfter: true });
    await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 20000 }).catch(() => {});
    await page.waitForTimeout(1500);
    if (!String(page.url()).includes('/login')) {
      console.log('login ok (attempt', attempt, ') →', page.url());
      return;
    }
    console.log('login attempt', attempt, 'still on /login, retrying');
  }
  throw new Error('login failed after 3 attempts');
}

async function sendMsg(page, text) {
  const input = page.locator('textarea, input[placeholder*="message"], input[placeholder*="mention"]').first();
  await input.click();
  await input.fill(text);
  await page.waitForTimeout(400);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(250);
  await page.click('button:has-text("Send")', { noWaitAfter: true }).catch(async () => { await input.press('Enter'); });
}

async function orchCount(page) {
  return await page.locator(`text=${ORCH}`).count().catch(() => 0);
}
async function scrollBottom(page) {
  await page.evaluate(() => {
    document.querySelectorAll('[class*="overflow"],main').forEach((el) => (el.scrollTop = el.scrollHeight));
    window.scrollTo(0, document.body.scrollHeight);
  }).catch(() => {});
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: SIZE, recordVideo: { dir: OUTDIR, size: SIZE } });
  const page = await ctx.newPage();
  await login(page);
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);
  await setCaption(page, '电商 AI 客服台 · 对话式编排（真 cc-agent live demo）', '右侧 ORCHESTRATOR=alive、MEMBERS=当前成员');
  await page.waitForTimeout(4000);

  for (const step of STEPS) {
    await setCaption(page, step.cap);
    await page.waitForTimeout(2500);
    const before = await orchCount(page);
    await sendMsg(page, step.msg);
    await setCaption(page, step.cap, '⏳ 编排器思考中（真 claude 处理 + 调 MCP 工具）…');
    const end = Date.now() + 110000;
    while (Date.now() < end) {
      await page.waitForTimeout(3000);
      await scrollBottom(page);
      if ((await orchCount(page)) > before) break;
    }
    await scrollBottom(page);
    await setCaption(page, step.cap, step.done);
    await page.waitForTimeout(7000);
  }

  await setCaption(page, '✅ operator 对话 → 编排器真调工具 → 搭出真客服坐席',
    '⚠️ 下一步 G-worker：客户→AI 回答 + 转人工等 gap（见 PR #538 / 脚本 §3）');
  await page.waitForTimeout(7000);

  const video = page.video();
  await ctx.close();
  console.log('VIDEO:', video ? await video.path() : null);
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
