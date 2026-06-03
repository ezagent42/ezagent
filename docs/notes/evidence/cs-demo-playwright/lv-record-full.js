// Record a COMPLETE captioned demo: operator builds team -> customer asks -> AI answers (+ GAP #1).
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = process.env.LV_USER || 'entity://user/system/admin';
const PASS = process.env.LV_PASS || '8bdemo';
const OUTDIR = process.argv[2] || '/tmp/rec';
const ORCH = 'entity://agent/system/cc_orchestrator-main';
const ROLE = 'presale_full';
const SIZE = { width: 1440, height: 900 };

function overlay(page, role, cap, sub) {
  return page.evaluate(({ role, cap, sub }) => {
    let bar = document.getElementById('__cap');
    let lab = document.getElementById('__lab');
    if (!bar) {
      lab = document.createElement('div'); lab.id = '__lab';
      lab.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:2147483647;pointer-events:none;color:#fff;font:700 19px/1.4 -apple-system,system-ui,sans-serif;padding:11px 18px;text-align:center;';
      document.body.appendChild(lab);
      bar = document.createElement('div'); bar.id = '__cap';
      bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;pointer-events:none;background:rgba(8,12,24,.9);color:#fff;font:600 25px/1.35 -apple-system,system-ui,sans-serif;padding:18px 30px 92px;text-align:center;border-top:3px solid #34d399;';
      document.body.appendChild(bar);
    }
    lab.textContent = role === 'op' ? '👤 运营视角 · 对编排器说话、搭客服团队' : '🛍️ 客户视角 · 咨询 AI 客服';
    lab.style.background = role === 'op' ? 'rgba(37,99,235,.93)' : 'rgba(217,70,239,.93)';
    bar.innerHTML = cap + (sub ? `<div style="font-size:18px;font-weight:400;opacity:.88;margin-top:6px;">${sub}</div>` : '');
  }, { role, cap, sub: sub || '' });
}

async function login(page) {
  for (let a = 1; a <= 3; a++) {
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="entity_uri"]', USER);
    await page.fill('input[name="secret"]', PASS);
    await page.click('button[type="submit"]', { noWaitAfter: true });
    await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 20000 }).catch(() => {});
    await page.waitForTimeout(1500);
    if (!String(page.url()).includes('/login')) return;
  }
  throw new Error('login failed');
}
async function send(page, text) {
  const i = page.locator('textarea, input[placeholder*="message"], input[placeholder*="mention"]').first();
  await i.click(); await i.fill(text); await page.waitForTimeout(400);
  await page.keyboard.press('Escape'); await page.waitForTimeout(250);
  await page.click('button:has-text("Send")', { noWaitAfter: true }).catch(async () => { await i.press('Enter'); });
}
async function scroll(page) { await page.evaluate(() => { document.querySelectorAll('[class*="overflow"],main').forEach(e=>e.scrollTop=e.scrollHeight); }).catch(()=>{}); }
async function count(page, sel) { return page.locator(`text=${sel}`).count().catch(() => 0); }
async function waitReply(page, marker, before, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { await page.waitForTimeout(3000); await scroll(page); if ((await count(page, marker)) > before) return true; }
  return false;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: SIZE, recordVideo: { dir: OUTDIR, size: SIZE } });
  const page = await ctx.newPage();
  await login(page);
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);

  await overlay(page, 'op', '电商 AI 客服台 · 对话式编排（真 cc-agent live）', '运营只靠对编排器说话就能搭客服团队');
  await page.waitForTimeout(4000);

  // ① list templates
  let b = await count(page, ORCH);
  await overlay(page, 'op', '① 运营对编排器：「列出我可用的模板」');
  await page.waitForTimeout(2000);
  await send(page, `@${ORCH} 你好，请列出我当前可用的 agent 模板和 session 模板。`);
  await overlay(page, 'op', '① 运营对编排器：「列出我可用的模板」', '⏳ 编排器处理中…');
  await waitReply(page, ORCH, b, 90000);
  await overlay(page, 'op', '① 运营对编排器：「列出我可用的模板」', '→ 编排器调用 list_templates 工具，返回真实模板');
  await page.waitForTimeout(6000);

  // ② add presale worker
  b = await count(page, ORCH);
  await overlay(page, 'op', '② 运营：「加一个售前 AI 客服坐席」（一句自然语言）');
  await page.waitForTimeout(2000);
  await send(page, `@${ORCH} 请用 add_managed_member 从 template://agent/system/cc-orchestrator 启动一个售前客服坐席，role_name=${ROLE}，in_session_template=true。加好后简短确认。`);
  await overlay(page, 'op', '② 运营：「加一个售前 AI 客服坐席」', '⏳ 编排器调用 add_managed_member、SPAWN 真 worker…');
  await waitReply(page, ORCH, b, 120000);
  await scroll(page);
  await overlay(page, 'op', '② 运营：「加一个售前 AI 客服坐席」', '→ 编排器 spawn 出真 cc 客服 worker、确认成功（右侧 MEMBERS 多出成员）');
  await page.waitForTimeout(7000);

  // extract the worker URI from the page
  const uris = await page.evaluate(() => {
    const re = /entity:\/\/agent\/system\/cc_[a-z0-9_]+-[0-9a-f]+--[0-9a-f]+/g;
    return Array.from(new Set((document.body.innerText.match(re) || [])));
  });
  const worker = uris.find((u) => u.includes(ROLE)) || uris.find((u) => !u.includes('orchestrator'));
  console.log('worker uri:', worker, '(all:', uris.length, ')');
  if (!worker) throw new Error('could not find worker uri on page');

  // ③ customer asks the AI 客服
  b = await count(page, worker.slice(-20));
  await overlay(page, 'cust', '③ 客户咨询售前 AI 客服：「羽绒服 XL 有现货吗？」');
  await page.waitForTimeout(2500);
  await send(page, `@${worker} 你好，请问你们的羽绒服 XL 码有现货吗？`);
  await overlay(page, 'cust', '③ 客户咨询售前 AI 客服：「羽绒服 XL 有现货吗？」', '⏳ AI 客服真处理中…');
  await waitReply(page, worker.slice(-20), b, 120000);
  await scroll(page);
  await overlay(page, 'cust', '③ 售前 AI 客服真回答', '→ 真 cc-agent 生成回复（非脚本、非预设）');
  await page.waitForTimeout(7000);

  // ④ GAP #1
  await overlay(page, 'cust', '④ AI 客服只能用话术周旋，无法真正查库存/订单', '⚠️ GAP #1：运行时给 AI 装「查库存/查订单」技能——对话做不到（skills 是 template-time，需重建 agent）');
  await page.waitForTimeout(9000);

  await overlay(page, 'op', '✅ 运营对话搭团队 → 客户咨询 → AI 真回答，全程真 cc-agent + 真 MCP 工具',
    '更多 gap（转人工/sticky 人工模式/复用模板）见 PR #538 / 脚本 §3');
  await page.waitForTimeout(8000);

  const v = page.video();
  await ctx.close();
  console.log('VIDEO:', v ? await v.path() : null);
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
