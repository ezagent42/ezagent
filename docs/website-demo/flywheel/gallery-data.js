/* ============================================================================
 * gallery-data.js · 飞轮 demo 的假后端（货架数据）
 * ----------------------------------------------------------------------------
 * SEED_PRODUCTS 的对象形状对齐真实 Ezagent.Socialware.Definition 的 manifest
 * 字段（name / version / title / description / owner / visibility），外加几个
 * demo 展示用字段（category / glyph / color / tryUrl / hires / rating）。
 *
 * ⚠ 后端是真的：DefinitionRegistry.list/1 + lookup/2 已在 main（今天只有一个
 *   薄的 install 下拉 world_live.ex:704）。把下面的 FW.products() 换成对
 *   「面向 homesite 的目录 API（handoff W-G1）」的 fetch，就是一个函数的事 ——
 *   所以这份 mock 同时是 H 侧的前端 spec。
 *
 * 用户发布的产品（builder 造的 / seller fork 的）写在 localStorage
 *   ez_flywheel_v1.published，与 SEED 合并展示 —— 让飞轮闭合「演出来」。
 * ========================================================================== */
(function (g) {
  'use strict';
  var KEY = 'ez_flywheel_v1';

  // 货架初始存量（builder 们已发布的产品）。visibility 恒为 public_view（socialware 前提）。
  var SEED_PRODUCTS = [
    {
      name: 'expert-recruit', version: '2.3.0',
      title: '专家 agent 招募 · Expert agent recruiting',
      description: '抽一张职业卡，为 TA 写个 agent，看看你和行业专家差多少 —— 然后招一个真专家发布的 agent 进你的组。',
      owner: 'Ezagent 团队 · Ezagent', category: 'hire', glyph: '招', color: 'var(--blue)',
      tryUrl: '../recruit/index.html', visibility: 'public_view', hires: 1284, rating: '4.9', seed: true,
    },
    {
      name: 'dealscout-matching', version: '1.1.0',
      title: '投融资撮合树洞 · DealScout matching',
      description: '说出你在找什么钱 / 项目 / 联合创始人，AI 循着信号把对的那一方捞到面前，你挑对上的牵成一条线。',
      owner: 'DealScout 团队 · DealScout', category: 'match', glyph: '撮', color: 'var(--jade)',
      tryUrl: '../dealscout/', visibility: 'public_view', hires: 412, rating: '4.8', seed: true,
    },
    {
      name: 'cs-desk', version: '1.4.2',
      title: '客服自助台 · Customer support desk',
      description: '把重复工单接进 AI 自助面，按「能否自助」二分、按愤怒值排队，一线只留一个升级按钮。',
      owner: '马屿 · SaaS 客服负责人', category: 'custom', glyph: '客', color: 'var(--orange)',
      tryUrl: '../recruit/index.html', visibility: 'public_view', hires: 268, rating: '4.7', seed: true,
    },
    {
      name: 'contract-redline', version: '1.0.3',
      title: '合同红线审查官 · Contract redline',
      description: '按中 / 欧双辖区逐条标注最常被砍的条款，输出可直接改的红线批注，不空谈原则。',
      owner: '苏珩 · 企业法务 9 年', category: 'custom', glyph: '法', color: 'var(--blueink)',
      tryUrl: '../recruit/index.html', visibility: 'public_view', hires: 214, rating: '4.9', seed: true,
    },
  ];

  var load = function () { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) { return {}; } };
  var save = function (s) { localStorage.setItem(KEY, JSON.stringify(s)); };

  g.FW = {
    // 全部货架 = 初始存量 ∪ 用户发布的（builder 造 + seller fork）
    products: function () {
      var pub = (load().published) || [];
      return SEED_PRODUCTS.concat(pub);
    },
    get: function (name) {
      return this.products().filter(function (p) { return p.name === name; })[0] || null;
    },
    // 发布一个产品进货架（B5 / S5）。幂等：同 name 覆盖。
    publish: function (p) {
      var s = load(); s.published = (s.published || []).filter(function (x) { return x.name !== p.name; });
      p.published_at = 'just now'; s.published.push(p); save(s); return p;
    },
    isPublished: function (name) {
      return ((load().published) || []).some(function (p) { return p.name === name; });
    },
    reset: function () { localStorage.removeItem(KEY); },
    CATEGORIES: [
      { k: '', label: '全部 · All' },
      { k: 'hire', label: '招募 · Hire' },
      { k: 'match', label: '撮合 · Match' },
      { k: 'custom', label: '自定义 · Custom' },
    ],
  };
})(window);
