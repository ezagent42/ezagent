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
  @media (max-width:860px){.wc-grid{grid-template-columns:1fr}}
  `;
  if (!$('#wc-style')) { const s = el('style'); s.id = 'wc-style'; s.textContent = CSS; document.head.appendChild(s); }

  // ── 状态 ────────────────────────────────────────────────────────────────
  let ITEMS = [];
  const item = (id) => ITEMS.find((i) => i.id === id);

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
  function l1Display(it) {
    if (it.stage === 'merged') return `<div class="wc-merged">已上线 · ${it.prRef || it.id}</div>`;
    const pct = Math.min(100, Math.round((it.waitlist / it.unlockAt) * 100));
    const unlocked = it.waitlist >= it.unlockAt;
    return `<div class="wc-wmeta"><span>候补 ${it.waitlist} / ${it.unlockAt}</span>${unlocked ? '<span class="ok">已解锁，团队评估中</span>' : `<span>再 ${it.unlockAt - it.waitlist} 人解锁</span>`}</div>
      <div class="wc-prog"><i style="width:${pct}%"></i></div>`;
  }
  function itemCard(it) {
    return `<div class="wc-card" data-id="${it.id}">
      <div class="wc-h"><span class="wc-title">${it.title}</span>${stageTag(it.stage)}</div>
      <div class="wc-chips"><span class="wc-chip"><b>${it.id}</b> ${it.scene}</span><span class="wc-chip">${it.pos}</span>${it.when ? `<span class="wc-chip">${it.when}</span>` : ''}</div>
      ${l1Display(it)}
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
    return `<div class="wc-viewbar"><div class="wc-tabs" id="wc-tabs"></div></div>
      <div class="wc-hint" id="wc-hint"></div>
      <div id="wc-view"></div>`;
  }

  // ── boot ──────────────────────────────────────────────────────────────────
  async function boot() {
    const root = $('#wc-root'); if (!root) return;
    root.innerHTML = '<div class="wc-hint">loading roadmap…</div>';
    ITEMS = await EZ.worldcup();
    root.innerHTML = shell();
    $('#wc-tabs').addEventListener('click', (e) => {
      const b = e.target.closest('[data-view]'); if (!b) return;
      view = b.dataset.view; renderViewTabs(); renderView();
    });
    renderViewTabs();
    renderView();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
