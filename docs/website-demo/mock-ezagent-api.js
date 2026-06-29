/* ============================================================================
 * mock-ezagent-api.js  ·  官网 demo 的数据层（mock ezagent runtime）
 * ----------------------------------------------------------------------------
 * 遵 #1072：业务概念只活在数据层。视图（index.html）只 render 这里的产物，
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

  // ── world.cup 路线图（押注标的）· 产品 feature roadmap（对应价值链产品卡）─────
  //    stage: issue(想做) | pr(在做) | merged(已上线)。waitlist/unlockAt = L1 候补门槛；
  //    t = 甘特时间戳(issue→pr→merge 年份)。结算真相源 = PR 合并。
  const ROADMAP = [
    { id: '#360', pos: 'hello｜界面生成', title: '一句话生成可用界面',   stage: 'pr',     scene: '生成', when: '2025 Q3', waitlist: 128, unlockAt: 150, prRef: '#360', t: { issue: 2025.3, pr: 2025.9, merge: 2026.8 } },
    { id: '#318', pos: 'world｜消息流转', title: '通用 webhook 接入',     stage: 'pr',     scene: '连接', when: '2025 Q3', waitlist: 92,  unlockAt: 120, prRef: '#318', t: { issue: 2025.6, pr: 2026.2, merge: 2026.9 } },
    { id: '#366', pos: 'hello｜界面生成', title: '生成界面可二次编辑',     stage: 'issue',  scene: '定制', when: '',        waitlist: 138, unlockAt: 150, prRef: '',     t: { issue: 2026.2, pr: 2026.9, merge: 2027.2 } },
    { id: '#340', pos: 'world｜消息流转', title: '渠道掉线自动重连',       stage: 'issue',  scene: '稳定', when: '',        waitlist: 64,  unlockAt: 100, prRef: '',     t: { issue: 2026.4, pr: 2027.0, merge: 2027.4 } },
    { id: '#380', pos: 'hello｜界面生成', title: '移动端自适应生成',       stage: 'issue',  scene: '生成', when: '',        waitlist: 77,  unlockAt: 100, prRef: '',     t: { issue: 2026.5, pr: 2027.1, merge: 2027.5 } },
    { id: '#372', pos: 'hello｜界面生成', title: '不同角色看到不同视图',   stage: 'issue',  scene: '定制', when: '',        waitlist: 41,  unlockAt: 100, prRef: '',     t: { issue: 2026.3, pr: 2027.0, merge: 2027.4 } },
    { id: '#355', pos: 'world｜消息流转', title: '消息流量可视化看板',     stage: 'issue',  scene: '观测', when: '',        waitlist: 38,  unlockAt: 100, prRef: '',     t: { issue: 2026.5, pr: 2027.2, merge: 2027.6 } },
    { id: '#312', pos: 'world｜消息流转', title: '常用渠道一键接入',       stage: 'merged', scene: '连接', when: '2025 Q1', waitlist: 210, unlockAt: 120, prRef: '#312', t: { issue: 2024.2, pr: 2024.6, merge: 2025.1 } },
    { id: '#333', pos: 'world｜消息流转', title: '换 AI/后端不用重写',     stage: 'merged', scene: '灵活', when: '2025 Q2', waitlist: 176, unlockAt: 150, prRef: '#333', t: { issue: 2024.6, pr: 2024.9, merge: 2025.4 } },
    { id: '#301', pos: 'world｜消息流转', title: '消息不丢、出错有兜底',   stage: 'merged', scene: '稳定', when: '2025 Q1', waitlist: 150, unlockAt: 120, prRef: '#301', t: { issue: 2024.1, pr: 2024.5, merge: 2025.0 } },
  ];

  // ── public API（async 仿网络，且证明视图走"接口"而非直读常量）──────────────
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  global.EZ = {
    async contributors() { await wait(120); return CONTRIBUTORS.slice(); },
    async kanbanDev()    { await wait(160); return JSON.parse(JSON.stringify(KANBAN_DEV)); },
    async kanbanValueChain() { await wait(160); return JSON.parse(JSON.stringify(KANBAN_VALUECHAIN)); },
    async worldcup()     { await wait(160); return JSON.parse(JSON.stringify(ROADMAP)); },
    async introspect()   { await wait(100); return JSON.parse(JSON.stringify(INTROSPECT)); },
    chatScript()         { return JSON.parse(JSON.stringify(CHAT_SCRIPT)); },
    // chat-feed wire shape：把一条 reply 编成 feed_encoding 的 {id,text,sender,render}
    async chatFeed(i)    { await wait(420); const s = CHAT_SCRIPT[i]; return s ? [s.reply] : []; },
  };
})(window);
