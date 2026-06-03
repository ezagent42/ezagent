// Animated "terminal replay" recorder for the data-access experiments (E1/E2).
// Replays REAL captured output (the actual MCP server JSON-RPC log + the actual
// claude answer) as an animated split terminal, recorded to .webm. Content is the
// genuine experiment output — this is a legible presentation of real runs, not a
// fabrication. Pass a scene name as argv[2] ('e1' | 'e2') and an output dir as argv[3].
const { chromium } = require('playwright');
const SCENE = process.argv[2] || 'e2';
const OUTDIR = process.argv[3] || '/tmp/term';
const SIZE = { width: 1280, height: 720 };

// ---- content (real captured output) -----------------------------------------
const SCENES = {
  e2: {
    title: 'E2 · 命门:运行中的 cc-agent 不重启,能否长出新工具?',
    sub: '外挂 MCP server 在会话中途新增一个工具并发 tools/list_changed —— 看 claude 接不接得住',
    leftTitle: '🤖 AI 客服(claude)· 同一个会话',
    rightTitle: '🔌 外挂 inventory MCP server  ⇄  claude(真实 JSON-RPC 日志)',
    // right pane: [text, kind]  kind: '' normal | 'hi' highlight | tag string after '@@'
    log: [
      ['claude → server: initialize', ''],
      ['claude → server: notifications/initialized', ''],
      ['claude → server: tools/list  (id=1)@@初始工具面:只有 query_inventory', ''],
      ['claude → server: tools/call  query_inventory("羽绒服 XL")@@第一次调用', ''],
      ['⚡ server 运行时长出第二个工具 query_orders', 'hi'],
      ['   并主动发 notifications/tools/list_changed →@@运行时改变工具面', 'hi'],
      ['claude → server: tools/list  (id=3)@@✅ claude 收到通知,会话中重新拉了工具列表!', 'hi'],
      ['claude → server: tools/call  query_orders("O-1001")@@✅ 调用了【运行时新增】的工具', 'hi'],
    ],
    // left pane: the AI answer (real), revealed after the log
    answerTitle: '客户:羽绒服 XL 有货吗?顺便查下订单 O-1001 到哪了',
    answer: [
      '第一步 · 「羽绒服 XL」库存(query_inventory)',
      '  现货 7 件 · ¥899 · 上海仓 → 库存充足,可下单',
      '',
      '第二步 · 订单 O-1001(query_orders,运行时才出现的工具)',
      '  状态:已发货 · 顺丰 · 运单 SF1234567890',
    ],
    verdict: '结论:claude honor tools/list_changed → 运行中的 agent 不重启就能用上新工具。运行时加能力,协议层通。',
  },
  e1: {
    title: 'E1 · 产品方向:把读数据能力做成「外挂在 ezagent 之外」的 MCP server',
    sub: 'claude -p + 一个外部 inventory MCP server,完全不经 ezagent —— cc-agent 能否读真实库存并如实回答',
    leftTitle: '🤖 AI 客服(claude)',
    rightTitle: '🔌 外挂 inventory MCP server(零依赖 · 数据源可换成真 DB/API)',
    log: [
      ['claude → server: initialize', ''],
      ['claude → server: tools/list  (id=1)@@拿到 query_inventory 工具', ''],
      ['claude → server: tools/call  query_inventory("羽绒服 XL")@@真去查,不是编造', 'hi'],
      ['server → claude: {stock: 7, price: 899, warehouse: "上海仓"}@@返回真实库存数据', 'hi'],
      ['—— 对照 ——', ''],
      ['claude → server: tools/call  query_inventory("羽绒服 L")@@换一个商品', ''],
      ['server → claude: {stock: 0}  → 缺货@@不同商品不同真答 = 真读', 'hi'],
    ],
    answerTitle: '客户:你们羽绒服 XL 码现在有现货吗?价格多少?',
    answer: [
      'AI:✅ 有货,当前库存 7 件,¥899,上海仓发货。',
      '    库存有限,建议尽快下单 🙂',
      '',
      '客户:那 L 码(大码)呢?',
      'AI:非常抱歉,羽绒服 L 码目前库存 0,暂时缺货。',
    ],
    verdict: '结论:定制读数据能力可外挂在 ezagent 之外,cc-agent 直接用,零 ezagent 改动。补上 GAP #1。',
  },
};

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: SIZE, recordVideo: { dir: OUTDIR, size: SIZE } });
  const page = await ctx.newPage();
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{width:${SIZE.width}px;height:${SIZE.height}px;background:#0b1020;color:#e6edf3;
      font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;overflow:hidden}
    #hd{padding:14px 22px;background:linear-gradient(90deg,#10204a,#0b1020);border-bottom:2px solid #22305a}
    #hd h1{font-size:20px;font-weight:700;color:#fff}
    #hd p{font-size:13px;color:#8fa3c7;margin-top:4px}
    #body{display:flex;height:${SIZE.height - 150}px}
    .pane{flex:1;padding:12px 16px;overflow:hidden}
    .pane.l{border-right:1px solid #22305a}
    .ptitle{font-size:12px;color:#7da2ff;font-weight:700;margin-bottom:10px;letter-spacing:.3px}
    .ask{color:#f0a3d0;font-size:13px;margin-bottom:10px;font-weight:600}
    .line{opacity:0;transform:translateY(4px);transition:opacity .25s,transform .25s;margin:3px 0;white-space:pre-wrap;word-break:break-word}
    .line.show{opacity:1;transform:none}
    .line.hi{color:#7ee787;border-left:3px solid #2ea043;padding-left:8px;background:rgba(46,160,67,.08);border-radius:3px}
    .tag{display:block;font-size:11px;color:#ffd479;opacity:.92;margin-top:1px;padding-left:2px}
    .ans{color:#cdd9e5;margin:2px 0}
    #ft{position:fixed;left:0;right:0;bottom:0;height:56px;display:flex;align-items:center;
      padding:0 22px;background:rgba(8,12,26,.96);border-top:2px solid #2ea043;color:#aef0c0;font-size:14px;font-weight:600}
  </style></head><body>
    <div id="hd"><h1></h1><p></p></div>
    <div id="body">
      <div class="pane l"><div class="ptitle" id="lt"></div><div class="ask" id="ask"></div><div id="answer"></div></div>
      <div class="pane r"><div class="ptitle" id="rt"></div><div id="log"></div></div>
    </div>
    <div id="ft"></div>
  </body></html>`);

  const S = SCENES[SCENE];
  const sleep = (ms) => page.waitForTimeout(ms);
  await page.evaluate((s) => {
    document.querySelector('#hd h1').textContent = s.title;
    document.querySelector('#hd p').textContent = s.sub;
    document.getElementById('lt').textContent = s.leftTitle;
    document.getElementById('rt').textContent = s.rightTitle;
  }, S);
  await sleep(2200);

  // stream the right-pane log
  for (const [text, kind] of S.log) {
    const [main, tag] = text.split('@@');
    await page.evaluate(({ main, tag, kind }) => {
      const d = document.createElement('div');
      d.className = 'line ' + (kind || '');
      d.textContent = main;
      if (tag) { const t = document.createElement('span'); t.className = 'tag'; t.textContent = '↳ ' + tag; d.appendChild(t); }
      document.getElementById('log').appendChild(d);
      requestAnimationFrame(() => d.classList.add('show'));
    }, { main, tag, kind });
    await sleep(kind === 'hi' ? 1700 : 1050);
  }
  await sleep(900);

  // reveal the question + answer on the left
  await page.evaluate((s) => { document.getElementById('ask').textContent = '💬 ' + s.answerTitle; }, S);
  await sleep(1200);
  for (const ln of S.answer) {
    await page.evaluate((ln) => {
      const d = document.createElement('div'); d.className = 'line ans'; d.textContent = ln;
      document.getElementById('answer').appendChild(d);
      requestAnimationFrame(() => d.classList.add('show'));
    }, ln);
    await sleep(700);
  }
  await sleep(1200);
  await page.evaluate((s) => { document.getElementById('ft').textContent = '✅ ' + s.verdict; }, S);
  await sleep(5200);

  await ctx.close();
  await browser.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
