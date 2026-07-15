/* ============================================================================
 * demo-state.js · 驾照测试 ↔ 个人成就中心 的共享状态（localStorage mock）
 * ----------------------------------------------------------------------------
 * 单一 schema 源，避免两页漂移。结构：
 *   ez_demo_v1 = { license:{tier,agents,pct,serial,persona,line,date}, profile:{...}, ach:{id:true} }
 * ========================================================================== */
(function (g) {
  'use strict';
  const KEY = 'ez_demo_v1';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) { return {}; } };
  const save = (s) => localStorage.setItem(KEY, JSON.stringify(s));

  // 成就定义（接价值链 ③-C 成就簇）。how = 未解锁时"怎么拿"的引导 + 跳转
  const ACH = [
    { id: 'license',  name: '指挥官驾照',   en: 'Commander License', desc: '测出你的并发指挥段位',     how: '测一张驾照',       go: 'driver-license.html' },
    { id: 'profile',  name: '画像已建',     en: 'Profile Built',     desc: '填好你的角色档案',         how: '建立角色档案',     go: '@profile' },
    { id: 'try',      name: '试玩者',       en: 'Tried it',          desc: '试玩过 world / hello',     how: '去试玩产品',       go: 'world-demo.html' },
    { id: 'vote',     name: '先知 · 眼光准', en: 'Foreseer',          desc: '在 world.cup 投票 / 押注', how: '去 world.cup 投票', go: 'mainsite.html#worldcup' },
    { id: 'feedback', name: '共创者',       en: 'Co-builder',        desc: '提交过一条反馈',           how: '提交反馈',         go: '@feedback' },
    { id: 'share',    name: '布道者',       en: 'Evangelist',        desc: '分享过你的名牌',           how: '去看名牌、分享',   go: 'driver-license.html' },
    { id: 'elder',    name: '元老',         en: 'Elder',             desc: '早期参与者（回溯授予）',   how: '',                 go: '', auto: true },
  ];

  g.EZD = {
    ACH,
    all() { return load(); },
    license() { return load().license || null; },
    setLicense(l) { const s = load(); s.license = l; s.ach = s.ach || {}; s.ach.license = true; save(s); },
    profile() { return load().profile || null; },
    setProfile(p) { const s = load(); s.profile = p; s.ach = s.ach || {}; s.ach.profile = true; save(s); },
    // 登录态（login.html 写）。有账号 或 有驾照 都算"有个人中心可进"
    user() { return load().user || null; },
    login(email) { const s = load(); s.user = { email: email || '', at: 1 }; save(s); },
    logout() { const s = load(); delete s.user; save(s); },
    hasIdentity() { const s = load(); return !!(s.user || s.license); },
    has(id) { return !!(load().ach || {})[id]; },
    unlock(id) { const s = load(); s.ach = s.ach || {}; s.ach[id] = true; save(s); },
    unlockedCount() { const a = load().ach || {}; return ACH.filter((x) => a[x.id]).length; },
    reset() { localStorage.removeItem(KEY); },
    // 驾照编号 / 测过人数（mock 自增）
    taken() { return +(localStorage.getItem('ez_taken') || 4127); },
    bumpTaken() { const n = this.taken() + 1; localStorage.setItem('ez_taken', n); return n; },
    nextSerial() { const b = +(localStorage.getItem('ez_serial') || 136) + 1; localStorage.setItem('ez_serial', b); return b; },
  };
})(window);
