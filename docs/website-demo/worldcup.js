/* ============================================================================
 * worldcup.js · 路线图押注（迁移自 03-demo-路线图押注，reskin 到 ezagent-design DS）
 * ----------------------------------------------------------------------------
 * Step 1：骨架 + 数据(EZ.worldcup() roadmap) + 3 视图(价值/时间线/场景) display。
 * 后续 Step：L1 我要用 / L2 看多看空 / 双榜 / 提需求 / 结算 / 分享卡。
 * 无 emoji（DS 禁），用文字 + 几何 SVG glyph。渲染进 #wc-root。
 * ========================================================================== */
(function () {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };

  // ── DS 样式（token 来自 index.html 的 :root；这里只加 world.cup 专属类）──────
  const CSS = `
  #wc-root{margin-top:18px}
  .wc-viewbar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  .wc-tabs{display:inline-flex;background:var(--ground-2);border-radius:var(--r-pill);padding:4px;gap:4px}
  .wc-tabs button{appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;color:var(--ink-2);padding:9px 16px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-tabs button:hover:not(.on){color:var(--ink)}
  .wc-tabs button.on{background:var(--accent);color:var(--on-accent);box-shadow:var(--shadow-accent)}
  .wc-hint{font-family:var(--font-mono);font-size:11px;letter-spacing:.04em;color:var(--ink-3);margin:0 0 18px}
  .wc-group{font-family:var(--font-mono);font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);margin:22px 0 12px;display:flex;align-items:center;gap:8px}
  .wc-group b{color:var(--ink-2)}
  .wc-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:var(--gap-grid)}
  .wc-card{background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:18px 20px;display:flex;flex-direction:column;gap:11px}
  .wc-h{display:flex;align-items:flex-start;justify-content:space-between;gap:10px}
  .wc-title{font-family:var(--font-cn-ui);font-weight:600;font-size:15.5px;line-height:1.4;color:var(--ink)}
  .wc-stage{flex:none;display:inline-flex;align-items:center;gap:6px;font-family:var(--font-mono);font-size:10.5px;font-weight:700;letter-spacing:.03em;color:var(--ink-2);background:var(--ground-2);padding:4px 10px;border-radius:var(--r-pill)}
  .wc-stage i{width:7px;height:7px;border-radius:50%;background:var(--c,var(--ink-4))}
  .wc-chips{display:flex;gap:7px;flex-wrap:wrap}
  .wc-chip{font-family:var(--font-mono);font-size:11px;color:var(--ink-2);background:var(--ground-2);padding:3px 9px;border-radius:var(--r-pill)}
  .wc-chip b{color:var(--accent-press)}
  .wc-wmeta{display:flex;justify-content:space-between;font-family:var(--font-mono);font-size:11px;color:var(--ink-3)}
  .wc-wmeta .ok{color:var(--jade)}
  .wc-prog{height:7px;border-radius:var(--r-pill);background:var(--ground-2);overflow:hidden}
  .wc-prog>i{display:block;height:100%;background:var(--accent);border-radius:var(--r-pill);transition:width .4s var(--ease-out)}
  .wc-merged{font-family:var(--font-mono);font-size:12px;color:var(--jade);display:flex;align-items:center;gap:7px}
  .wc-merged::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--jade)}
  /* gantt */
  .wc-gantt{background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:24px 26px;overflow-x:auto}
  .wc-gchart{position:relative;min-width:680px}
  .wc-gbg{position:absolute;left:0;right:0;top:30px;bottom:0;display:grid;grid-template-columns:repeat(4,1fr);z-index:0;pointer-events:none}
  .wc-gbg span{border-left:1px solid var(--line)}.wc-gbg span:first-child{border-left:0}
  .wc-gyears{display:grid;grid-template-columns:repeat(4,1fr);margin-bottom:16px;position:relative;z-index:1}
  .wc-gyears span{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);padding-left:8px}
  .wc-grow{position:relative;z-index:1;margin-bottom:16px}
  .wc-glabel{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--ink);margin-bottom:7px;font-weight:500}
  .wc-glabel .nid{font-family:var(--font-mono);font-size:10px;color:var(--ink-3)}
  .wc-track{position:relative;height:10px}
  .wc-seg{position:absolute;height:10px;border-radius:var(--r-pill)}
  .wc-seg.issue{background:var(--ink-4)} .wc-seg.pr{background:var(--orange)} .wc-seg.merge{background:var(--jade)}
  .wc-seg.proj{opacity:.32;background-image:repeating-linear-gradient(45deg,rgba(0,0,0,.18) 0 4px,transparent 4px 8px)}
  .wc-glegend{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin-bottom:18px}
  .wc-glegend b.i{color:var(--ink-4)} .wc-glegend b.p{color:var(--orange)} .wc-glegend b.m{color:var(--jade)}
  /* L1 我要用 */
  .wc-want{display:flex;align-items:center;gap:12px}
  .wc-wantbtn{appearance:none;border:0;cursor:pointer;flex:none;font-family:inherit;font-size:13px;font-weight:700;color:var(--accent-press);background:var(--accent-wash);padding:9px 15px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-wantbtn:hover{background:var(--accent);color:var(--on-accent)}
  .wc-wantbtn.on{background:var(--jade-wash);color:var(--jade)}
  .wc-wantwrap{flex:1;min-width:0}
  .wc-miniact{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
  .wc-ibtn{appearance:none;border:0;cursor:pointer;font-family:var(--font-mono);font-size:11px;font-weight:700;color:var(--ink-2);background:var(--ground-2);padding:7px 12px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-ibtn:hover{background:var(--ground-hover);color:var(--ink)}
  .wc-ibtn.on{background:var(--accent-wash);color:var(--accent-press)}
  .wc-ibtn.like.on{background:var(--red-wash);color:var(--red)}
  /* modal + toast */
  .wc-mask{position:fixed;inset:0;background:rgba(15,15,20,.5);backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px);display:grid;place-items:center;z-index:200;padding:20px}
  .wc-modal{position:relative;background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);max-width:420px;width:100%;padding:28px 30px}
  .wc-modal.wide{max-width:560px}
  .wc-modal h3{font-family:var(--font-cn);font-weight:600;font-size:20px;margin:0;color:var(--ink)}
  .wc-modal .x{position:absolute;top:14px;right:18px;cursor:pointer;color:var(--ink-3);font-size:22px;line-height:1;font-family:var(--font-ui)}
  .wc-modal .x:hover{color:var(--ink)}
  .wc-field{margin-top:14px}
  .wc-field label{display:block;font-size:13px;font-weight:500;color:var(--ink-2);margin-bottom:7px}
  .wc-field input,.wc-field select{width:100%;box-sizing:border-box;padding:12px 14px;border:0;border-radius:var(--r-md);background:var(--ground-2);font-family:var(--font-ui);font-size:15px;color:var(--ink);box-shadow:inset 0 0 0 1px var(--line)}
  .wc-field input:focus,.wc-field select:focus{outline:none;box-shadow:0 0 0 3px var(--focus-ring)}
  .wc-mbtn{width:100%;appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:15px;padding:13px;border-radius:var(--r-pill);background:var(--accent);color:var(--on-accent);margin-top:16px;transition:background 150ms,transform 150ms}
  .wc-mbtn:hover{background:var(--accent-hover);transform:translateY(-1px)}
  .wc-mnote{color:var(--ink-3);font-size:11px;text-align:center;margin-top:10px;font-family:var(--font-mono)}
  .wc-msub{color:var(--ink-2);font-size:13px;margin:4px 0 0;line-height:1.5}
  .wc-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%) translateY(20px);background:var(--ink);color:var(--card);font-size:13.5px;padding:12px 20px;border-radius:var(--r-pill);box-shadow:var(--shadow-card);z-index:300;opacity:0;pointer-events:none;transition:all .25s var(--ease-out)}
  .wc-toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
  .wc-empty{color:var(--ink-3);font-size:14px;line-height:1.6;padding:18px;text-align:center}
  /* status bar */
  .wc-status{display:flex;align-items:center;gap:0;flex-wrap:wrap;background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:14px 14px;margin-bottom:16px}
  .wc-stat{padding:4px 18px}
  .wc-stat.click{cursor:pointer;border-radius:var(--r-md);transition:background 150ms}
  .wc-stat.click:hover{background:var(--ground-2)}
  .wc-stat .n{font-family:var(--font-ui);font-weight:800;font-size:18px;letter-spacing:-.01em;color:var(--ink);display:flex;align-items:baseline;gap:5px}
  .wc-stat .n .u{font-size:11px;font-weight:500;color:var(--ink-3);font-family:var(--font-mono)}
  .wc-stat .k{font-family:var(--font-mono);font-size:10px;letter-spacing:.03em;color:var(--ink-3);margin-top:2px}
  .wc-sep{width:1px;align-self:stretch;background:var(--line);margin:4px 0}
  .wc-status .sp{flex:1}
  .wc-status .gold{appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:700;font-size:13px;color:var(--ink);background:var(--yellow-wash);padding:9px 16px;border-radius:var(--r-pill);transition:background 150ms}
  .wc-status .gold:hover{background:var(--yellow)}
  /* L2 看多看空 */
  .wc-l2{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:2px;padding-top:12px;border-top:1px solid var(--line)}
  .wc-l2t{font-family:var(--font-mono);font-size:10px;color:var(--ink-3);flex:1;min-width:130px}
  .wc-l2btn{appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:12px;font-weight:700;padding:7px 12px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-l2btn b{font-family:var(--font-mono);margin-left:4px}
  .wc-l2btn.long{background:var(--jade-wash);color:var(--jade)}
  .wc-l2btn.long:hover,.wc-l2btn.long.staked{box-shadow:inset 0 0 0 1.5px var(--jade)}
  .wc-l2btn.short{background:var(--red-wash);color:var(--red)}
  .wc-l2btn.short:hover,.wc-l2btn.short.staked{box-shadow:inset 0 0 0 1.5px var(--red)}
  /* bet modal */
  .wc-betpick{font-size:13px;color:var(--ink-2);margin:8px 0 12px}
  .wc-amtrow{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
  .wc-amtb{appearance:none;border:0;cursor:pointer;font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink-2);background:var(--ground-2);padding:9px 14px;border-radius:var(--r-pill);transition:all 150ms}
  .wc-amtb.on{background:var(--accent);color:var(--on-accent)}
  .wc-winline{font-size:13px;color:var(--ink-2)}.wc-winline b{color:var(--ink)}
  .wc-predrow{display:flex;gap:10px;margin-top:12px}
  .wc-bigchoice{flex:1;appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:14px;font-weight:700;padding:18px;border-radius:var(--r-md);display:flex;flex-direction:column;gap:5px;transition:all 150ms}
  .wc-bigchoice b{font-family:var(--font-mono);font-size:18px}
  .wc-bigchoice.long{background:var(--jade-wash);color:var(--jade)}.wc-bigchoice.long:hover{box-shadow:inset 0 0 0 2px var(--jade)}
  .wc-bigchoice.short{background:var(--red-wash);color:var(--red)}.wc-bigchoice.short:hover{box-shadow:inset 0 0 0 2px var(--red)}
  /* positions / want list */
  .wc-poslist{display:flex;flex-direction:column;gap:10px}
  .wc-posrow{display:flex;align-items:center;gap:12px;background:var(--ground-2);border-radius:var(--r-md);padding:12px 15px}
  .wc-posrow .pt{font-size:14px;font-weight:600;color:var(--ink)}
  .wc-posrow .ps{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin-top:3px}
  .wc-posrow .right{margin-left:auto;text-align:right}
  .wc-posrow .pa{font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink)}
  .wc-ptag{flex:none;font-family:var(--font-mono);font-size:10px;font-weight:700;padding:4px 9px;border-radius:var(--r-pill)}
  .wc-ptag.pr{background:var(--orange-wash);color:var(--orange)}
  .wc-ptag.live{background:var(--jade-wash);color:var(--jade)}
  .wc-ptag.issue{background:var(--red-wash);color:var(--red)}
  .wc-ptag.merged{background:var(--ground-hover);color:var(--ink-3)}
  /* leaderboard */
  .wc-lbtabs{display:flex;gap:6px}
  .wc-lbtabs button{appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;color:var(--ink-2);background:var(--ground-2);padding:8px 14px;border-radius:var(--r-pill)}
  .wc-lbtabs button.on{background:var(--accent);color:var(--on-accent)}
  .wc-lbrow{display:flex;align-items:center;gap:14px;padding:11px 10px;border-bottom:1px solid var(--line)}
  .wc-lbrow.me{background:var(--accent-wash);border-radius:var(--r-md);border-bottom:0}
  .wc-lbrow .rk{font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink-3);width:22px}
  .wc-lbrow .nm{font-size:14px;font-weight:600;color:var(--ink);flex:1}
  .wc-lbrow .mt2{font-family:var(--font-mono);font-size:12px;color:var(--ink-2)}
  /* ticker */
  .wc-ticker{overflow:hidden;background:var(--card);border-radius:var(--r-pill);box-shadow:var(--shadow-sm);padding:10px 0;margin-bottom:16px;white-space:nowrap;-webkit-mask-image:linear-gradient(90deg,transparent,#000 5%,#000 95%,transparent);mask-image:linear-gradient(90deg,transparent,#000 5%,#000 95%,transparent)}
  .wc-ticker .tk{display:inline-block;animation:wc-scroll 30s linear infinite}
  .wc-ev{display:inline-flex;align-items:center;gap:7px;margin:0 26px;font-size:12.5px;color:var(--ink-2)}
  .wc-ev::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--jade)}
  .wc-ev .pr{font-family:var(--font-mono);color:var(--accent-press);font-weight:700}
  .wc-ev b{color:var(--ink);font-weight:600}
  @keyframes wc-scroll{from{transform:translateX(0)}to{transform:translateX(-50%)}}
  @media (prefers-reduced-motion:reduce){.wc-ticker .tk{animation:none}}
  /* propose */
  .wc-propose{appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:13px;color:var(--accent-press);background:var(--accent-wash);padding:9px 16px;border-radius:var(--r-pill);margin-left:auto;transition:all 150ms}
  .wc-propose:hover{background:var(--accent);color:var(--on-accent)}
  /* demo 控制条 */
  .wc-dembar{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:150;display:flex;align-items:center;gap:10px;padding:9px 14px 9px 16px;border-radius:var(--r-pill);background:var(--glass-bg);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur);box-shadow:var(--shadow-card),var(--glass-edge)}
  body:not([data-page="worldcup"]) .wc-dembar{display:none}
  .wc-dembar .dnote{font-family:var(--font-mono);font-size:10px;color:var(--ink-3)}
  .wc-dembtn{appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:13px;padding:9px 15px;border-radius:var(--r-pill);transition:all 150ms}
  .wc-dembtn.ff{background:var(--orange-wash);color:var(--orange)}.wc-dembtn.ff:hover{background:var(--orange);color:#fff}
  .wc-dembtn.merge{background:var(--ground-2);color:var(--ink)}.wc-dembtn.merge:hover{background:var(--ground-hover)}
  /* 分享卡 */
  .wc-sharecard{background:#14131C;border-radius:var(--r-lg);padding:26px 26px 22px;color:#F4F2EC;position:relative;overflow:hidden}
  .wc-sharecard .sc-num{position:absolute;top:18px;right:20px;font-family:var(--font-mono);font-size:11px;color:#85837B}
  .wc-sharecard .sc-eye{font-family:var(--font-mono);font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--blue)}
  .wc-sharecard .sc-badge{display:inline-block;margin-top:10px;font-family:var(--font-mono);font-size:11px;font-weight:700;background:var(--blue);color:#fff;padding:4px 11px;border-radius:var(--r-pill)}
  .wc-sharecard .sc-title{font-family:var(--font-cn);font-weight:600;font-size:23px;margin:12px 0 4px;line-height:1.3}
  .wc-sharecard .sc-sub{font-size:13px;color:#B6B4AC}
  .wc-sharecard .sc-lines{margin:16px 0 12px}
  .wc-sharecard .sc-line{display:flex;justify-content:space-between;gap:12px;font-size:13px;color:#B6B4AC;border-top:1px solid rgba(255,255,255,.08);padding:9px 0}
  .wc-sharecard .sc-line b{color:#fff}
  .wc-sharecard .sc-cta{font-size:12.5px;color:#5AA2FF;margin-top:4px}
  .wc-sharecard .sc-brand{margin-top:16px;font-family:var(--font-mono);font-size:10px;color:#56544D}
  .wc-sharebtns{display:flex;gap:10px;margin-top:16px}
  .wc-sharebtns .b{flex:1;appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:14px;padding:12px;border-radius:var(--r-pill);transition:all 150ms}
  .wc-sharebtns .b.g{background:var(--ground-2);color:var(--ink)}.wc-sharebtns .b.g:hover{background:var(--ground-hover)}
  .wc-sharebtns .b.gold{background:var(--accent);color:var(--on-accent)}.wc-sharebtns .b.gold:hover{background:var(--accent-hover)}
  .wc-ffstage{text-align:center;padding:22px 0 6px}
  .wc-ffbig{font-family:var(--font-cn);font-weight:600;font-size:36px}
  @media (max-width:860px){.wc-grid{grid-template-columns:1fr}.wc-predrow{flex-direction:column}}
  `;
  if (!$('#wc-style')) { const s = el('style'); s.id = 'wc-style'; s.textContent = CSS; document.head.appendChild(s); }

  // ── 状态 ────────────────────────────────────────────────────────────────
  let ITEMS = [];
  const item = (id) => ITEMS.find((i) => i.id === id);
  const myWant = new Set(), liked = new Set(), subscribed = new Set();
  let myEmail = '';

  // L2 账本 / 仓位 / 市场（同注分彩）
  const fmt = (n) => Math.round(n).toLocaleString();
  const LEDGER = { renown: 1000, hits: 0, misses: 0 };
  let POSITIONS = [];   // {marketId, sideKey, amount, lockedOdds, status:'open'|'won'|'lost'}
  let MARKETS = [];
  function buildMarkets() {
    ITEMS.filter((i) => i.stage !== 'merged').forEach((i) => {
      if (MARKETS.find((m) => m.itemId === i.id)) return;
      const lean = i.waitlist / i.unlockAt;
      MARKETS.push({ id: 'm' + i.id.slice(1), itemId: i.id, status: 'open', hotAt: i.unlockAt,
        sides: [{ key: 'long', label: '看多 · 会火', pool: Math.round(300 + lean * 500) },
                { key: 'short', label: '看空 · 火不起来', pool: Math.round(360 - lean * 120) }] });
    });
  }
  const mkById = (id) => MARKETS.find((m) => m.id === id);
  const marketFor = (it) => MARKETS.find((m) => m.itemId === it.id && m.status === 'open');
  const itemOfMarket = (mk) => item(mk.itemId);
  function odds(m, sideKey) { const tot = m.sides.reduce((s, x) => s + x.pool, 0); const s = m.sides.find((x) => x.key === sideKey); return Math.max(1.05, tot / s.pool); }
  function stake(marketId, sideKey, amount) {
    if (amount > LEDGER.renown) return { ok: false, msg: '声望不足' };
    const m = mkById(marketId), lockedOdds = odds(m, sideKey);
    LEDGER.renown -= amount; m.sides.find((x) => x.key === sideKey).pool += amount;
    POSITIONS.push({ marketId, sideKey, amount, lockedOdds, status: 'open' });
    return { ok: true, lockedOdds };
  }
  function settle(marketId, winKey) {
    const m = mkById(marketId); if (!m) return; m.status = 'settled'; m.winKey = winKey;
    POSITIONS.filter((p) => p.marketId === marketId && p.status === 'open').forEach((p) => {
      if (p.sideKey === winKey) { p.status = 'won'; LEDGER.renown += p.amount * p.lockedOdds; LEDGER.hits++; }
      else { p.status = 'lost'; LEDGER.misses++; }
    });
  }
  const myStakeOn = (mid, sk) => POSITIONS.filter((p) => p.marketId === mid && p.sideKey === sk).reduce((s, p) => s + p.amount, 0);

  // 双榜（眼光榜=命中率，声望榜=总声望）+ 提需求序号 + 滚动事件
  const RIVALS = [
    { name: '盯盘老张', renown: 4820, hits: 31, misses: 9 }, { name: 'eyes_of_qa', renown: 3110, hits: 22, misses: 11 },
    { name: '押注狂魔', renown: 5950, hits: 18, misses: 26 }, { name: '@mia', renown: 2440, hits: 14, misses: 6 },
    { name: '冷静观察者', renown: 1890, hits: 9, misses: 3 }, { name: '@kev', renown: 2760, hits: 17, misses: 14 },
    { name: 'all_in_dev', renown: 980, hits: 5, misses: 12 }, { name: '稳健派', renown: 1620, hits: 11, misses: 7 },
    { name: '梭哈一时爽', renown: 6300, hits: 20, misses: 30 }, { name: '信号挖掘机', renown: 3540, hits: 25, misses: 8 },
  ];
  const MIN_BETS = 5;
  const totalBets = (x) => x.hits + x.misses;
  const hitRate = (x) => (totalBets(x) ? x.hits / totalBets(x) : 0);
  const you = () => ({ name: '你', renown: LEDGER.renown, hits: LEDGER.hits, misses: LEDGER.misses, me: true });
  const eyeRank = () => { const me = you(); return RIVALS.filter((r) => totalBets(r) >= MIN_BETS && hitRate(r) > hitRate(me)).length + 1; };
  const renownRank = () => RIVALS.filter((r) => r.renown > LEDGER.renown).length + 1;
  let SEQ = 137;
  let TICKER_EVENTS = [
    { pr: '#312', txt: '已合并 → 候补 210 破阈值，看多通吃' },
    { pr: '#333', txt: '已合并 → 早期「我要用」者收到上线通知' },
    { pr: '#366', txt: '候补冲上 138/150 · 看多赔率跳水' },
  ];

  const STAGE = {
    issue:  { cn: 'Issue · 想做',   c: 'var(--ink-4)' },
    pr:     { cn: 'PR · 在做',      c: 'var(--orange)' },
    merged: { cn: 'Merged · 已上线', c: 'var(--jade)' },
  };
  const STAGE_ORD = { issue: 0, pr: 1, merged: 2 };
  const byStage = (a, b) => STAGE_ORD[a.stage] - STAGE_ORD[b.stage];

  // ── 视图 ────────────────────────────────────────────────────────────────
  let view = 'value';
  const VIEWS = [
    { k: 'value',    label: '价值' },
    { k: 'timeline', label: '时间线' },
    { k: 'scenario', label: '场景' },
  ];
  const VIEW_HINT = {
    value:    '按战略定位分组 · 同一批需求按 Issue → PR → Merge 排列',
    timeline: '按阶段看：计划 (Issue) → 在做 (PR) → 已上线战报 (Merged)',
    scenario: '按场景归类（连接 / 稳定 / 生成 / 定制 …），只看跟你相关的那块',
  };

  // ── item 卡（display-only · Step 1）──────────────────────────────────────
  function stageTag(s) { return `<span class="wc-stage" style="--c:${STAGE[s].c}"><i></i>${STAGE[s].cn}</span>`; }
  // L1 我要用（交互）
  function l1(it) {
    if (it.stage === 'merged') {
      const lk = liked.has(it.id);
      return `<div class="wc-miniact">
        <button class="wc-ibtn like ${lk ? 'on' : ''}" data-like="${it.id}">${lk ? '已赞' : '点赞'}</button>
        <button class="wc-ibtn" data-try="${it.id}">试玩</button>
        <span class="wc-merged">已上线 · ${it.prRef || it.id}</span>
      </div>`;
    }
    const want = myWant.has(it.id);
    const pct = Math.min(100, Math.round((it.waitlist / it.unlockAt) * 100));
    const unlocked = it.waitlist >= it.unlockAt;
    const sub = it.stage === 'pr' ? `<button class="wc-ibtn ${subscribed.has(it.id) ? 'on' : ''}" data-sub="${it.id}">${subscribed.has(it.id) ? '已订阅上线' : '订阅上线'}</button>` : '';
    return `<div class="wc-want">
      <button class="wc-wantbtn ${want ? 'on' : ''}" data-want="${it.id}">${want ? '✓ 我要用' : '我要用'}</button>
      <div class="wc-wantwrap">
        <div class="wc-wmeta"><span>候补 ${it.waitlist} / ${it.unlockAt}</span>${unlocked ? '<span class="ok">已解锁，团队评估中</span>' : `<span>再 ${it.unlockAt - it.waitlist} 人</span>`}</div>
        <div class="wc-prog"><i style="width:${pct}%"></i></div>
      </div>
    </div>
    <div class="wc-miniact"><button class="wc-ibtn" data-invite="${it.id}">拉同行凑人解锁</button>${sub}</div>`;
  }
  // L2 看多看空（次要、紧凑）
  function secondLayer(it) {
    const mk = marketFor(it); if (!mk) return '';
    const sl = myStakeOn(mk.id, 'long'), ss = myStakeOn(mk.id, 'short');
    return `<div class="wc-l2">
      <span class="wc-l2t">押声望赌它会不会火（候补破 ${mk.hotAt}）</span>
      <button class="wc-l2btn long ${sl > 0 ? 'staked' : ''}" data-bet="${mk.id}|long">看多<b>${odds(mk, 'long').toFixed(2)}×</b></button>
      <button class="wc-l2btn short ${ss > 0 ? 'staked' : ''}" data-bet="${mk.id}|short">看空<b>${odds(mk, 'short').toFixed(2)}×</b></button>
    </div>`;
  }
  function itemCard(it) {
    return `<div class="wc-card" data-id="${it.id}">
      <div class="wc-h"><span class="wc-title">${it.title}</span>${stageTag(it.stage)}</div>
      <div class="wc-chips"><span class="wc-chip"><b>${it.id}</b> ${it.scene}</span><span class="wc-chip">${it.pos}</span>${it.when ? `<span class="wc-chip">${it.when}</span>` : ''}</div>
      ${l1(it)}
      ${secondLayer(it)}
    </div>`;
  }

  // 价值视角：按战略定位分组
  function renderValue() {
    const groups = {};
    ITEMS.forEach((it) => { (groups[it.pos] = groups[it.pos] || []).push(it); });
    return Object.entries(groups).map(([pos, list]) =>
      `<div class="wc-group">战略定位 · <b>${pos}</b> <span style="opacity:.6">${list.length}</span></div>
       <div class="wc-grid">${list.slice().sort(byStage).map(itemCard).join('')}</div>`
    ).join('');
  }

  // 场景视角：按 scene 分组
  function renderScenario() {
    const scenes = [...new Set(ITEMS.map((i) => i.scene))];
    return scenes.map((sc) => {
      const list = ITEMS.filter((i) => i.scene === sc);
      return `<div class="wc-group">场景 · <b>${sc}</b> <span style="opacity:.6">${list.length}</span></div>
        <div class="wc-grid">${list.slice().sort(byStage).map(itemCard).join('')}</div>`;
    }).join('');
  }

  // 时间线视角：年份甘特（每需求三段 Issue→PR→Merge，未到的斜纹=预计）
  const Y0 = 2024, Y1 = 2028, YEARS = [2024, 2025, 2026, 2027], NOW = 2026.5;
  const ypct = (y) => ((Math.max(Y0, Math.min(Y1, y)) - Y0) / (Y1 - Y0)) * 100;
  function ganttRow(it) {
    const t = it.t, segs = [];
    segs.push({ cls: 'issue', a: t.issue, b: it.stage === 'issue' ? NOW : t.pr, real: true });
    if (it.stage === 'issue') {
      segs.push({ cls: 'pr', a: t.pr, b: t.merge, real: false });
      segs.push({ cls: 'merge', a: t.merge, b: t.merge + 0.18, real: false });
    } else if (it.stage === 'pr') {
      segs.push({ cls: 'pr', a: t.pr, b: NOW, real: true });
      segs.push({ cls: 'merge', a: t.merge, b: t.merge + 0.18, real: false });
    } else {
      segs.push({ cls: 'pr', a: t.pr, b: t.merge, real: true });
      segs.push({ cls: 'merge', a: t.merge, b: t.merge + 0.18, real: true });
    }
    const bars = segs.map((s) => `<div class="wc-seg ${s.cls}${s.real ? '' : ' proj'}" style="left:${ypct(s.a)}%;width:${Math.max(1.6, ypct(s.b) - ypct(s.a))}%"></div>`).join('');
    return `<div class="wc-grow">
      <div class="wc-glabel" style="margin-left:${ypct(t.issue)}%">${stageTag(it.stage)}<span>${it.title}</span><span class="nid">${it.id}</span></div>
      <div class="wc-track">${bars}</div></div>`;
  }
  function renderTimeline() {
    const rows = ITEMS.slice().sort((a, b) => a.t.issue - b.t.issue).map(ganttRow).join('');
    return `<div class="wc-glegend">横轴＝年份 · 每个需求三段：<b class="i">Issue</b> → <b class="p">PR</b> → <b class="m">Merge</b>（斜纹＝预计）</div>
      <div class="wc-gantt"><div class="wc-gchart">
        <div class="wc-gbg">${YEARS.map(() => '<span></span>').join('')}</div>
        <div class="wc-gyears">${YEARS.map((y) => `<span>${y}</span>`).join('')}</div>
        ${rows}
      </div></div>`;
  }

  function renderView() {
    const v = $('#wc-view');
    if (view === 'value') v.innerHTML = renderValue();
    else if (view === 'timeline') v.innerHTML = renderTimeline();
    else v.innerHTML = renderScenario();
  }
  function renderViewTabs() {
    $('#wc-tabs').innerHTML = VIEWS.map((v) => `<button class="${v.k === view ? 'on' : ''}" data-view="${v.k}">${v.label}</button>`).join('');
    $('#wc-hint').textContent = VIEW_HINT[view];
  }

  function shell() {
    return `<div class="wc-status" id="wc-status"></div>
      <div class="wc-ticker" id="wc-ticker"></div>
      <div class="wc-viewbar"><div class="wc-tabs" id="wc-tabs"></div><button class="wc-propose" id="wc-propose">+ 提个需求</button></div>
      <div class="wc-hint" id="wc-hint"></div>
      <div id="wc-view"></div>`;
  }

  // ── modal / toast（L1/L2/双榜/分享 共用）─────────────────────────────────
  function toast(msg) {
    let t = $('#wc-toast'); if (!t) { t = el('div', 'wc-toast'); t.id = 'wc-toast'; document.body.appendChild(t); }
    t.textContent = msg; t.classList.add('show'); clearTimeout(t._t); t._t = setTimeout(() => t.classList.remove('show'), 2300);
  }
  function openModal(html, wide) {
    let m = $('#wc-modal-root'); if (!m) { m = el('div'); m.id = 'wc-modal-root'; document.body.appendChild(m); }
    m.innerHTML = `<div class="wc-mask" data-mask><div class="wc-modal${wide ? ' wide' : ''}">${html}<span class="x" data-close>×</span></div></div>`;
    m.onclick = (e) => {
      const bet = e.target.closest('[data-bet]'); if (bet) { const [mid, sk] = bet.dataset.bet.split('|'); openBet(mid, sk); return; }
      if (e.target.closest('[data-close]') || e.target.hasAttribute('data-mask')) closeModal();
    };
  }
  function closeModal() { const m = $('#wc-modal-root'); if (m) m.innerHTML = ''; }

  // ── L1 我要用 ──────────────────────────────────────────────────────────────
  function doWant(id) {
    const it = item(id); if (!it) return;
    if (myWant.has(id)) { myWant.delete(id); it.waitlist--; toast('已取消「我要用」'); }
    else {
      myWant.add(id); it.waitlist++; subscribed.add(id);
      toast(it.waitlist >= it.unlockAt ? '你这票让它解锁了！上线邮件通知你' : '已登记 · 解锁/上线邮件通知你');
    }
    renderAll();
  }
  function onWantClick(id) {
    if (myWant.has(id) || myEmail) { doWant(id); return; }
    const it = item(id);
    openModal(`<h3>我要用</h3>
      <p class="wc-msub">留个邮箱，<b style="color:var(--ink)">${it ? it.title : ''}</b> 解锁 / 上线第一时间通知你（同时算你一票候补）。</p>
      <div class="wc-field"><label>邮箱 · Email</label><input id="wc-email" placeholder="you@company.com"></div>
      <button class="wc-mbtn" id="wc-wgo">举手 + 接收通知</button>
      <p class="wc-mnote">仅用于上线通知 · demo 不真实发送</p>`);
    $('#wc-wgo').onclick = () => { const v = $('#wc-email').value.trim(); if (!v || !v.includes('@')) { toast('填个有效邮箱'); return; } myEmail = v; closeModal(); doWant(id); };
  }
  function invite(id) {
    const it = item(id); if (!it) return; const need = Math.max(0, it.unlockAt - it.waitlist);
    openModal(`<h3>凑人解锁</h3>
      <p class="wc-msub">「${it.title}」攒够 ${it.unlockAt} 个「我要用」团队就评估开工，<b style="color:var(--ink)">还差 ${need} 人</b>。</p>
      <div class="wc-field"><label>分享文案（demo · 复制甩群）</label><input id="wc-inv" readonly value="我在 Ezagent world.cup 想要「${it.title}」，还差 ${need} 人解锁，帮我举个手 →"></div>
      <button class="wc-mbtn" id="wc-invcopy">复制邀请</button>`);
    $('#wc-invcopy').onclick = () => { const i = $('#wc-inv'); i.select(); (navigator.clipboard?.writeText(i.value) || Promise.reject()).then(() => { closeModal(); toast('凑人邀请已复制，甩进群'); }, () => toast('复制失败，长按手动复制')); };
  }

  // ── L2 看多看空：下注单 / 选择器 ─────────────────────────────────────────
  function openBet(marketId, sideKey) {
    const m = mkById(marketId); if (!m) return;
    const s = m.sides.find((x) => x.key === sideKey), o = odds(m, sideKey), it = itemOfMarket(m), isLong = sideKey === 'long';
    let amt = Math.min(200, LEDGER.renown); const quick = [100, 200, 500];
    openModal(`<h3>${it ? it.title : m.id} · 会不会火？</h3>
      <p class="wc-msub">赌它的候补会不会在结算窗口内破 <b style="color:var(--ink)">${m.hotAt}</b></p>
      <div class="wc-betpick">你押：<b style="color:${isLong ? 'var(--jade)' : 'var(--red)'}">${s.label}</b> · 当前赔率 <b style="color:var(--accent-press)">${o.toFixed(2)}×</b></div>
      <div class="wc-amtrow" id="wc-amtrow">${quick.map((a) => `<button class="wc-amtb" data-amt="${a}">${a}</button>`).join('')}<button class="wc-amtb" data-amt="all">全下</button></div>
      <div class="wc-winline">押 <b id="wc-amtshow">${amt}</b> 声望 · 预计可赢 <b id="wc-winshow" style="color:var(--accent-press)">${Math.round(amt * o)}</b> 声望</div>
      <button class="wc-mbtn" id="wc-confirmbet">确认押注</button>
      <p class="wc-mnote">虚拟声望 · 结算认候补数 · 不可提现</p>`);
    const refresh = () => { $('#wc-amtshow').textContent = amt; $('#wc-winshow').textContent = Math.round(amt * o);
      [...document.querySelectorAll('#wc-amtrow .wc-amtb')].forEach((b) => b.classList.toggle('on', (b.dataset.amt === 'all' && amt === LEDGER.renown) || b.dataset.amt === String(amt))); };
    $('#wc-amtrow').onclick = (e) => { const b = e.target.closest('[data-amt]'); if (!b) return; amt = b.dataset.amt === 'all' ? LEDGER.renown : Math.min(+b.dataset.amt, LEDGER.renown); refresh(); };
    $('#wc-confirmbet').onclick = () => { if (amt <= 0) { toast('声望不足'); return; } const r = stake(marketId, sideKey, amt); if (!r.ok) { toast(r.msg); return; } closeModal(); toast(`已押 ${fmt(amt)} 声望 · 锁定 ${r.lockedOdds.toFixed(2)}×`); renderAll(); };
    refresh();
  }
  function openPredict(marketId) {
    const m = mkById(marketId); if (!m) return; const it = itemOfMarket(m);
    openModal(`<h3>${it ? it.title : m.id} · 会不会火？</h3>
      <p class="wc-msub">押声望赌它的候补会不会在结算窗口内破 <b style="color:var(--ink)">${m.hotAt}</b></p>
      <div class="wc-predrow">
        <button class="wc-bigchoice long" data-bet="${m.id}|long">看多 · 会火<b>${odds(m, 'long').toFixed(2)}×</b></button>
        <button class="wc-bigchoice short" data-bet="${m.id}|short">看空 · 火不起来<b>${odds(m, 'short').toFixed(2)}×</b></button>
      </div>
      <p class="wc-mnote">虚拟声望 · 结算认候补数 · 不可提现</p>`);
  }

  // ── 我要用 / 仓位 面板 ────────────────────────────────────────────────────
  function renderWantList() {
    const ids = [...myWant]; if (!ids.length) return `<div class="wc-empty">还没点「我要用」。在卡上给真想用的功能举手，攒够人就解锁。</div>`;
    return `<div class="wc-poslist">${ids.map((id) => { const it = item(id); if (!it) return '';
      const st = it.stage === 'merged' ? '<span class="wc-ptag merged">已上线</span>' : it.waitlist >= it.unlockAt ? '<span class="wc-ptag live">已解锁</span>' : '<span class="wc-ptag pr">候补中</span>';
      return `<div class="wc-posrow"><div><div class="pt">${it.title}</div><div class="ps">${it.id} · ${it.scene} · 候补 ${it.waitlist}/${it.unlockAt}</div></div>${st}</div>`;
    }).join('')}</div>`;
  }
  function renderPositions() {
    if (!POSITIONS.length) return `<div class="wc-empty">还没押注。在需求卡上「看多 / 看空」它会不会火，仓位会出现在这里 —— 这就是你回访的理由。</div>`;
    return `<div class="wc-poslist">${[...POSITIONS].reverse().map((p) => {
      const m = mkById(p.marketId), it = itemOfMarket(m), s = m.sides.find((x) => x.key === p.sideKey);
      const st = p.status === 'won' ? '<span class="wc-ptag live">已赢</span>' : p.status === 'lost' ? '<span class="wc-ptag issue">已输</span>' : '<span class="wc-ptag pr">待结算</span>';
      return `<div class="wc-posrow"><div><div class="pt">${it ? it.title : m.id} · 会不会火</div><div class="ps">押「${s.label}」· 锁定 ${p.lockedOdds.toFixed(2)}×</div></div>
        <div class="right"><div class="pa">${fmt(p.amount)} 声望</div><div class="ps">${p.status === 'won' ? '赢得' : '可赢'} ${fmt(p.amount * p.lockedOdds)}</div></div>${st}</div>`;
    }).join('')}</div>`;
  }
  function openPanel(which) {
    const map = { want: ['我要用的需求', renderWantList], positions: ['我的预测仓位', renderPositions] };
    const [title, fn] = map[which];
    openModal(`<h3>${title}</h3><div style="margin-top:14px;max-height:62vh;overflow:auto">${fn()}</div>`, true);
  }

  // ── 状态条（含双榜 rank）──────────────────────────────────────────────────
  function renderStatus() {
    const me = you(), tb = totalBets(me);
    const eye = tb >= MIN_BETS ? '#' + eyeRank() : '未上榜';
    const rate = tb ? Math.round(hitRate(me) * 100) + '%' : '—';
    const open = POSITIONS.filter((p) => p.status === 'open').length;
    $('#wc-status').innerHTML = `
      <div class="wc-stat"><div class="n">${fmt(LEDGER.renown)}<span class="u">声望</span></div><div class="k">押注余额</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-lb="eye"><div class="n">${eye}</div><div class="k">眼光榜 · 命中率 ${rate}</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-lb="renown"><div class="n">#${renownRank()}</div><div class="k">声望榜 · ${me.hits}胜${me.misses}负</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-panel="want"><div class="n">${myWant.size}</div><div class="k">我要用</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-panel="positions"><div class="n">${POSITIONS.length}</div><div class="k">仓位 · 待结算 ${open}</div></div>
      <div class="sp"></div>
      <button class="gold" id="wc-record">晒战绩</button>`;
  }
  function renderTicker() {
    const evs = TICKER_EVENTS.map((e) => `<span class="wc-ev"><span class="pr">${e.pr}</span> <b>${e.txt}</b></span>`).join('');
    $('#wc-ticker').innerHTML = `<div class="tk">${evs}${evs}</div>`;
  }
  // ── 双榜 ──────────────────────────────────────────────────────────────────
  function openLeaderboard(which) {
    which = which === 'renown' ? 'renown' : 'eye';
    const me = you();
    const rows = which === 'eye'
      ? [...RIVALS, me].filter((r) => r.me || totalBets(r) >= MIN_BETS).sort((a, b) => hitRate(b) - hitRate(a) || b.hits - a.hits)
      : [...RIVALS, me].sort((a, b) => b.renown - a.renown);
    const body = rows.map((r, i) => {
      const metric = which === 'eye'
        ? (totalBets(r) ? `${Math.round(hitRate(r) * 100)}% · ${r.hits}胜${r.misses}负` : '—')
        : `${fmt(r.renown)} 声望`;
      return `<div class="wc-lbrow${r.me ? ' me' : ''}"><span class="rk">${i + 1}</span><span class="nm">${r.name}${r.me ? '（你）' : ''}</span><span class="mt2">${metric}</span></div>`;
    }).join('');
    openModal(`<h3>排行榜</h3>
      <div class="wc-lbtabs" style="margin-top:16px"><button class="${which === 'eye' ? 'on' : ''}" data-lbt="eye">眼光榜 · 命中率</button><button class="${which === 'renown' ? 'on' : ''}" data-lbt="renown">声望榜 · 总量</button></div>
      <div style="margin-top:8px;max-height:54vh;overflow:auto">${body}</div>
      <p class="wc-mnote" style="margin-top:12px">眼光榜需 ≥${MIN_BETS} 注上榜（防刷）· 虚拟声望 · 不可提现</p>`, true);
    [...document.querySelectorAll('[data-lbt]')].forEach((b) => (b.onclick = () => openLeaderboard(b.dataset.lbt)));
  }
  // ── 提个需求（开 Issue）────────────────────────────────────────────────────
  function openPropose() {
    openModal(`<h3>提个需求（开一个 Issue）</h3>
      <p class="wc-msub">提交后进入「价值视角」的 Issue 阶段，等同行举手。攒够人就解锁。</p>
      <div class="wc-field"><label>一句话需求（标题）</label><input id="wc-ptitle" placeholder="例：自动把工单同步到 Notion" maxlength="24"></div>
      <div class="wc-field"><label>场景</label><select id="wc-pscene"><option>连接</option><option>稳定</option><option>生成</option><option>定制</option><option>观测</option><option>灵活</option></select></div>
      <div class="wc-field"><label>战略定位</label><select id="wc-ppos"><option>world｜消息流转</option><option>hello｜界面生成</option></select></div>
      <button class="wc-mbtn" id="wc-confirmprop">提交（开 Issue）</button>`);
    $('#wc-confirmprop').onclick = () => { const title = $('#wc-ptitle').value.trim(); if (!title) { toast('给需求起个标题'); return; } submitProposal(title, $('#wc-pscene').value, $('#wc-ppos').value); };
  }
  function submitProposal(title, scene, pos) {
    const id = '#' + (900 + (++SEQ - 137));
    ITEMS.unshift({ id, pos, title, stage: 'issue', scene, when: '', waitlist: 1, unlockAt: 100, prRef: '', t: { issue: NOW, pr: NOW + 0.6, merge: NOW + 1.2 } });
    myWant.add(id); buildMarkets();
    closeModal(); view = 'value'; renderAll(); toast('已开 Issue · 你是第 1 个想要的');
  }
  function renderAll() { renderStatus(); renderTicker(); renderViewTabs(); renderView(); }

  // ── 裂变分享卡 ────────────────────────────────────────────────────────────
  let CARD_NO = 137;
  function shareCard(opts) {
    const no = opts.no || ('#' + String(++CARD_NO).padStart(6, '0'));
    openModal(`<div class="wc-sharecard">
        <span class="sc-num">world.cup ${no}</span>
        <div class="sc-eye">${opts.eye || 'WORLD.CUP'}</div>
        ${opts.badge ? `<div class="sc-badge">${opts.badge}</div>` : ''}
        <div class="sc-title">${opts.title}</div>
        ${opts.sub ? `<div class="sc-sub">${opts.sub}</div>` : ''}
        <div class="sc-lines">${(opts.lines || []).map((l) => `<div class="sc-line"><span>${l[0]}</span><b>${l[1]}</b></div>`).join('')}</div>
        ${opts.cta ? `<div class="sc-cta">${opts.cta}</div>` : ''}
        <div class="sc-brand">Ezagent · world.cup · Issue, PR, Merge!</div>
      </div>
      <div class="wc-sharebtns">
        <button class="b g" id="wc-sctxt">复制文案</button>
        <button class="b gold" data-close>完成</button>
      </div>`, true);
    $('#wc-sctxt').onclick = () => { (navigator.clipboard?.writeText(opts.copyText || opts.title) || Promise.reject()).then(() => toast(opts.copiedToast || '文案已复制 →'), () => toast('复制失败，长按手动复制')); };
  }
  function shareRecordCard() {
    const me = you(), tb = totalBets(me), rate = tb ? Math.round(hitRate(me) * 100) : 0;
    shareCard({
      eye: '我的预测战绩', badge: tb ? `命中率 ${rate}%` : '新晋预言家',
      title: (tb >= MIN_BETS && eyeRank() <= 3) ? '我是 world.cup 眼光榜常客' : '我在 world.cup 押路线图',
      lines: [['声望', fmt(me.renown)], ['战绩', `${me.hits} 胜 ${me.misses} 负`], ['我要用的需求', myWant.size + ' 个'], ['眼光榜', tb >= MIN_BETS ? ('#' + eyeRank()) : '冲榜中']],
      cta: '来 world.cup 押你看好的功能，赌它会不会火 →',
      copyText: `我在 Ezagent world.cup 押路线图：命中率 ${rate}%、${me.hits}胜${me.misses}负、声望 ${fmt(me.renown)}。来赌你看好的功能。`,
      copiedToast: '战绩文案已复制，去发群里 →',
    });
  }
  function shareForeseerCard(it) {
    shareCard({
      eye: '需求先知', badge: 'EARLY ADOPTER',
      title: `我早就要了「${it.title}」`,
      sub: `现在它上线了（${it.prRef || it.id} 已合并）`,
      lines: [['我举手得早', '✓'], ['最终候补', it.waitlist + ' 人'], ['状态', '已上线']],
      cta: '眼光不错？来挑下一个会火的功能 →',
      copyText: `我早就在 Ezagent world.cup 举手要「${it.title}」，现在它上线了。来挑下一个会火的。`,
      copiedToast: '先知卡文案已复制 →',
    });
  }

  // ── demo 控制：快进结算 / 模拟 PR 合并 ─────────────────────────────────────
  function fastForwardSettle() {
    const open = MARKETS.filter((m) => m.status === 'open');
    if (!open.length) { toast('没有可结算的预测了'); return; }
    const m = open.find((x) => POSITIONS.some((p) => p.marketId === x.id && p.status === 'open')) || open[0];
    const it = itemOfMarket(m);
    const surge = ((it.waitlist + POSITIONS.length * 7 + 17) % 54) - 10;
    it.waitlist = Math.max(0, it.waitlist + surge);
    const winKey = it.waitlist >= m.hotAt ? 'long' : 'short';
    openModal(`<h3 style="text-align:center">结算窗口到期</h3>
      <p class="wc-msub" style="text-align:center">${it ? it.title : m.id} · 会不会火</p>
      <div class="wc-ffstage" id="wc-ffstage"><div class="wc-msub">统计候补数…</div></div>`);
    setTimeout(() => {
      settle(m.id, winKey);
      const win = m.sides.find((s) => s.key === winKey);
      const won = POSITIONS.filter((p) => p.marketId === m.id && p.status === 'won');
      const lost = POSITIONS.filter((p) => p.marketId === m.id && p.status === 'lost');
      const winnings = won.reduce((s, p) => s + p.amount * p.lockedOdds, 0);
      const verdict = won.length ? `<div style="color:var(--jade);font-weight:800;font-size:18px">你押中了！+${fmt(winnings)} 声望</div>`
        : lost.length ? `<div style="color:var(--red);font-weight:700">这把没押中（已计入战绩）</div>`
        : `<div class="wc-msub">你没押这个 —— 围观一次结算</div>`;
      const ff = $('#wc-ffstage');
      if (ff) ff.innerHTML = `
        <div class="wc-ffbig" style="color:${winKey === 'long' ? 'var(--jade)' : 'var(--ink-3)'}">${winKey === 'long' ? '会火' : '没火'}</div>
        <div style="margin-top:6px;font-weight:600;color:var(--ink)">候补 ${it.waitlist} / 阈值 ${m.hotAt} → ${win.label}</div>
        <div style="margin-top:14px">${verdict}</div>
        <button class="wc-mbtn" id="wc-ffdone">${won.length ? '晒预测战绩' : '知道了'}</button>`;
      TICKER_EVENTS.unshift({ pr: it ? it.id : m.id, txt: `结算 → 候补 ${it.waitlist} · ${win.label}` });
      const done = $('#wc-ffdone'); if (done) done.onclick = () => { closeModal(); if (won.length) shareRecordCard(); renderAll(); };
      renderAll();
    }, 1100);
  }
  function mergeAdvance() {
    const cand = ITEMS.filter((i) => i.stage === 'pr').concat(ITEMS.filter((i) => i.stage === 'issue'));
    const it = cand.find((i) => myWant.has(i.id)) || cand[0];
    if (!it) { toast('没有可推进的需求了'); return; }
    const wasEarly = myWant.has(it.id);
    const mk = marketFor(it); if (mk) settle(mk.id, it.waitlist >= mk.hotAt ? 'long' : 'short');
    it.stage = 'merged'; it.prRef = it.id; it.when = '刚刚';
    const merge = NOW, pr = Math.min(it.t.pr, merge - 0.25), issue = Math.min(it.t.issue, pr - 0.25);
    it.t = { issue, pr, merge };
    buildMarkets(); renderAll();
    toast(`${it.id} 已合并上线！`);
    TICKER_EVENTS.unshift({ pr: it.id, txt: '已合并 → 候补者收到上线通知' });
    if (wasEarly) shareForeseerCard(it);
  }

  // ── boot ──────────────────────────────────────────────────────────────────
  async function boot() {
    const root = $('#wc-root'); if (!root) return;
    root.innerHTML = '<div class="wc-hint">loading roadmap…</div>';
    ITEMS = await EZ.worldcup();
    buildMarkets();
    root.innerHTML = shell();
    $('#wc-tabs').addEventListener('click', (e) => {
      const b = e.target.closest('[data-view]'); if (!b) return;
      view = b.dataset.view; renderViewTabs(); renderView();
    });
    $('#wc-status').addEventListener('click', (e) => {
      const p = e.target.closest('[data-panel]'); if (p) { openPanel(p.dataset.panel); return; }
      const lb = e.target.closest('[data-lb]'); if (lb) { openLeaderboard(lb.dataset.lb); return; }
      if (e.target.closest('#wc-record')) { shareRecordCard(); return; }
    });
    $('#wc-propose').addEventListener('click', openPropose);
    // demo 控制条（挂 body，真·viewport-fixed；按 body[data-page] CSS 控制显隐）
    if (!$('#wc-dembar')) {
      const d = el('div', 'wc-dembar'); d.id = 'wc-dembar';
      d.innerHTML = `<button class="wc-dembtn ff" id="wc-ff">快进结算</button><button class="wc-dembtn merge" id="wc-merge">模拟 PR 合并</button><span class="dnote">demo 控制</span>`;
      document.body.appendChild(d);
      $('#wc-ff').onclick = fastForwardSettle;
      $('#wc-merge').onclick = mergeAdvance;
    }
    $('#wc-view').addEventListener('click', (e) => {
      let b;
      if (b = e.target.closest('[data-want]')) { onWantClick(b.dataset.want); return; }
      if (b = e.target.closest('[data-invite]')) { invite(b.dataset.invite); return; }
      if (b = e.target.closest('[data-bet]')) { const [mid, sk] = b.dataset.bet.split('|'); openBet(mid, sk); return; }
      if (b = e.target.closest('[data-predict]')) { openPredict(b.dataset.predict); return; }
      if (b = e.target.closest('[data-sub]')) { const id = b.dataset.sub; subscribed.has(id) ? subscribed.delete(id) : subscribed.add(id); toast(subscribed.has(id) ? '已订阅 · 上线第一时间通知你' : '已取消订阅'); renderView(); return; }
      if (b = e.target.closest('[data-like]')) { const id = b.dataset.like; liked.has(id) ? liked.delete(id) : liked.add(id); renderView(); return; }
      if (b = e.target.closest('[data-try]')) { toast('demo · 试玩跳转（原型未接）'); return; }
    });
    renderAll();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
