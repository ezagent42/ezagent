/* ============================================================================
 * mock-ezagent-api.js  ·  官网 demo 的数据层（mock ezagent runtime）
 * ----------------------------------------------------------------------------
 * 遵 #1072：业务概念只活在数据层。视图（mainsite.html）只 render 这里的产物，
 * 不硬编业务数据。ezagent 没有 OpenAPI/swagger —— 它的 API 模型就是
 * dispatch(action, args) → result。这里三个"端点"的形状照抄真实运行时：
 *
 *   EZ.introspect()  仿 apps/ezagent_core/lib/ezagent/behavior/introspection.ex
 *                    → { action_names:[atom], action_spec:{ name:{args,returns,caps} } }
 *   EZ.chatFeed()    抄 apps/ezagent_web/lib/.../socialware/feed_encoding.ex
 *                    → [ { id, text, sender:"<uri>", render, render_css } ]
 *   EZ.kanbanTree()  抄 kanban behavior get_tree（apps/ezagent_plugin_kanban）
 *                    → { nodes:{ id:{title,stage,status,owner,parent_id,order} }, stages:[] }
 *
 * ⚠ kanban schema 待 jjkysy(#1020) 最终确认 —— 现按已知 get_tree 形状搭。
 * 所有数据为 mock；真实接入由 zhaomato 在 @json-render 底座上替换。
 * ========================================================================== */
