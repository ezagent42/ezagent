// Split-screen demo: LEFT = customer view, RIGHT = operator view (same session, two contexts).
// Records two videos; ffmpeg hstack外部拼接。
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:10042';
const OP_USER = 'entity://user/system/admin';        // 运营
const CUST_USER = 'entity://user/system/customer1';  // 真客户
const PASS = '8bdemo';
const OUTL = process.argv[2] || '/tmp/recL';
const OUTR = process.argv[3] || '/tmp/recR';
const ORCH = 'entity://agent/system/cc_orchestrator-main';
const ROLE = 'presale_real2';
const PANE = { width: 760, height: 900 };

// Overlay redesigned (rev 2): NEVER cover the two real differentiators —
//   (a) top-right avatar button (~x724,y8)   (b) bottom ~85px = input row (y≈820-864) + footer identity (y≈875).
// Instead, role label = top-LEFT pill, narration = floating pill ABOVE the input row,
// and a colored RING actively spotlights the bottom-left footer `entity://user/system/<who>` (the only reliable
// visual differentiator — the composer/input row is identical for both roles in the current admin console = G-ui gap).
function overlay(page, role, cap, sub) {
  return page.evaluate(({ role, cap, sub }) => {
    const isOp = role === 'op';
    const rgb = isOp ? '37,99,235' : '217,70,239';            // blue 运营 / pink 客户
    const who = isOp ? 'user/system/admin' : 'user/system/customer1';
    const title = (isOp ? '👤 运营 · 登录为 ' : '🛍️ 客户 · 登录为 ') + who;
    let lab = document.getElementById('__lab'),
        cb = document.getElementById('__cap'),
        ring = document.getElementById('__ring'),
        tag = document.getElementById('__tag');
    if (!lab) {
      // (1) role label — TOP-LEFT pill (leaves top-right avatar visible)
      lab = document.createElement('div'); lab.id = '__lab';
      lab.style.cssText = 'position:fixed;top:8px;left:8px;max-width:60%;z-index:2147483647;pointer-events:none;'
        + 'color:#fff;font:700 14px/1.3 -apple-system,system-ui,sans-serif;padding:7px 12px;border-radius:9px;'
        + 'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 2px 10px rgba(0,0,0,.3);';
      document.body.appendChild(lab);
      // (2) narration — floating pill ABOVE the input row (bottom:96 clears input + footer)
      cb = document.createElement('div'); cb.id = '__cap';
      cb.style.cssText = 'position:fixed;bottom:96px;left:50%;transform:translateX(-50%);max-width:90%;z-index:2147483647;'
        + 'pointer-events:none;background:rgba(8,12,24,.86);color:#fff;font:600 16px/1.32 -apple-system,system-ui,sans-serif;'
        + 'padding:10px 17px;border-radius:12px;text-align:center;box-shadow:0 4px 18px rgba(0,0,0,.4);';
      document.body.appendChild(cb);
      // (3) identity spotlight — ring around bottom-left footer, kept fully VISIBLE
      ring = document.createElement('div'); ring.id = '__ring';
      ring.style.cssText = 'position:fixed;bottom:3px;left:3px;width:336px;height:24px;z-index:2147483646;'
        + 'pointer-events:none;border-radius:7px;';
      document.body.appendChild(ring);
      tag = document.createElement('div'); tag.id = '__tag';
      tag.style.cssText = 'position:fixed;bottom:30px;left:6px;z-index:2147483647;pointer-events:none;color:#fff;'
        + 'font:700 11px/1.2 -apple-system,system-ui,sans-serif;padding:3px 8px;border-radius:6px;';
      tag.textContent = '↓ 当前登录身份(UI 上唯一可区分处)';
      document.body.appendChild(tag);
    }
    lab.textContent = title;
    lab.style.background = `rgba(${rgb},.96)`;
    ring.style.border = `2.5px solid rgba(${rgb},1)`;
    tag.style.background = `rgba(${rgb},.96)`;
    cb.innerHTML = cap + (sub ? `<div style="font-size:13px;font-weight:400;opacity:.88;margin-top:5px;">${sub}</div>` : '');
  }, { role, cap, sub: sub || '' });
}
async function login(page, user) {
  for (let a = 1; a <= 3; a++) {
    await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="entity_uri"]', user); await page.fill('input[name="secret"]', PASS);
    await page.click('button[type="submit"]', { noWaitAfter: true });
    await page.waitForURL((u) => !String(u).includes('/login'), { timeout: 20000 }).catch(() => {});
    await page.waitForTimeout(1500);
    if (!String(page.url()).includes('/login')) return;
  }
  throw new Error('login failed: ' + user);
}
// Glow the ACTUAL composer element (queried, not coordinate-pinned) so the typed text —
// which differs per role (customer's question vs operator's command) — is highlighted and
// held visible for ~1.8s instead of flashing past in 1-2 frames after an instant fill().
async function inputGlow(page, rgb, on) {
  await page.evaluate(({ rgb, on }) => {
    const i = document.querySelector('textarea, input[placeholder*="message"], input[placeholder*="mention"]');
    if (i) {
      i.style.transition = 'box-shadow .18s ease';
      i.style.borderRadius = '8px';
      i.style.boxShadow = on ? `0 0 0 3px rgba(${rgb},.95), 0 0 16px 3px rgba(${rgb},.7)` : '';
    }
    // While typing, the identity ring+tag sit right under the composer; have them step aside
    // (fade out) so the glowing input is the sole focus, then fade back once input is done.
    ['__ring', '__tag'].forEach((id) => {
      const el = document.getElementById(id);
      if (el) { el.style.transition = 'opacity .25s ease'; el.style.opacity = on ? '0' : '1'; }
    });
  }, { rgb, on }).catch(() => {});
}
async function send(page, text, rgb) {
  const i = page.locator('textarea, input[placeholder*="message"], input[placeholder*="mention"]').first();
  await i.click();
  if (rgb) await inputGlow(page, rgb, true);   // highlight composer BEFORE text lands
  await i.fill(text);
  await page.waitForTimeout(rgb ? 1800 : 400); // hold the typed (highlighted) text visible across many frames
  await page.keyboard.press('Escape'); await page.waitForTimeout(250);
  await page.click('button:has-text("Send")', { noWaitAfter: true }).catch(async () => { await i.press('Enter'); });
  if (rgb) { await page.waitForTimeout(500); await inputGlow(page, rgb, false); }
}
async function scroll(page) { await page.evaluate(() => document.querySelectorAll('[class*="overflow"],main').forEach(e=>e.scrollTop=e.scrollHeight)).catch(()=>{}); }
async function cnt(page, s) { return page.locator(`text=${s}`).count().catch(() => 0); }
async function waitRep(page, m, b, ms) { const e = Date.now()+ms; while (Date.now()<e){ await page.waitForTimeout(3000); await scroll(page); if ((await cnt(page,m))>b) return; } }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctxL = await browser.newContext({ viewport: PANE, recordVideo: { dir: OUTL, size: PANE } });
  const ctxR = await browser.newContext({ viewport: PANE, recordVideo: { dir: OUTR, size: PANE } });
  const L = await ctxL.newPage(), R = await ctxR.newPage();
  await Promise.all([login(L, CUST_USER), login(R, OP_USER)]);
  await Promise.all([L.goto(`${BASE}/sessions`,{waitUntil:'domcontentloaded'}), R.goto(`${BASE}/sessions`,{waitUntil:'domcontentloaded'})]);
  await L.waitForTimeout(2500);
  await overlay(L, 'cust', '电商 AI 客服台'); await overlay(R, 'op', '电商 AI 客服台');
  await L.waitForTimeout(3500);

  // Phase 1: operator builds team (RIGHT active, LEFT waits)
  await overlay(L, 'cust', '客户打开客服窗口', '⏳ 等售前 AI 客服上线…');
  let b = await cnt(R, ORCH);
  await overlay(R, 'op', '① 运营对编排器：「列出可用模板」');
  await R.waitForTimeout(1500); await send(R, `@${ORCH} 请列出我当前可用的 agent 模板和 session 模板。`, '37,99,235');
  await overlay(R, 'op', '① 列出可用模板', '⏳ 编排器调 list_templates…'); await waitRep(R, ORCH, b, 90000);
  await overlay(R, 'op', '① 编排器返回真实模板', '→ 真调 list_templates 工具');
  await R.waitForTimeout(4000);

  const WORKER = process.env.WORKER_URI;
  let worker;
  b = await cnt(R, ORCH);
  if (WORKER) {
    worker = WORKER;
    await overlay(R, 'op', '② 运营：「确认售前 AI 客服已就绪」');
    await R.waitForTimeout(1500); await send(R, `@${ORCH} 我这个会话里已经有一个售前客服坐席(role_name=${ROLE})，请简短确认它在线、可以接待客户。`, '37,99,235');
    await overlay(R, 'op', '② 确认售前客服', '⏳ 编排器确认中…'); await waitRep(R, ORCH, b, 90000);
    await scroll(R); await overlay(R, 'op', '② 售前 AI 客服已就绪', '→ 编排器确认成员在线（右侧 MEMBERS 可见）');
    await R.waitForTimeout(5000);
  } else {
    await overlay(R, 'op', '② 运营：「加一个售前 AI 客服坐席」');
    await R.waitForTimeout(1500); await send(R, `@${ORCH} 请用 add_managed_member 从 template://agent/system/cc-orchestrator 启动一个售前客服坐席，role_name=${ROLE}，in_session_template=true。简短确认。`, '37,99,235');
    await overlay(R, 'op', '② 加售前客服坐席', '⏳ 编排器 add_managed_member、SPAWN 真 worker…'); await waitRep(R, ORCH, b, 120000);
    await scroll(R); await overlay(R, 'op', '② 售前 AI 客服已上线', '→ 真 spawn cc worker（右侧 MEMBERS 多出成员）');
    await R.waitForTimeout(5000);
    worker = null;
    for (let i = 0; i < 15; i++) {
      await R.waitForTimeout(3000); await scroll(R);
      const uris = await R.evaluate(() => { const re=/entity:\/\/agent\/system\/cc_[a-z0-9_]+-[0-9a-f]+--[0-9a-f]+/g; return Array.from(new Set((document.body.innerText.match(re)||[]))); });
      worker = uris.find(u => u.includes(ROLE));
      if (worker) break;
    }
    if (!worker) throw new Error('no worker uri for ' + ROLE);
  }
  console.log('worker:', worker);

  // Phase 2: customer asks (LEFT active, RIGHT shows ready)
  await overlay(R, 'op', '✅ 客服团队已搭好', '运营侧完成，看客户咨询 →');
  await overlay(L, 'cust', '售前 AI 客服已上线，客户开始咨询');
  await L.waitForTimeout(2500);
  b = await cnt(L, worker.slice(-20));
  await overlay(L, 'cust', '③ 客户：「羽绒服 XL 有现货吗？」');
  await L.waitForTimeout(1500); await send(L, `@${worker} 你好，请问你们的羽绒服 XL 码有现货吗？`, '217,70,239');
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
