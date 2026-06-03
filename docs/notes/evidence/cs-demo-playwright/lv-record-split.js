// Split-screen demo: LEFT = customer view, RIGHT = operator view (same session, two contexts).
// Records two videos; ffmpeg hstack外部拼接。
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const USER = 'entity://user/system/admin';
const PASS = '8bdemo';
const OUTL = process.argv[2] || '/tmp/recL';
const OUTR = process.argv[3] || '/tmp/recR';
const ORCH = 'entity://agent/system/cc_orchestrator-main';
const ROLE = 'presale_split';
const PANE = { width: 760, height: 900 };

function overlay(page, role, cap, sub) {
  return page.evaluate(({ role, cap, sub }) => {
    let bar = document.getElementById('__cap'), lab = document.getElementById('__lab');
    if (!bar) {
      lab = document.createElement('div'); lab.id = '__lab';
      lab.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:2147483647;pointer-events:none;color:#fff;font:700 18px/1.4 -apple-system,system-ui,sans-serif;padding:10px 14px;text-align:center;';
      document.body.appendChild(lab);
      bar = document.createElement('div'); bar.id = '__cap';
      bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;pointer-events:none;background:rgba(8,12,24,.92);color:#fff;font:600 20px/1.3 -apple-system,system-ui,sans-serif;padding:14px 18px 88px;text-align:center;border-top:3px solid #34d399;';
      document.body.appendChild(bar);
    }
    lab.textContent = role === 'op' ? '👤 运营视角' : '🛍️ 客户视角';
    lab.style.background = role === 'op' ? 'rgba(37,99,235,.95)' : 'rgba(217,70,239,.95)';
    bar.innerHTML = cap + (sub ? `<div style="font-size:15px;font-weight:400;opacity:.88;margin-top:5px;">${sub}</div>` : '');
  }, { role, cap, sub: sub || '' });
}
async function login(page) {
  for (let a = 1; a <= 3; a++) {
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="entity_uri"]', USER); await page.fill('input[name="secret"]', PASS);
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
async function scroll(page) { await page.evaluate(() => document.querySelectorAll('[class*="overflow"],main').forEach(e=>e.scrollTop=e.scrollHeight)).catch(()=>{}); }
async function cnt(page, s) { return page.locator(`text=${s}`).count().catch(() => 0); }
async function waitRep(page, m, b, ms) { const e = Date.now()+ms; while (Date.now()<e){ await page.waitForTimeout(3000); await scroll(page); if ((await cnt(page,m))>b) return; } }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctxL = await browser.newContext({ viewport: PANE, recordVideo: { dir: OUTL, size: PANE } });
  const ctxR = await browser.newContext({ viewport: PANE, recordVideo: { dir: OUTR, size: PANE } });
  const L = await ctxL.newPage(), R = await ctxR.newPage();
  await Promise.all([login(L), login(R)]);
  await Promise.all([L.goto(`${BASE}/sessions`,{waitUntil:'domcontentloaded'}), R.goto(`${BASE}/sessions`,{waitUntil:'domcontentloaded'})]);
  await L.waitForTimeout(2500);
  await overlay(L, 'cust', '电商 AI 客服台'); await overlay(R, 'op', '电商 AI 客服台');
  await L.waitForTimeout(3500);

  // Phase 1: operator builds team (RIGHT active, LEFT waits)
  await overlay(L, 'cust', '客户打开客服窗口', '⏳ 等售前 AI 客服上线…');
  let b = await cnt(R, ORCH);
  await overlay(R, 'op', '① 运营对编排器：「列出可用模板」');
  await R.waitForTimeout(1500); await send(R, `@${ORCH} 请列出我当前可用的 agent 模板和 session 模板。`);
  await overlay(R, 'op', '① 列出可用模板', '⏳ 编排器调 list_templates…'); await waitRep(R, ORCH, b, 90000);
  await overlay(R, 'op', '① 编排器返回真实模板', '→ 真调 list_templates 工具');
  await R.waitForTimeout(4000);

  b = await cnt(R, ORCH);
  await overlay(R, 'op', '② 运营：「加一个售前 AI 客服坐席」');
  await R.waitForTimeout(1500); await send(R, `@${ORCH} 请用 add_managed_member 从 template://agent/system/cc-orchestrator 启动一个售前客服坐席，role_name=${ROLE}，in_session_template=true。简短确认。`);
  await overlay(R, 'op', '② 加售前客服坐席', '⏳ 编排器 add_managed_member、SPAWN 真 worker…'); await waitRep(R, ORCH, b, 120000);
  await scroll(R); await overlay(R, 'op', '② 售前 AI 客服已上线', '→ 真 spawn cc worker（右侧 MEMBERS 多出成员）');
  await R.waitForTimeout(5000);

  const uris = await R.evaluate(() => { const re=/entity:\/\/agent\/system\/cc_[a-z0-9_]+-[0-9a-f]+--[0-9a-f]+/g; return Array.from(new Set((document.body.innerText.match(re)||[]))); });
  const worker = uris.find(u=>u.includes(ROLE)) || uris.find(u=>!u.includes('orchestrator'));
  console.log('worker:', worker);
  if (!worker) throw new Error('no worker uri');

  // Phase 2: customer asks (LEFT active, RIGHT shows ready)
  await overlay(R, 'op', '✅ 客服团队已搭好', '运营侧完成，看客户咨询 →');
  await overlay(L, 'cust', '售前 AI 客服已上线，客户开始咨询');
  await L.waitForTimeout(2500);
  b = await cnt(L, worker.slice(-20));
  await overlay(L, 'cust', '③ 客户：「羽绒服 XL 有现货吗？」');
  await L.waitForTimeout(1500); await send(L, `@${worker} 你好，请问你们的羽绒服 XL 码有现货吗？`);
  await overlay(L, 'cust', '③ 客户咨询售前 AI 客服', '⏳ AI 客服真处理中…'); await waitRep(L, worker.slice(-20), b, 120000);
  await scroll(L); await overlay(L, 'cust', '③ 售前 AI 客服真回答', '→ 真 cc-agent 生成（非脚本、非预设）');
  await L.waitForTimeout(6000);
  await overlay(L, 'cust', '④ AI 只能话术周旋，查不了真库存', '⚠️ GAP #1：运行时装「查库存」技能对话做不到（skills 是 template-time）');
  await L.waitForTimeout(9000);
  await overlay(L, 'cust', '✅ 客户↔AI 客服', 'PR #538 / 脚本 §3 有更多 gap'); await overlay(R, 'op', '✅ 运营↔编排器', '一句话搭出真客服团队');
  await L.waitForTimeout(6000);

  const vL = L.video(), vR = R.video();
  await Promise.all([ctxL.close(), ctxR.close()]);
  console.log('VIDEO_L:', await vL.path()); console.log('VIDEO_R:', await vR.path());
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
