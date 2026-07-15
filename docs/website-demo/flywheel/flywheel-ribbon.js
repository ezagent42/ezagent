/* ============================================================================
 * flywheel-ribbon.js · 飞轮 demo 的顶部 nav（官网 / 探索；路径按 flywheel/ 子目录修正）
 * 后端待建功能不在这里标注 —— 各页用「后端需要加的功能」朴素说明框直接列出（与
 * world 占位页同款），一处一致。
 * ========================================================================== */
(function () {
  'use strict';
  var body = document.body;

  var css = ''
  + 'nav.fwnav{position:sticky;top:16px;z-index:50;margin:16px auto 0;max-width:1180px;display:flex;align-items:center;gap:16px;padding:10px 14px 10px 20px;border-radius:var(--r-pill);background:var(--glass-bg);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur);box-shadow:var(--shadow-sm),var(--glass-edge)}'
  + 'nav.fwnav .brand{display:flex;align-items:center;gap:10px;font-family:var(--font-ui);font-weight:800;letter-spacing:-.01em;font-size:17px;text-decoration:none;color:var(--ink)}'
  + 'nav.fwnav .brand img{height:26px;width:auto;display:block}'
  + 'nav.fwnav .tabs{display:flex;gap:4px;margin-left:6px}'
  + 'nav.fwnav .tab{border:0;background:transparent;cursor:pointer;font-family:inherit;font-size:14px;font-weight:500;color:var(--ink-2);padding:8px 14px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out);text-decoration:none}'
  + 'nav.fwnav .tab:hover{background:var(--ground-hover);color:var(--ink)}'
  + 'nav.fwnav .tab.active{background:var(--accent);color:var(--on-accent)}'
  + 'nav.fwnav .spacer{flex:1}'
  + 'nav.fwnav .ghbtn{font-family:var(--font-mono);font-size:12px;color:var(--ink-2);padding:9px 16px;border-radius:var(--r-pill);background:var(--ground-2);text-decoration:none;transition:all 150ms var(--ease-out)}'
  + 'nav.fwnav .ghbtn:hover{background:var(--ink);color:var(--card)}';
  var s = document.createElement('style'); s.textContent = css; document.head.appendChild(s);

  var active = body.getAttribute('data-fw-nav') || 'explore';
  var nav = document.createElement('nav'); nav.className = 'fwnav';
  nav.innerHTML =
    '<a class="brand" href="../mainsite.html"><img src="https://cdn.jsdelivr.net/gh/ezagent42/design-system@main/assets/ezagent-logo.png" alt="Ezagent"><span>EZAGENT</span></a>'
    + '<div class="tabs">'
    + '<a class="tab' + (active === 'home' ? ' active' : '') + '" href="../mainsite.html#intro">官网 · Home</a>'
    + '<a class="tab' + (active === 'explore' ? ' active' : '') + '" href="gallery.html">探索 · Explore</a>'
    + '</div>'
    + '<span class="spacer"></span>'
    + '<a class="ghbtn" href="../mainsite.html">← 返回官网 · Home</a>';
  body.insertBefore(nav, body.firstChild);
})();
