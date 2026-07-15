/* ============================================================================
 * worldcup.js · 路线图（v2 mindmap 模型 + 03 押注，reskin 到 ezagent-design DS）
 * ----------------------------------------------------------------------------
 * 模型：定位 → 痛点(votes/我想要) → 成果(真实 GitHub PR：live/wip)。
 * 价值视角 = mindmap 树；「我想要」= votePill(▲ 票数 想要)挂痛点；
 * 押注(看多/看空)挂痛点；双榜 + 提需求 + 分享卡。无 emoji（▲ 几何符 + SVG 心）。
 * 数据走 EZ.worldcup()（来自 github.com/ezagent42/ezagent 真实 PR/issue）。
 * ========================================================================== */
(function () {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const fmt = (n) => Math.round(n).toLocaleString();
  const HEART = '<svg viewBox="0 0 24 24" fill="currentColor" style="width:12px;height:12px"><path d="M12 21s-6.7-4.3-9.2-8.6C1.2 9.6 2.6 6 6 6c2 0 3.2 1.2 4 2.4C10.8 7.2 12 6 14 6c3.4 0 4.8 3.6 3.2 6.4C18.7 16.7 12 21 12 21z"/></svg>';

  // ── DS 样式（token 来自 mainsite.html :root）────────────────────────────────
  const CSS = `
  #wc-root{margin-top:18px}
  .wc-viewbar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  .wc-tabs{display:inline-flex;background:var(--ground-2);border-radius:var(--r-pill);padding:4px;gap:4px}
  .wc-tabs button{appearance:none;border:0;background:transparent;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;color:var(--ink-2);padding:9px 16px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-tabs button:hover:not(.on){color:var(--ink)}
  .wc-tabs button.on{background:var(--accent);color:var(--on-accent);box-shadow:var(--shadow-accent)}
  .wc-hint{font-family:var(--font-mono);font-size:11px;letter-spacing:.04em;color:var(--ink-3);margin:0 0 18px}
  /* ---- 价值树 mindmap ---- */
  .wc-mtree,.wc-mtree ul{list-style:none;margin:0;padding:0}
  .wc-mtree{margin-top:6px}
  .wc-mtree ul{margin-left:18px}
  .wc-mtree li{position:relative;padding-left:30px}
  .wc-mtree li::before{content:"";position:absolute;left:0;top:0;bottom:0;border-left:1.5px solid var(--line)}
  .wc-mtree li::after{content:"";position:absolute;left:0;top:26px;width:26px;border-top:1.5px solid var(--line)}
  .wc-mtree li:last-child::before{height:26px}
  .wc-mtree>li{padding-left:0}.wc-mtree>li::before,.wc-mtree>li::after{display:none}
  .wc-mnode{display:inline-flex;align-items:center;gap:10px;flex-wrap:wrap;margin:7px 0;padding:11px 15px;border-radius:14px;
    background:var(--card);box-shadow:var(--shadow-sm);border-left:3px solid var(--ac,var(--line))}
  .wc-mnode .mt{font-size:14px;font-weight:600;color:var(--ink)}
  .wc-mnode.lf{background:var(--ground-2);box-shadow:none}
  .wc-mnode.lf .mt{font-weight:500;color:var(--ink-2);font-size:13px}
  .wc-mnode .meye{font-family:var(--font-mono);font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-3)}
  .wc-mnode .mt.serif{font-family:var(--font-cn);font-weight:600;font-size:16px}
  .wc-mnode.hot{box-shadow:var(--shadow-sm),inset 0 0 0 1.5px var(--orange)}
  .wc-hotbadge{font-family:var(--font-mono);font-size:10px;font-weight:700;color:var(--orange);background:var(--orange-wash);padding:3px 8px;border-radius:var(--r-pill)}
  /* tags / buttons (v2 风格) */
  .wc-stag{display:inline-flex;align-items:center;gap:5px;font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:.03em;padding:3px 9px;border-radius:var(--r-pill)}
  .wc-stag::before{content:"";width:6px;height:6px;border-radius:50%}
  .wc-stag.live{background:var(--jade-wash);color:var(--jade-deep,var(--jade))}.wc-stag.live::before{background:var(--jade)}
  .wc-stag.wip{background:var(--orange-wash);color:var(--orange)}.wc-stag.wip::before{background:var(--orange)}
  .wc-stag.planned{background:var(--ground-hover);color:var(--ink-3)}.wc-stag.planned::before{background:var(--ink-4)}
  .wc-scene{font-family:var(--font-mono);font-size:10.5px;color:var(--ink-2);background:var(--ground-2);padding:3px 9px;border-radius:var(--r-pill)}
  .wc-mnode.lf .wc-scene{background:var(--card)}
  .wc-vote{appearance:none;border:0;cursor:pointer;display:inline-flex;align-items:center;gap:6px;font-family:var(--font-ui);font-weight:700;font-size:12px;color:var(--accent-press);background:var(--accent-wash);padding:6px 12px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-vote .tri{font-size:10px;line-height:1}
  .wc-vote .num{font-family:var(--font-mono)}
  .wc-vote:hover{background:var(--accent);color:var(--on-accent)}
  .wc-vote.on{background:var(--jade-wash);color:var(--jade)}
  .wc-chip2{appearance:none;border:0;cursor:pointer;display:inline-flex;align-items:center;gap:5px;font-family:var(--font-mono);font-size:11px;font-weight:600;color:var(--ink-2);background:var(--ground-2);padding:6px 11px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-mnode.lf .wc-chip2{background:var(--card)}
  .wc-chip2:hover{color:var(--ink);background:var(--ground-hover)}
  .wc-chip2.on{background:var(--accent-wash);color:var(--accent-press)}
  .wc-chip2.like.on{background:var(--red-wash);color:var(--red)}
  .wc-chip2.go{background:var(--accent);color:var(--on-accent)}.wc-chip2.go:hover{background:var(--accent-hover);color:#fff}
  .wc-pr{font-family:var(--font-mono);font-size:10px;color:var(--ink-3)}
  /* L2 看多看空（挂痛点）*/
  .wc-l2btn{appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:11.5px;font-weight:700;padding:6px 11px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out)}
  .wc-l2btn b{font-family:var(--font-mono);margin-left:4px}
  .wc-l2btn.long{background:var(--jade-wash);color:var(--jade)}.wc-l2btn.long:hover,.wc-l2btn.long.staked{box-shadow:inset 0 0 0 1.5px var(--jade)}
  .wc-l2btn.short{background:var(--red-wash);color:var(--red)}.wc-l2btn.short:hover,.wc-l2btn.short.staked{box-shadow:inset 0 0 0 1.5px var(--red)}
  /* status bar */
  .wc-status{display:flex;align-items:center;flex-wrap:wrap;background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:14px 14px;margin-bottom:16px}
  .wc-stat{padding:4px 18px}
  .wc-stat.click{cursor:pointer;border-radius:var(--r-md);transition:background 150ms}.wc-stat.click:hover{background:var(--ground-2)}
  .wc-stat .n{font-family:var(--font-ui);font-weight:800;font-size:18px;letter-spacing:-.01em;color:var(--ink);display:flex;align-items:baseline;gap:5px}
  .wc-stat .n .u{font-size:11px;font-weight:500;color:var(--ink-3);font-family:var(--font-mono)}
  .wc-stat .k{font-family:var(--font-mono);font-size:10px;letter-spacing:.03em;color:var(--ink-3);margin-top:2px}
  .wc-sep{width:1px;align-self:stretch;background:var(--line);margin:4px 0}
  .wc-status .sp{flex:1}
  .wc-status .gold{appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:700;font-size:13px;color:var(--ink);background:var(--yellow-wash);padding:9px 16px;border-radius:var(--r-pill)}
  .wc-status .gold:hover{background:var(--yellow)}
  .wc-propose{appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:13px;color:var(--accent-press);background:var(--accent-wash);padding:9px 16px;border-radius:var(--r-pill);margin-left:auto}
  .wc-propose:hover{background:var(--accent);color:var(--on-accent)}
  /* ticker */
  .wc-ticker{overflow:hidden;background:var(--card);border-radius:var(--r-pill);box-shadow:var(--shadow-sm);padding:10px 0;margin-bottom:16px;white-space:nowrap;-webkit-mask-image:linear-gradient(90deg,transparent,#000 5%,#000 95%,transparent);mask-image:linear-gradient(90deg,transparent,#000 5%,#000 95%,transparent)}
  .wc-ticker .tk{display:inline-block;animation:wc-scroll 30s linear infinite}
  .wc-ev{display:inline-flex;align-items:center;gap:7px;margin:0 26px;font-size:12.5px;color:var(--ink-2)}
  .wc-ev::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--jade)}
  .wc-ev .pr{font-family:var(--font-mono);color:var(--accent-press);font-weight:700}.wc-ev b{color:var(--ink);font-weight:600}
  @keyframes wc-scroll{from{transform:translateX(0)}to{transform:translateX(-50%)}}
  @media (prefers-reduced-motion:reduce){.wc-ticker .tk{animation:none}}
  /* gantt (时间线) · 每需求三段 Issue→PR→Merge */
  .wc-gantt{background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:24px 26px;overflow-x:auto}
  .wc-gchart2{position:relative;min-width:720px}
  .wc-gbg2{position:absolute;left:0;right:0;top:30px;bottom:0;display:grid;grid-template-columns:repeat(3,1fr);z-index:0;pointer-events:none}
  .wc-gbg2 span{border-left:1px solid var(--line)}.wc-gbg2 span:first-child{border-left:0}
  .wc-gyears{display:grid;grid-template-columns:repeat(3,1fr);margin-bottom:16px;position:relative;z-index:1}
  .wc-gyears span{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);padding-left:8px}
  .wc-grow2{position:relative;z-index:1;margin-bottom:15px}
  .wc-glabel2{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--ink);margin-bottom:7px;font-weight:500}
  .wc-glabel2 .gs{font-family:var(--font-mono);font-size:10px;color:var(--ink-3)}
  .wc-track{position:relative;height:10px}
  .wc-seg{position:absolute;height:10px;border-radius:var(--r-pill)}
  .wc-seg.issue{background:var(--ink-4)}.wc-seg.pr{background:var(--orange)}.wc-seg.merge{background:var(--jade)}
  .wc-seg.proj{opacity:.32;background-image:repeating-linear-gradient(45deg,rgba(0,0,0,.18) 0 4px,transparent 4px 8px)}
  .wc-glegend{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin-bottom:14px}
  .wc-glegend b.i{color:var(--ink-4)}.wc-glegend b.p{color:var(--orange)}.wc-glegend b.m{color:var(--jade)}
  /* scenario gallery */
  .wc-galwrap{display:flex;flex-direction:column;gap:26px}
  .wc-galhead{display:flex;align-items:center;gap:10px;margin-bottom:14px}
  .wc-galhead h3{font-family:var(--font-cn);font-weight:600;font-size:18px;margin:0}
  .wc-galhead .cnt{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin-left:auto}
  .wc-gal{display:grid;grid-template-columns:repeat(3,1fr);gap:var(--gap-grid)}
  .wc-gcard{background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);padding:18px 20px;display:flex;flex-direction:column;gap:10px}
  .wc-gcard .gtitle{font-family:var(--font-cn-ui);font-weight:600;font-size:15px;color:var(--ink)}
  .wc-gcard .gsum{font-size:13px;color:var(--ink-2);line-height:1.5;margin:0}
  .wc-gacts{display:flex;gap:7px;flex-wrap:wrap;align-items:center;margin-top:2px}
  /* modal + toast + 分享 + 双榜 + 仓位 */
  .wc-mask{position:fixed;inset:0;background:rgba(15,15,20,.5);backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px);display:grid;place-items:center;z-index:200;padding:20px}
  .wc-modal{position:relative;background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-card);max-width:420px;width:100%;padding:28px 30px}
  .wc-modal.wide{max-width:560px}
  .wc-modal h3{font-family:var(--font-cn);font-weight:600;font-size:20px;margin:0;color:var(--ink)}
  .wc-modal .x{position:absolute;top:14px;right:18px;cursor:pointer;color:var(--ink-3);font-size:22px;line-height:1}.wc-modal .x:hover{color:var(--ink)}
  .wc-field{margin-top:14px}.wc-field label{display:block;font-size:13px;font-weight:500;color:var(--ink-2);margin-bottom:7px}
  .wc-field input,.wc-field select{width:100%;box-sizing:border-box;padding:12px 14px;border:0;border-radius:var(--r-md);background:var(--ground-2);font-family:var(--font-ui);font-size:15px;color:var(--ink);box-shadow:inset 0 0 0 1px var(--line)}
  .wc-field input:focus,.wc-field select:focus{outline:none;box-shadow:0 0 0 3px var(--focus-ring)}
  .wc-mbtn{width:100%;appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:15px;padding:13px;border-radius:var(--r-pill);background:var(--accent);color:var(--on-accent);margin-top:16px}
  .wc-mbtn:hover{background:var(--accent-hover)}
  .wc-msub{color:var(--ink-2);font-size:13px;margin:4px 0 0;line-height:1.5}
  .wc-mnote{color:var(--ink-3);font-size:11px;text-align:center;margin-top:10px;font-family:var(--font-mono)}
  .wc-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%) translateY(20px);background:var(--ink);color:var(--card);font-size:13.5px;padding:12px 20px;border-radius:var(--r-pill);box-shadow:var(--shadow-card);z-index:300;opacity:0;pointer-events:none;transition:all .25s var(--ease-out)}
  .wc-toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
  .wc-empty{color:var(--ink-3);font-size:14px;line-height:1.6;padding:18px;text-align:center}
  .wc-betpick{font-size:13px;color:var(--ink-2);margin:8px 0 12px}
  .wc-amtrow{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
  .wc-amtb{appearance:none;border:0;cursor:pointer;font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink-2);background:var(--ground-2);padding:9px 14px;border-radius:var(--r-pill)}
  .wc-amtb.on{background:var(--accent);color:var(--on-accent)}
  .wc-winline{font-size:13px;color:var(--ink-2)}.wc-winline b{color:var(--ink)}
  .wc-poslist{display:flex;flex-direction:column;gap:10px}
  .wc-posrow{display:flex;align-items:center;gap:12px;background:var(--ground-2);border-radius:var(--r-md);padding:12px 15px}
  .wc-posrow .pt{font-size:14px;font-weight:600;color:var(--ink)}.wc-posrow .ps{font-family:var(--font-mono);font-size:11px;color:var(--ink-3);margin-top:3px}
  .wc-posrow .right{margin-left:auto;text-align:right}.wc-posrow .pa{font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink)}
  .wc-ptag{flex:none;font-family:var(--font-mono);font-size:10px;font-weight:700;padding:4px 9px;border-radius:var(--r-pill)}
  .wc-ptag.pr{background:var(--orange-wash);color:var(--orange)}.wc-ptag.live{background:var(--jade-wash);color:var(--jade)}.wc-ptag.issue{background:var(--red-wash);color:var(--red)}
  .wc-lbtabs{display:flex;gap:6px}
  .wc-lbtabs button{appearance:none;border:0;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;color:var(--ink-2);background:var(--ground-2);padding:8px 14px;border-radius:var(--r-pill)}
  .wc-lbtabs button.on{background:var(--accent);color:var(--on-accent)}
  .wc-lbrow{display:flex;align-items:center;gap:14px;padding:11px 10px;border-bottom:1px solid var(--line)}
  .wc-lbrow.me{background:var(--accent-wash);border-radius:var(--r-md);border-bottom:0}
  .wc-lbrow .rk{font-family:var(--font-mono);font-size:13px;font-weight:700;color:var(--ink-3);width:22px}
  .wc-lbrow .nm{font-size:14px;font-weight:600;color:var(--ink);flex:1}.wc-lbrow .mt2{font-family:var(--font-mono);font-size:12px;color:var(--ink-2)}
  .wc-sharecard{background:#14131C;border-radius:var(--r-lg);padding:26px 26px 22px;color:#F4F2EC;position:relative;overflow:hidden}
  .wc-sharecard .sc-num{position:absolute;top:18px;right:20px;font-family:var(--font-mono);font-size:11px;color:#85837B}
  .wc-sharecard .sc-eye{font-family:var(--font-mono);font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--blue)}
  .wc-sharecard .sc-badge{display:inline-block;margin-top:10px;font-family:var(--font-mono);font-size:11px;font-weight:700;background:var(--blue);color:#fff;padding:4px 11px;border-radius:var(--r-pill)}
  .wc-sharecard .sc-title{font-family:var(--font-cn);font-weight:600;font-size:23px;margin:12px 0 4px;line-height:1.3}
  .wc-sharecard .sc-lines{margin:16px 0 12px}
  .wc-sharecard .sc-line{display:flex;justify-content:space-between;gap:12px;font-size:13px;color:#B6B4AC;border-top:1px solid rgba(255,255,255,.08);padding:9px 0}.wc-sharecard .sc-line b{color:#fff}
  .wc-sharecard .sc-cta{font-size:12.5px;color:#5AA2FF;margin-top:4px}
  .wc-sharecard .sc-brand{margin-top:16px;font-family:var(--font-mono);font-size:10px;color:#56544D}
  .wc-sharebtns{display:flex;gap:10px;margin-top:16px}
  .wc-sharebtns .b{flex:1;appearance:none;border:0;cursor:pointer;font-family:var(--font-ui);font-weight:600;font-size:14px;padding:12px;border-radius:var(--r-pill)}
  .wc-sharebtns .b.g{background:var(--ground-2);color:var(--ink)}.wc-sharebtns .b.gold{background:var(--accent);color:var(--on-accent)}
  @media (max-width:860px){.wc-gal{grid-template-columns:1fr}.wc-mtree ul{margin-left:8px}.wc-mtree li{padding-left:20px}}
  `;
  if (!$('#wc-style')) { const s = el('style'); s.id = 'wc-style'; s.textContent = CSS; document.head.appendChild(s); }

  // ── 状态 ──────────────────────────────────────────────────────────────────
  let DATA = { 定位: [] };
  const voted = new Set(), liked = new Set(), subscribed = new Set();
  let myEmail = '';
  const allPains = () => DATA.定位.flatMap((p) => p.痛点);
  const allAch = () => DATA.定位.flatMap((pos) => pos.痛点.flatMap((p) => p.成果));
  const painById = (id) => allPains().find((p) => p.id === id);
  const painStatus = (p) => (!p.成果.length ? 'planned' : p.成果.some((a) => a.status !== 'live') ? 'wip' : 'live');
  const hottest = () => { let b = null; allPains().forEach((p) => { if (!b || p.votes > b.votes) b = p; }); return b ? b.id : null; };
  const scn = (s) => s;

  // L2 账本 / 市场（挂痛点）+ 双榜
  const LEDGER = { renown: 1000, hits: 0, misses: 0 };
  let POSITIONS = [], MARKETS = [];
  function buildMarkets() {
    allPains().forEach((p) => {
      if (painStatus(p) === 'live') return;
      if (MARKETS.find((m) => m.painId === p.id)) return;
      const lean = Math.min(1, p.votes / 50);
      MARKETS.push({ id: 'm-' + p.id, painId: p.id, status: 'open',
        sides: [{ key: 'long', label: '看多 · 会做出来', pool: Math.round(300 + lean * 500) },
                { key: 'short', label: '看空 · 短期做不出', pool: Math.round(360 - lean * 120) }] });
    });
  }
  const mkById = (id) => MARKETS.find((m) => m.id === id);
  const marketForPain = (p) => MARKETS.find((m) => m.painId === p.id && m.status === 'open');
  const odds = (m, sk) => { const tot = m.sides.reduce((s, x) => s + x.pool, 0); const s = m.sides.find((x) => x.key === sk); return Math.max(1.05, tot / s.pool); };
  function stake(mid, sk, amount) { if (amount > LEDGER.renown) return { ok: false, msg: '声望不足' }; const m = mkById(mid), lo = odds(m, sk); LEDGER.renown -= amount; m.sides.find((x) => x.key === sk).pool += amount; POSITIONS.push({ mid, sk, amount, lo, status: 'open' }); return { ok: true, lo }; }
  const myStakeOn = (mid, sk) => POSITIONS.filter((p) => p.mid === mid && p.sk === sk).reduce((s, p) => s + p.amount, 0);
  const RIVALS = [
    { name: '盯盘老张', renown: 4820, hits: 31, misses: 9 }, { name: 'eyes_of_qa', renown: 3110, hits: 22, misses: 11 },
    { name: '押注狂魔', renown: 5950, hits: 18, misses: 26 }, { name: '@mia', renown: 2440, hits: 14, misses: 6 },
    { name: '冷静观察者', renown: 1890, hits: 9, misses: 3 }, { name: '@kev', renown: 2760, hits: 17, misses: 14 },
    { name: '稳健派', renown: 1620, hits: 11, misses: 7 }, { name: '信号挖掘机', renown: 3540, hits: 25, misses: 8 },
  ];
  const MIN_BETS = 5;
  const totalBets = (x) => x.hits + x.misses;
  const hitRate = (x) => (totalBets(x) ? x.hits / totalBets(x) : 0);
  const you = () => ({ name: '你', renown: LEDGER.renown, hits: LEDGER.hits, misses: LEDGER.misses, me: true });
  const eyeRank = () => { const me = you(); return RIVALS.filter((r) => totalBets(r) >= MIN_BETS && hitRate(r) > hitRate(me)).length + 1; };
  const renownRank = () => RIVALS.filter((r) => r.renown > LEDGER.renown).length + 1;
  let SEQ = 0;
  let TICKER = [
    { pr: '#1069', txt: '已合并 → 统一 socialware 对客流水线上线' },
    { pr: '#1076', txt: '已合并 → plugin-package 热加载 / 热卸载就绪' },
    { pr: '#1083', txt: '在做 → handoff 界面迁 shadcn，看多赔率走低' },
  ];

  // ── 视图 ──────────────────────────────────────────────────────────────────
  let view = 'value';
  const VIEWS = [{ k: 'value', label: '价值' }, { k: 'timeline', label: '时间线' }, { k: 'scenario', label: '场景' }];
  const VIEW_HINT = {
    value: '按战略定位 → 痛点展开，痛点按「我想要」票数排序 — 最想要的浮到上面',
    timeline: '按阶段看：已上线(live) / 在做(wip) / 想做(planned)，成果绑真实 PR',
    scenario: '按场景归类（连接 / 稳定 / 生成 / 定制 / 扩展 …），只看跟你相关的那块',
  };

  // ── 组件（v2 风格）────────────────────────────────────────────────────────
  const ST_CN = { live: '已上线', wip: '在做', planned: '想做' };
  const statusTag = (s) => `<span class="wc-stag ${s}">${ST_CN[s]}</span>`;
  const sceneTag = (s) => `<span class="wc-scene">${scn(s)}</span>`;
  function votePill(id, v) { const on = voted.has(id), n = v + (on ? 1 : 0); return `<button class="wc-vote ${on ? 'on' : ''}" data-vote="${id}"><span class="tri">▲</span><span class="num">${n}</span>${on ? '已要' : '我想要'}</button>`; }
  const subBtn = (id) => `<button class="wc-chip2 ${subscribed.has(id) ? 'on' : ''}" data-sub="${id}">${subscribed.has(id) ? '已订阅' : '订阅上线'}</button>`;
  const likeBtn = (a) => { const on = liked.has(a.prId), n = a.likes + (on ? 1 : 0); return `<button class="wc-chip2 like ${on ? 'on' : ''}" data-like="${a.prId}">${HEART} ${n}</button>`; };
  function betButtons(p) {
    const mk = marketForPain(p); if (!mk) return '';
    const sl = myStakeOn(mk.id, 'long'), ss = myStakeOn(mk.id, 'short');
    return `<button class="wc-l2btn long ${sl > 0 ? 'staked' : ''}" data-bet="${mk.id}|long">看多<b>${odds(mk, 'long').toFixed(2)}×</b></button><button class="wc-l2btn short ${ss > 0 ? 'staked' : ''}" data-bet="${mk.id}|short">看空<b>${odds(mk, 'short').toFixed(2)}×</b></button>`;
  }

  // 成果叶子
  function mLeaf(a) {
    const tryB = a.status === 'live' ? `<button class="wc-chip2 go" data-try="${a.prId}">试玩</button>` : '';
    return `<li><div class="wc-mnode lf" style="--ac:${a.status === 'live' ? 'var(--jade)' : a.status === 'wip' ? 'var(--orange)' : 'var(--ink-4)'}">
      ${statusTag(a.status)}<span class="mt">${a.title}</span><span class="wc-pr">PR #${a.prId}</span>${tryB}${likeBtn(a)}</div></li>`;
  }
  // 痛点
  function mPain(p, hot) {
    const leaves = p.成果.length ? `<ul>${p.成果.map(mLeaf).join('')}</ul>` : '';
    const planned = !p.成果.length;
    return `<li><div class="wc-mnode${p.id === hot ? ' hot' : ''}" style="--ac:var(--blue)">
      <span class="mt">${p.gc}</span>${sceneTag(p.场景)}${p.id === hot ? `<span class="wc-hotbadge">最想要</span>` : ''}
      ${votePill(p.id, p.votes)}${betButtons(p)}${planned ? subBtn(p.id) : ''}</div>${leaves}</li>`;
  }
  // 定位
  function posLi(pos) {
    const hot = hottest();
    return `<li><div class="wc-mnode" style="--ac:var(--red)"><span class="meye">战略定位</span><span class="mt serif">${pos.title}</span>${votePill(pos.id, pos.votes)}</div>
      <ul>${[...pos.痛点].sort((a, b) => b.votes - a.votes).map((p) => mPain(p, hot)).join('')}</ul></li>`;
  }
  function renderValue() {
    return `<ul class="wc-mtree"><li><div class="wc-mnode" style="--ac:var(--ink)"><span class="mt serif">hello, world</span><span class="meye">三条产品线</span></div>
      <ul>${DATA.定位.map(posLi).join('')}</ul></li></ul>`;
  }

  // 时间线：每个需求三段 Issue → PR → Merge（横轴＝时间，未到的斜纹＝预计）
  const Y0 = 2025, Y1 = 2027.5, YEARS = [2025, 2026, 2027], NOW = 2026.45;
  const ypct = (y) => ((Math.max(Y0, Math.min(Y1, y)) - Y0) / (Y1 - Y0)) * 100;
  function whenYear(w) { if (!w) return NOW; const m = w.match(/(\d{4})\D*Q?(\d)?/); if (!m) return NOW; return +m[1] + ((m[2] ? +m[2] : 1) - 1) * 0.25; }
  // segs: [cls, start, end, real?]
  function rowSegs(status, when) {
    const y = whenYear(when);
    if (status === 'live') return [['issue', y - 0.55, y - 0.25, 1], ['pr', y - 0.25, y - 0.05, 1], ['merge', y - 0.05, y + 0.12, 1]];
    if (status === 'wip') return [['issue', y - 0.4, y - 0.1, 1], ['pr', y - 0.1, NOW, 1], ['merge', y + 0.35, y + 0.5, 0]];
    return [['issue', NOW, NOW + 0.25, 1], ['pr', NOW + 0.25, NOW + 0.5, 0], ['merge', NOW + 0.5, NOW + 0.65, 0]];
  }
  function ganttRow(r) {
    const segs = rowSegs(r.status, r.when);
    const bars = segs.map(([cls, a, b, real]) => `<div class="wc-seg ${cls}${real ? '' : ' proj'}" style="left:${ypct(a)}%;width:${Math.max(1.5, ypct(b) - ypct(a))}%"></div>`).join('');
    return `<div class="wc-grow2">
      <div class="wc-glabel2" style="margin-left:${ypct(segs[0][1])}%">${statusTag(r.status)}<span>${r.label}</span><span class="gs">${r.sub}</span></div>
      <div class="wc-track">${bars}</div></div>`;
  }
  function renderTimeline() {
    const rows = [];
    allAch().forEach((a) => rows.push({ label: a.title, status: a.status, when: a.when, sub: 'PR #' + a.prId }));
    allPains().filter((p) => !p.成果.length).forEach((p) => rows.push({ label: p.gc, status: 'planned', when: '', sub: scn(p.场景) }));
    rows.sort((a, b) => whenYear(a.when) - whenYear(b.when));
    return `<div class="wc-glegend">横轴＝时间 · 每个需求三段：<b class="i">Issue</b> → <b class="p">PR</b> → <b class="m">Merge</b>（斜纹＝预计）</div>
      <div class="wc-gantt"><div class="wc-gchart2">
        <div class="wc-gbg2">${YEARS.map(() => '<span></span>').join('')}</div>
        <div class="wc-gyears">${YEARS.map((y) => `<span>${y}</span>`).join('')}</div>
        ${rows.map(ganttRow).join('')}</div></div>`;
  }

  // 场景：按 scene 分组成果卡
  function renderScenario() {
    const scenes = [...new Set(allPains().map((p) => p.场景))];
    return `<div class="wc-galwrap">${scenes.map((sc) => {
      const pains = allPains().filter((p) => p.场景 === sc), achs = pains.flatMap((p) => p.成果);
      const cards = achs.map((a) => `<div class="wc-gcard">
          <div style="display:flex;gap:8px;align-items:center">${statusTag(a.status)}<span class="wc-pr" style="margin-left:auto">${a.when || ''}</span></div>
          <span class="gtitle">${a.title}</span><p class="gsum">PR #${a.prId} · ${scn(a.场景)}</p>
          <div class="wc-gacts">${a.status === 'live' ? `<button class="wc-chip2 go" data-try="${a.prId}">试玩</button>` : subBtn('a' + a.prId)}${likeBtn(a)}</div></div>`).join('')
        + pains.filter((p) => !p.成果.length).map((p) => `<div class="wc-gcard">
          <div>${statusTag('planned')}</div><span class="gtitle">${p.gc}</span><p class="gsum">想做 · ${scn(p.场景)}</p>
          <div class="wc-gacts">${votePill(p.id, p.votes)}${subBtn(p.id)}</div></div>`).join('');
      return `<div><div class="wc-galhead">${sceneTag(sc)}<h3>${pains.length} 个痛点 · ${achs.length} 个成果</h3><span class="cnt">已上线 ${achs.filter((a) => a.status === 'live').length}</span></div><div class="wc-gal">${cards}</div></div>`;
    }).join('')}</div>`;
  }

  function renderView() { const v = $('#wc-view'); v.innerHTML = view === 'timeline' ? renderTimeline() : view === 'scenario' ? renderScenario() : renderValue(); }
  function renderViewTabs() { $('#wc-tabs').innerHTML = VIEWS.map((v) => `<button class="${v.k === view ? 'on' : ''}" data-view="${v.k}">${v.label}</button>`).join(''); $('#wc-hint').textContent = VIEW_HINT[view]; }
  function renderTicker() { $('#wc-ticker').innerHTML = `<div class="tk">${[0, 1].map(() => TICKER.map((e) => `<span class="wc-ev"><span class="pr">${e.pr}</span> <b>${e.txt}</b></span>`).join('')).join('')}</div>`; }
  function renderStatus() {
    const me = you(), tb = totalBets(me);
    const eye = tb >= MIN_BETS ? '#' + eyeRank() : '未上榜', rate = tb ? Math.round(hitRate(me) * 100) + '%' : '—';
    const open = POSITIONS.filter((p) => p.status === 'open').length;
    $('#wc-status').innerHTML = `
      <div class="wc-stat"><div class="n">${fmt(LEDGER.renown)}<span class="u">声望</span></div><div class="k">押注余额</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-lb="eye"><div class="n">${eye}</div><div class="k">眼光榜 · 命中率 ${rate}</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-lb="renown"><div class="n">#${renownRank()}</div><div class="k">声望榜 · ${me.hits}胜${me.misses}负</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-panel="want"><div class="n">${voted.size}</div><div class="k">我想要</div></div>
      <div class="wc-sep"></div>
      <div class="wc-stat click" data-panel="positions"><div class="n">${POSITIONS.length}</div><div class="k">仓位 · 待结算 ${open}</div></div>
      <div class="sp"></div>
      <button class="gold" id="wc-record">晒战绩</button>`;
  }
  function renderAll() { renderStatus(); renderTicker(); renderViewTabs(); renderView(); }

  // ── modal / toast ─────────────────────────────────────────────────────────
  function toast(msg) { let t = $('#wc-toast'); if (!t) { t = el('div', 'wc-toast'); t.id = 'wc-toast'; document.body.appendChild(t); } t.textContent = msg; t.classList.add('show'); clearTimeout(t._t); t._t = setTimeout(() => t.classList.remove('show'), 2300); }
  function openModal(html, wide) {
    let m = $('#wc-modal-root'); if (!m) { m = el('div'); m.id = 'wc-modal-root'; document.body.appendChild(m); }
    m.innerHTML = `<div class="wc-mask" data-mask><div class="wc-modal${wide ? ' wide' : ''}">${html}<span class="x" data-close>×</span></div></div>`;
    m.onclick = (e) => { const bet = e.target.closest('[data-bet]'); if (bet) { const [mid, sk] = bet.dataset.bet.split('|'); openBet(mid, sk); return; } if (e.target.closest('[data-close]') || e.target.hasAttribute('data-mask')) closeModal(); };
  }
  function closeModal() { const m = $('#wc-modal-root'); if (m) m.innerHTML = ''; }

  // ── 我想要（vote）────────────────────────────────────────────────────────
  function doVote(id) {
    const it = painById(id) || DATA.定位.find((d) => d.id === id);
    if (voted.has(id)) { voted.delete(id); if (it) it.votes--; toast('已取消「我想要」'); }
    else { voted.add(id); if (it) it.votes++; subscribed.add(id); toast('已记一票 · 解锁/上线邮件通知你'); }
    renderAll();
  }
  function onVote(id) {
    if (voted.has(id) || myEmail) { doVote(id); return; }
    const it = painById(id) || DATA.定位.find((d) => d.id === id);
    openModal(`<h3>我想要</h3>
      <p class="wc-msub">留个邮箱，<b style="color:var(--ink)">${it ? (it.gc || it.title) : ''}</b> 有进展 / 上线第一时间通知你（同时算你一票）。</p>
      <div class="wc-field"><label>邮箱 · Email</label><input id="wc-email" placeholder="you@company.com"></div>
      <button class="wc-mbtn" id="wc-wgo">投一票 + 接收通知</button>
      <p class="wc-mnote">仅用于上线通知 · demo 不真实发送</p>`);
    $('#wc-wgo').onclick = () => { const v = $('#wc-email').value.trim(); if (!v || !v.includes('@')) { toast('填个有效邮箱'); return; } myEmail = v; closeModal(); doVote(id); };
  }

  // ── 押注 ──────────────────────────────────────────────────────────────────
  function openBet(mid, sk) {
    const m = mkById(mid); if (!m) return; const s = m.sides.find((x) => x.key === sk), o = odds(m, sk), p = painById(m.painId), isLong = sk === 'long';
    let amt = Math.min(200, LEDGER.renown); const quick = [100, 200, 500];
    openModal(`<h3>${p ? p.gc : m.id} · 做得出来吗？</h3>
      <p class="wc-msub">赌这个痛点会不会在结算窗口内被做出来（PR 合并）</p>
      <div class="wc-betpick">你押：<b style="color:${isLong ? 'var(--jade)' : 'var(--red)'}">${s.label}</b> · 赔率 <b style="color:var(--accent-press)">${o.toFixed(2)}×</b></div>
      <div class="wc-amtrow" id="wc-amtrow">${quick.map((a) => `<button class="wc-amtb" data-amt="${a}">${a}</button>`).join('')}<button class="wc-amtb" data-amt="all">全下</button></div>
      <div class="wc-winline">押 <b id="wc-amtshow">${amt}</b> 声望 · 预计可赢 <b id="wc-winshow" style="color:var(--accent-press)">${Math.round(amt * o)}</b></div>
      <button class="wc-mbtn" id="wc-confirmbet">确认押注</button>
      <p class="wc-mnote">虚拟声望 · 结算认 PR 合并 · 不可提现</p>`);
    const refresh = () => { $('#wc-amtshow').textContent = amt; $('#wc-winshow').textContent = Math.round(amt * o); $$('#wc-amtrow .wc-amtb').forEach((b) => b.classList.toggle('on', (b.dataset.amt === 'all' && amt === LEDGER.renown) || b.dataset.amt === String(amt))); };
    $('#wc-amtrow').onclick = (e) => { const b = e.target.closest('[data-amt]'); if (!b) return; amt = b.dataset.amt === 'all' ? LEDGER.renown : Math.min(+b.dataset.amt, LEDGER.renown); refresh(); };
    $('#wc-confirmbet').onclick = () => { if (amt <= 0) { toast('声望不足'); return; } const r = stake(mid, sk, amt); if (!r.ok) { toast(r.msg); return; } closeModal(); toast(`已押 ${fmt(amt)} 声望 · 锁定 ${r.lo.toFixed(2)}×`); renderAll(); };
    refresh();
  }

  // ── 面板 / 双榜 / 提需求 / 分享 ────────────────────────────────────────────
  function renderWantList() { const ids = [...voted]; if (!ids.length) return `<div class="wc-empty">还没投「我想要」。在痛点上投票，攒够票团队就排上日程。</div>`;
    return `<div class="wc-poslist">${ids.map((id) => { const p = painById(id) || DATA.定位.find((d) => d.id === id); if (!p) return ''; const isPain = !!p.gc;
      return `<div class="wc-posrow"><div><div class="pt">${p.gc || p.title}</div><div class="ps">${isPain ? scn(p.场景) + ' · ' : ''}${p.votes} 票</div></div>${isPain ? statusTag(painStatus(p)) : ''}</div>`; }).join('')}</div>`; }
  function renderPositions() { if (!POSITIONS.length) return `<div class="wc-empty">还没押注。在痛点上「看多 / 看空」它做不做得出来，仓位会出现在这里。</div>`;
    return `<div class="wc-poslist">${[...POSITIONS].reverse().map((p) => { const m = mkById(p.mid), pain = m ? painById(m.painId) : null, s = m.sides.find((x) => x.key === p.sk);
      return `<div class="wc-posrow"><div><div class="pt">${pain ? pain.gc : p.mid}</div><div class="ps">押「${s.label}」· 锁定 ${p.lo.toFixed(2)}×</div></div><div class="right"><div class="pa">${fmt(p.amount)} 声望</div><div class="ps">可赢 ${fmt(p.amount * p.lo)}</div></div><span class="wc-ptag pr">待结算</span></div>`; }).join('')}</div>`; }
  function openPanel(which) { const map = { want: ['我想要的痛点', renderWantList], positions: ['我的预测仓位', renderPositions] }; const [title, fn] = map[which]; openModal(`<h3>${title}</h3><div style="margin-top:14px;max-height:62vh;overflow:auto">${fn()}</div>`, true); }
  function openLeaderboard(which) {
    which = which === 'renown' ? 'renown' : 'eye'; const me = you();
    const rows = which === 'eye' ? [...RIVALS, me].filter((r) => r.me || totalBets(r) >= MIN_BETS).sort((a, b) => hitRate(b) - hitRate(a) || b.hits - a.hits) : [...RIVALS, me].sort((a, b) => b.renown - a.renown);
    const body = rows.map((r, i) => `<div class="wc-lbrow${r.me ? ' me' : ''}"><span class="rk">${i + 1}</span><span class="nm">${r.name}${r.me ? '（你）' : ''}</span><span class="mt2">${which === 'eye' ? (totalBets(r) ? `${Math.round(hitRate(r) * 100)}% · ${r.hits}胜${r.misses}负` : '—') : `${fmt(r.renown)} 声望`}</span></div>`).join('');
    openModal(`<h3>排行榜</h3><div class="wc-lbtabs" style="margin-top:16px"><button class="${which === 'eye' ? 'on' : ''}" data-lbt="eye">眼光榜 · 命中率</button><button class="${which === 'renown' ? 'on' : ''}" data-lbt="renown">声望榜 · 总量</button></div><div style="margin-top:8px;max-height:54vh;overflow:auto">${body}</div><p class="wc-mnote" style="margin-top:12px">眼光榜需 ≥${MIN_BETS} 注上榜 · 虚拟声望 · 不可提现</p>`, true);
    $$('[data-lbt]').forEach((b) => (b.onclick = () => openLeaderboard(b.dataset.lbt)));
  }
  function openPropose() {
    openModal(`<h3>提个需求（开一个痛点）</h3>
      <p class="wc-msub">提交后进入价值树的「想做」，等同行投票。攒够票就排日程。</p>
      <div class="wc-field"><label>一句话痛点</label><input id="wc-ptitle" placeholder="例：想要个界面还得等开发排期" maxlength="28"></div>
      <div class="wc-field"><label>场景</label><select id="wc-pscene"><option>连接</option><option>稳定</option><option>生成</option><option>定制</option><option>扩展</option><option>观测</option><option>工具</option></select></div>
      <div class="wc-field"><label>战略定位</label><select id="wc-ppos">${DATA.定位.map((d) => `<option value="${d.id}">${d.title}</option>`).join('')}</select></div>
      <button class="wc-mbtn" id="wc-confirmprop">提交（开痛点）</button>`);
    $('#wc-confirmprop').onclick = () => { const title = $('#wc-ptitle').value.trim(); if (!title) { toast('给痛点起一句话'); return; }
      const pos = DATA.定位.find((d) => d.id === $('#wc-ppos').value); if (!pos) return;
      const id = 'p-new' + (++SEQ); pos.痛点.unshift({ id, gc: title, 场景: $('#wc-pscene').value, votes: 1, 成果: [] });
      voted.add(id); buildMarkets(); closeModal(); view = 'value'; renderAll(); toast('已开痛点 · 你是第 1 个想要的'); };
  }
  let CARD_NO = 137;
  function shareRecordCard() {
    const me = you(), tb = totalBets(me), rate = tb ? Math.round(hitRate(me) * 100) : 0;
    openModal(`<div class="wc-sharecard"><span class="sc-num">world.cup #${String(++CARD_NO).padStart(6, '0')}</span>
        <div class="sc-eye">我的预测战绩</div><div class="sc-badge">${tb ? `命中率 ${rate}%` : '新晋预言家'}</div>
        <div class="sc-title">我在 world.cup 押 Ezagent 路线图</div>
        <div class="sc-lines"><div class="sc-line"><span>声望</span><b>${fmt(me.renown)}</b></div><div class="sc-line"><span>战绩</span><b>${me.hits} 胜 ${me.misses} 负</b></div><div class="sc-line"><span>我想要</span><b>${voted.size} 个</b></div></div>
        <div class="sc-cta">来 world.cup 押你看好的功能，赌它做不做得出来 →</div><div class="sc-brand">Ezagent · world.cup · Issue, PR, Merge!</div></div>
      <div class="wc-sharebtns"><button class="b g" id="wc-sctxt">复制文案</button><button class="b gold" data-close>完成</button></div>`, true);
    $('#wc-sctxt').onclick = () => { (navigator.clipboard?.writeText(`我在 Ezagent world.cup 押路线图：命中率 ${rate}%、声望 ${fmt(me.renown)}。来赌你看好的功能。`) || Promise.reject()).then(() => toast('战绩文案已复制 →'), () => toast('复制失败')); };
  }

  // ── boot ──────────────────────────────────────────────────────────────────
  function shell() {
    return `<div class="wc-status" id="wc-status"></div>
      <div class="wc-ticker" id="wc-ticker"></div>
      <div class="wc-viewbar"><div class="wc-tabs" id="wc-tabs"></div><button class="wc-propose" id="wc-propose">+ 提个需求</button></div>
      <div class="wc-hint" id="wc-hint"></div>
      <div id="wc-view"></div>`;
  }
  async function boot() {
    const root = $('#wc-root'); if (!root) return;
    root.innerHTML = '<div class="wc-hint">loading roadmap…</div>';
    DATA = await EZ.worldcup(); buildMarkets();
    root.innerHTML = shell();
    $('#wc-tabs').addEventListener('click', (e) => { const b = e.target.closest('[data-view]'); if (!b) return; view = b.dataset.view; renderViewTabs(); renderView(); });
    $('#wc-status').addEventListener('click', (e) => {
      const p = e.target.closest('[data-panel]'); if (p) { openPanel(p.dataset.panel); return; }
      const lb = e.target.closest('[data-lb]'); if (lb) { openLeaderboard(lb.dataset.lb); return; }
      if (e.target.closest('#wc-record')) { shareRecordCard(); return; }
    });
    $('#wc-propose').addEventListener('click', openPropose);
    $('#wc-view').addEventListener('click', (e) => {
      let b;
      if (b = e.target.closest('[data-vote]')) { onVote(b.dataset.vote); return; }
      if (b = e.target.closest('[data-bet]')) { const [mid, sk] = b.dataset.bet.split('|'); openBet(mid, sk); return; }
      if (b = e.target.closest('[data-sub]')) { const id = b.dataset.sub; subscribed.has(id) ? subscribed.delete(id) : subscribed.add(id); toast(subscribed.has(id) ? '已订阅 · 上线第一时间通知你' : '已取消订阅'); renderView(); return; }
      if (b = e.target.closest('[data-like]')) { const id = +b.dataset.like; liked.has(id) ? liked.delete(id) : liked.add(id); renderView(); return; }
      if (b = e.target.closest('[data-try]')) { toast('demo · 试玩跳转（原型未接）'); return; }
    });
    renderAll();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
