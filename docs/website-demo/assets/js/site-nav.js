/* ============================================================================
 * site-nav.js · 子页面共享 nav（与 mainsite.html 视觉一致，单一来源）
 * ----------------------------------------------------------------------------
 * 用法：页面 <body> 末尾 <script src="demo-state.js"></script><script src="site-nav.js"></script>
 *   可在 <body data-ez-nav="worldcup"> 高亮对应 tab（intro|worldcup|contributors）。
 * tab = 跳 mainsite.html#section；登录态由 EZD.hasIdentity() 决定 登录 / 我的主页。
 * ========================================================================== */
(function () {
  'use strict';
  var ROOT = (window.EZD_SITE_ROOT !== undefined) ? window.EZD_SITE_ROOT : './';
  if (document.querySelector('nav.nav')) return; // 已有（如 index 自带）则不注入
  if (!document.getElementById('ez-nav-style')) {
    const css = `
    nav.nav{position:sticky;top:16px;z-index:50;margin:16px auto 0;max-width:1280px;display:flex;align-items:center;gap:18px;padding:10px 14px 10px 20px;border-radius:var(--r-pill);background:var(--glass-bg);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur);box-shadow:var(--shadow-sm),var(--glass-edge)}
    nav.nav .brand{display:flex;align-items:center;gap:10px;font-family:var(--font-ui);font-weight:800;letter-spacing:-.01em;font-size:17px;text-decoration:none;color:var(--ink)}
    nav.nav .brand img{height:26px;width:auto;display:block}
    nav.nav .tabs{display:flex;gap:4px;margin-left:6px}
    nav.nav .tab{border:0;background:transparent;cursor:pointer;font-family:inherit;font-size:14px;font-weight:500;color:var(--ink-2);padding:8px 14px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out);display:flex;gap:7px;align-items:center;text-decoration:none}
    nav.nav .tab .en{font-size:11px;color:var(--ink-4);font-family:var(--font-mono)}
    nav.nav .tab:hover{background:var(--ground-hover);color:var(--ink)}
    nav.nav .tab.active{background:var(--accent);color:var(--on-accent)}
    nav.nav .tab.active .en{color:rgba(255,255,255,.72)}
    nav.nav .navball{width:16px;height:16px;display:inline-block;transform-origin:center 85%;animation:ballbounce 1.5s cubic-bezier(.3,.6,.3,1) infinite}
    nav.nav .tab:hover .navball{animation-duration:.7s}
    @keyframes ballbounce{0%{transform:translateY(0) rotate(0)}20%{transform:translateY(-5px) rotate(-16deg)}40%{transform:translateY(0) rotate(0)}55%{transform:translateY(-2px) rotate(11deg)}70%,100%{transform:translateY(0) rotate(0)}}
    nav.nav .spacer{flex:1}
    nav.nav .ghbtn{font-family:var(--font-mono);font-size:12px;color:var(--ink-2);padding:9px 16px;border-radius:var(--r-pill);background:var(--ground-2);transition:all 150ms var(--ease-out);text-decoration:none}
    nav.nav .ghbtn:hover{background:var(--ink);color:var(--card)}
    nav.nav .loginbtn{font-family:var(--font-mono);font-size:12px;font-weight:700;color:var(--accent-press);background:var(--accent-wash);padding:9px 16px;border-radius:var(--r-pill);transition:all 150ms var(--ease-out);text-decoration:none}
    nav.nav .loginbtn:hover{background:var(--accent);color:var(--on-accent)}
    nav.nav .iconbtn{appearance:none;border:0;cursor:pointer;width:38px;height:38px;border-radius:var(--r-pill);background:var(--ground-2);color:var(--ink-2);display:grid;place-items:center;transition:all 150ms var(--ease-out)}
    nav.nav .iconbtn:hover{background:var(--ground-hover);color:var(--ink)}
    @media (max-width:860px){nav.nav{padding:8px 10px 8px 14px;gap:8px}nav.nav .tab .en{display:none}nav.nav .brand span.wm{display:none}}
    @media (prefers-reduced-motion:reduce){nav.nav .navball{animation:none}}
    `;
    const s = document.createElement('style'); s.id = 'ez-nav-style'; s.textContent = css; document.head.appendChild(s);
  }
  const active = document.body.getAttribute('data-ez-nav') || '';
  const a = (k) => (active === k ? ' active' : '');
  const ball = '<svg class="navball" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#fff" stroke="#17171B" stroke-width="1.6"/><path d="M12 7.2l3 2.2-1.15 3.5h-3.7L9 9.4z" fill="#17171B"/><path d="M12 7.2V4.2M15 9.4l2.7-1M13.85 12.9l1.7 2.4M10.15 12.9l-1.7 2.4M9 9.4l-2.7-1" stroke="#17171B" stroke-width="1.3" fill="none" stroke-linecap="round"/></svg>';
  const me = (window.EZD && EZD.hasIdentity());
  const login = me
    ? '<a class="loginbtn" href="' + ROOT + 'achievement-center.html">我的主页 · Me</a>'
    : '<a class="loginbtn" href="' + ROOT + 'login.html">登录 · Login</a>';
  const nav = document.createElement('nav'); nav.className = 'nav';
  nav.innerHTML =
    '<a class="brand" href="' + ROOT + 'mainsite.html"><img src="' + ROOT + 'assets/images/ezagent-logo.png" alt="Ezagent"><span class="wm">EZAGENT</span></a>' +
    '<div class="tabs">' +
      '<a class="tab' + a('intro') + '" href="' + ROOT + 'mainsite.html#intro">介绍<span class="en">Intro</span></a>' +
      '<a class="tab' + a('worldcup') + '" href="' + ROOT + 'mainsite.html#worldcup">' + ball + 'world.cup<span class="en">Progress</span></a>' +
      '<a class="tab' + a('contributors') + '" href="' + ROOT + 'mainsite.html#contributors">团队<span class="en">Team</span></a>' +
    '</div>' +
    '<span class="spacer"></span>' +
    '<a class="ghbtn" href="https://github.com/ezagent42" target="_blank" rel="noopener">↗ GitHub</a>' +
    login +
    '<button class="iconbtn" id="ez-theme" title="切换主题 · Theme" aria-label="切换主题"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>';
  document.body.insertBefore(nav, document.body.firstChild);
  document.getElementById('ez-theme').onclick = () => { const r = document.documentElement; r.dataset.theme = r.dataset.theme === 'dark' ? 'light' : 'dark'; };
})();
