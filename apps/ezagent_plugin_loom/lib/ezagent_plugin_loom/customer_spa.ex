defmodule EzagentPluginLoom.CustomerSPA do
  @moduledoc """
  Loom customer 前端壳(项 2):最小 vanilla-JS 单页,调本 plugin 的 HTTP 端点
  (sendMessage / feed 轮询 / stitch)。含简易 json-render(把 page UI-tree 渲成 DOM)。

  ⚠️ 代码壳已就绪、服务端可测(GET 返回 HTML);**浏览器内交互验证待 agent-browser**
  (见 docs/loom/2026-06-17-loom-vertical-pending-integration.md 项 2)。生产可换 socialware
  customer_app.js + json_render.mjs(#732);此壳是 loom 自包含的可用最小版。
  """

  @doc "返回 customer SPA 的 HTML(从 URL query 读 ws/sid/token)。"
  @spec html() :: String.t()
  def html do
    """
    <!doctype html>
    <html lang="zh">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>Loom</title>
      <style>
        body{font-family:system-ui,sans-serif;margin:0;display:flex;height:100vh}
        #page{flex:1;overflow:auto;padding:16px;border-right:1px solid #eee}
        #chat{width:360px;display:flex;flex-direction:column}
        #msgs{flex:1;overflow:auto;padding:12px}
        .m{margin:6px 0;padding:8px 10px;border-radius:10px;max-width:85%}
        .user{background:#4f46e5;color:#fff;margin-left:auto}
        .agent{background:#f3f4f6}
        #bar{display:flex;border-top:1px solid #eee}
        #t{flex:1;border:0;padding:12px;font-size:14px}
        #send{border:0;background:#4f46e5;color:#fff;padding:0 16px}
        .node{margin:6px 0;padding:8px;border:1px solid #eee;border-radius:8px}
        .node>.type{font-size:11px;color:#999}
      </style>
    </head>
    <body>
      <div id="page"><p>正在加载页面…</p></div>
      <div id="chat">
        <div id="msgs"></div>
        <div id="bar"><input id="t" placeholder="说点什么…"/><button id="send">发送</button></div>
      </div>
    <script>
    const q = new URLSearchParams(location.search);
    // ws/sid 在 path(/loom/app/:ws/:sid),token 在 query;query 兜底兼容。
    const pm = location.pathname.match(/\\/loom\\/app\\/([^\\/]+)\\/([^\\/]+)/);
    const ws = (pm && pm[1]) || q.get('ws');
    const sid = (pm && pm[2]) || q.get('sid');
    const token = q.get('token');
    const base = `/loom/c/${ws}/${sid}`;
    const seen = new Set();

    function renderNode(n){
      if(!n || !n.type) return '';
      const props = n.props||{}; const title = props.title||props.text||'';
      const kids = (n.children||[]).map(renderNode).join('');
      return `<div class="node"><div class="type">${n.type}</div>${title?`<div>${title}</div>`:''}${kids}</div>`;
    }
    function renderPage(tree){
      document.getElementById('page').innerHTML = tree ? renderNode(tree) : '<p>（operator 批准后显示）</p>';
    }
    function addMsg(m){
      if(!m || seen.has(m.id)) return; seen.add(m.id);
      const d = document.createElement('div');
      d.className = 'm ' + (m.sender && m.sender.includes('/user/') ? 'user' : 'agent');
      d.textContent = m.text || ''; document.getElementById('msgs').appendChild(d);
    }
    async function poll(){
      try{
        const r = await fetch(`${base}/feed?token=${encodeURIComponent(token)}`);
        const j = await r.json();
        if(j.ok){ (j.messages||[]).forEach(addMsg); renderPage(j.page); }
      }catch(e){}
      setTimeout(poll, 2000);
    }
    async function send(){
      const t = document.getElementById('t'); const text = t.value.trim(); if(!text) return;
      t.value=''; addMsg({id:'local-'+Date.now(), text, sender:'/user/me'});
      await fetch(`${base}/messages`, {method:'POST', headers:{'content-type':'application/json'},
        body: JSON.stringify({text, token})});
    }
    document.getElementById('send').onclick = send;
    document.getElementById('t').addEventListener('keydown', e=>{ if(e.key==='Enter') send(); });
    poll();
    </script>
    </body>
    </html>
    """
  end
end