(function (global) {
  'use strict';

  // ── contributors · 数据源 docs/together/team.md（2026-06-25 roster）─────────
  const CONTRIBUTORS = [
    { gh: 'allenwoods',          cn: '林懿伦', role: 'lead',       track: 'dev-together lead · 架构地基 / 部署',           bg: '全栈 · AI 博士 · lead programmer', tz: 'GMT+9' },
    { gh: 'jjkysy',              cn: '姚升悦', role: 'human-dev',  track: '架构/原则把关 · kanban 插件原作',              bg: '全栈 · AI 博士 · dev-together owner', tz: 'GMT+8' },
    { gh: 'gagameow',            cn: '黄佳佳', role: 'human-dev',  track: 'agent-config 后端契约',                       bg: '运维 · 部署/运维 · 产品 sense',     tz: 'GMT+8' },
    { gh: 'zyli-developer',      cn: '李震宇', role: 'human-dev',  track: '人肉 full-flow validation · E2E',             bg: '全栈 · 端到端验证强',               tz: 'GMT+8' },
    { gh: 'zhaomaota97',         cn: '张宁',   role: 'human-dev',  track: '官网（@json-render 底座）',                   bg: '全栈 · 前端 json-render / hello 渲染', tz: 'GMT+8' },
    { gh: 'FatNine',             cn: '戴明',   role: 'human-dev',  track: '#84 Agent Console CRUD',                      bg: '后端 · core',                       tz: 'GMT+8' },
    { gh: 'ruihuachen-designer', cn: '陈瑞华', role: 'designer',   track: '产品 / 设计版式 · 可外发文档',                bg: '产品经理 · 设计输入',               tz: 'GMT+8' },
    { gh: 'claude',              cn: 'Claude', role: 'agent',      track: 'off-plan support · 编排 / 修复',              bg: 'AI agent',                          tz: '—' },
    { gh: 'codex',               cn: 'Codex',  role: 'agent',      track: 'off-plan support · 有界可验子任务',           bg: 'AI agent',                          tz: '—' },
  ];

  // ── 看板 1 · 团队开发看板（dev-together：plan→dive→return→review）───────────
  //    用 team.md 的 current_track 当卡，列 = dev-together 当日流程阶段。
  const KANBAN_DEV = {
    title: '团队开发看板 · Dev Board',
    subtitle: 'dev-together 每日流程 · plan → dive → return → review',
    stages: ['plan', 'dive', 'return', 'review', 'shipped'],
    nodes: {
      d1: { title: 'dev-together lead（plan/handoff/close/review）', stage: 'review',  status: 'in_progress', owner: 'allenwoods',     parent_id: null, order: 0 },
      d2: { title: '官网 demo（3 段 + mock API · DS reskin）',        stage: 'dive',    status: 'in_progress', owner: 'ruihuachen-designer', parent_id: null, order: 1 },
      d3: { title: '官网 go-live（@json-render 底座承接）',           stage: 'plan',    status: 'unassigned',  owner: 'zhaomaota97',    parent_id: null, order: 2 },
      d4: { title: 'agent-config 后端契约（#84）',                    stage: 'dive',    status: 'in_progress', owner: 'gagameow',       parent_id: null, order: 3 },
      d5: { title: 'Agent Console CRUD（#84）',                       stage: 'return',  status: 'in_progress', owner: 'FatNine',        parent_id: null, order: 4 },
      d6: { title: '人肉 full-flow validation · E2E',                stage: 'return',  status: 'in_progress', owner: 'zyli-developer', parent_id: null, order: 5 },
      d7: { title: 'cc-headless 真实实现（#931）',                    stage: 'shipped', status: 'done',        owner: 'gagameow',       parent_id: null, order: 6 },
      d8: { title: 'kanban-as-role 后端（#1007）',                    stage: 'shipped', status: 'done',        owner: 'jjkysy',         parent_id: null, order: 7 },
    },
  };

  // ── 看板 2 · 价值链 board（真实 export：homesite-value-chain，149 节点采样）──
  //    数据采样自 entity://system/agent/homesite-value-chain 的 get_tree。
  //    5 大段 = depth-2；这里展示段 + 每段代表卡，counts 为真实全量。
  const KANBAN_VALUECHAIN = {
    title: '官网价值链 V · Value-Chain Board',
    subtitle: '真实看板采样 · entity://system/agent/homesite-value-chain · 149 节点 / 62 spec 卡',
    stages: ['positioning', 'metric', 'pain', 'anchor', 'ux', 'feature', 'issue', 'test', 'pr'],
    segments: [
      { id: 's1', title: '0→1 段 · 把官网从无到有立起来', count: 8,  metric: '里程碑 ✓/✗',
        cards: ['0-A1 站点骨架+部署上线 · P0', '②-C1 内嵌可跑 demo · P0', 'W-1 GitHub 内容同步 · P1'] },
      { id: 's2', title: 'AARRR 段 · 漏斗优化', count: 40, metric: '率',
        cards: ['①-B1 首屏一句话主张 · P0', '②-A1 空框引导 · P0', '③-A1 低摩擦留资 · P0', '④-A1 明码价格表 · P0'] },
      { id: 's3', title: '价值传达段 · 增益直说 + Solutions', count: 6, metric: '增益看懂率',
        cards: ['增-A1 增益主张 · P0', '增-B1 Solutions tab 骨架 · P1'] },
      { id: 's4', title: '裂变引擎段 · 攀比/对赌锚点', count: 2, metric: '裂变系数 K',
        cards: ['⑤-C1 指挥官驾照测试 · P1', '②-D1 路线图押注 · P2'] },
      { id: 's5', title: '产品发现/验证段 · 画像校准', count: 6, metric: '研究闭环计数',
        cards: ['V-1-A1 验证落地面 · P1', 'V-2-A1 采集引擎 · P1', 'V-3-A1 靶心三件套打分器 · P2'] },
    ],
  };

  // ── 介绍段 · hello「界面即问即生」交互气泡（chat-feed wire shape）──────────
  //    一句话 → hello 长出界面。render 是 json-render 节点树（与 preview 同引擎），
  //    这里 demo 用一个极简节点 schema：{ kind, props, children }。
  const CHAT_SCRIPT = [
    {
      prompt: '给跨境电商客服做一个工单看板',
      reply: {
        id: 'm1', sender: 'agent://system/hello', text: '已为你长出一个客服工单看板 —',
        render: { kind: 'board', props: { title: '客服工单 · 实时' }, children: [
          { kind: 'col', props: { title: '待处理', tone: 'red' },  children: [
            { kind: 'ticket', props: { text: '物流延迟咨询 · #2381', tag: '高' } },
            { kind: 'ticket', props: { text: '退款申请 · #2379', tag: '中' } } ] },
          { kind: 'col', props: { title: 'AI 处理中', tone: 'blue' }, children: [
            { kind: 'ticket', props: { text: '尺码推荐 · #2382', tag: 'AI' } } ] },
          { kind: 'col', props: { title: '已解决', tone: 'jade' }, children: [
            { kind: 'ticket', props: { text: '订单查询 · #2375', tag: '✓' } } ] },
        ] },
      },
    },
    {
      prompt: '加一个今天处理量的数字卡',
      reply: {
        id: 'm2', sender: 'agent://system/hello', text: '加好了，实时统计 —',
        render: { kind: 'stat', props: { label: '今日处理量 · today', value: '1,284', unit: 'tickets', delta: '+18%' } },
      },
    },
    {
      prompt: '把客服换成我的品牌蓝',
      reply: {
        id: 'm3', sender: 'agent://system/hello', text: '换成品牌蓝了，界面为你这一刻重新组合 —',
        render: { kind: 'stat', props: { label: '今日处理量 · today', value: '1,284', unit: 'tickets', delta: '+18%', accent: '#0B5CFF' } },
      },
    },
  ];

  // ── introspect · 仿 behavior/introspection（action_names + action_spec）─────
  const INTROSPECT = {
    action_names: ['workspace.create_agent', 'agent.invoke', 'session.create', 'kanban.import_markmap', 'kanban.get_tree'],
    action_spec: {
      'workspace.create_agent': { args: ['flavor', 'name', 'role?'], returns: 'entity://…/agent/<name>', caps: ['workspace.manage'] },
      'agent.invoke':           { args: ['target', 'action', 'args'], returns: '{ok, result}',            caps: ['agent.invoke'] },
      'session.create':         { args: ['workspace', 'participants'], returns: 'session://…',             caps: ['session.create'] },
      'kanban.import_markmap':  { args: ['markdown'],                 returns: '{nodes_created}',          caps: ['kanban.import_markmap'] },
      'kanban.get_tree':        { args: [],                           returns: '{nodes, stages}',          caps: ['kanban.get_tree'] },
    },
  };

  // ── world.cup 路线图 · v2 嵌套模型（定位 → 痛点 → 成果）──────────────────────
  //    成果 = 真实 GitHub PR（merged→live 已上线 / open→wip 在做）；prId/title/status 真实。
  //    痛点(planned，成果为空) ← 真实 open issue。votes=「我想要」票数。结算真相源=PR 合并。
  //    来源：github.com/ezagent42/ezagent（merged PR #1065–#1085 · open PR/issue）。
  const WORLDCUP = {
    定位: [
      { id: 'pos-world', title: 'world｜让消息在工具、渠道、AI 之间顺畅流转', votes: 46, 痛点: [
        { id: 'p-w1', gc: '每接一个新渠道，都要重做一遍', 场景: '连接', votes: 40, 成果: [
          { prId: 1069, title: '统一 socialware 对客流水线 P1–P10', 场景: '连接', when: '2026 Q2', status: 'live', likes: 21 },
          { prId: 1066, title: 'cc ReadyGate 经 bridge-bind 接住消息', 场景: '连接', when: '2026 Q2', status: 'live', likes: 9 },
        ] },
        { id: 'p-w2', gc: '消息偶尔悄悄丢了 / 架构纪律守不住', 场景: '稳定', votes: 33, 成果: [
          { prId: 1075, title: 'kanban 9 阶段业务链 code→data（消除越界）', 场景: '稳定', when: '2026 Q2', status: 'live', likes: 8 },
          { prId: 1072, title: '4 层载体边界 + 反模式收口', 场景: '稳定', when: '2026 Q2', status: 'live', likes: 6 },
        ] },
        { id: 'p-w3', gc: 'URI / 文档跨仓库对不齐（issue #895）', 场景: '观测', votes: 17, 成果: [] },
      ] },
      { id: 'pos-hello', title: 'hello｜用一句话，生成你要的界面', votes: 39, 痛点: [
        { id: 'p-h1', gc: '想要个界面，还得等开发排期', 场景: '生成', votes: 38, 成果: [
          { prId: 1065, title: 'hello 渲染岛接进共享 aliases（部署前置）', 场景: '生成', when: '2026 Q2', status: 'live', likes: 12 },
          { prId: 1083, title: '把 handoff 界面迁到 shadcn 品牌系统', 场景: '定制', when: '2026 Q2', status: 'wip', likes: 7 },
        ] },
        { id: 'p-h2', gc: '客户面冷启动 302 / SPA 构建不出来（issue #878/#879）', 场景: '定制', votes: 22, 成果: [] },
      ] },
      { id: 'pos-platform', title: '平台｜底座、插件与开发流程', votes: 28, 痛点: [
        { id: 'p-p1', gc: '扩展能力得改底层、热加载难', 场景: '扩展', votes: 24, 成果: [
          { prId: 1076, title: 'plugin-package 全 Q1-C：manifest + 热加载 + 热卸载', 场景: '扩展', when: '2026 Q2', status: 'live', likes: 14 },
        ] },
        { id: 'p-p2', gc: '团队开发流程看不见、对不齐', 场景: '工具', votes: 19, 成果: [
          { prId: 1020, title: 'kanban 穿起团队开发全流程（分 Phase 实施）', 场景: '工具', when: '2026 Q2', status: 'wip', likes: 11 },
        ] },
      ] },
    ],
  };

  // ── public API（async 仿网络，且证明视图走"接口"而非直读常量）──────────────
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  global.EZ = {
    async contributors() { await wait(120); return CONTRIBUTORS.slice(); },
    async kanbanDev()    { await wait(160); return JSON.parse(JSON.stringify(KANBAN_DEV)); },
    async kanbanValueChain() { await wait(160); return JSON.parse(JSON.stringify(KANBAN_VALUECHAIN)); },
    async worldcup()     { await wait(160); return JSON.parse(JSON.stringify(WORLDCUP)); },
    async introspect()   { await wait(100); return JSON.parse(JSON.stringify(INTROSPECT)); },
    chatScript()         { return JSON.parse(JSON.stringify(CHAT_SCRIPT)); },
    // chat-feed wire shape：把一条 reply 编成 feed_encoding 的 {id,text,sender,render}
    async chatFeed(i)    { await wait(420); const s = CHAT_SCRIPT[i]; return s ? [s.reply] : []; },
  };
})(window);
