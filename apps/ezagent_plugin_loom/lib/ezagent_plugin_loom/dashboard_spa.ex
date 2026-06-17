defmodule EzagentPluginLoom.DashboardSPA do
  @moduledoc """
  Loom operator Dashboard 前端壳(项 2 的 operator UI 部分)。最小 vanilla-JS,轮询
  `GET /loom/c/:ws/:sid/dashboard` 渲 KPI(token/calls/素材/知识)。

  ⚠️ 代码壳就绪、服务端可测;浏览器内验证待 agent-browser。operator 鉴权当前用 session token,
  真正 operator-only auth 待 operator web 上下文集成(标注于端点)。
  """

  @spec html() :: String.t()
  def html do
    """
    <!doctype html>
    <html lang="zh"><head><meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <title>Loom Dashboard</title>
    <style>
      body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#f9fafb}
      h1{font-size:18px}
      .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
      .kpi{background:#fff;border:1px solid #eee;border-radius:12px;padding:16px}
      .kpi .v{font-size:28px;font-weight:700}
      .kpi .l{font-size:12px;color:#6b7280;margin-top:4px}
    </style></head>
    <body>
      <h1>Loom 运营看板</h1>
      <div class="grid" id="grid"><p>加载中…</p></div>
    <script>
    const q = new URLSearchParams(location.search);
    // ws/sid 在 path(/loom/dashboard/:ws/:sid),token 在 query;query 兜底兼容。
    const pm = location.pathname.match(/\\/loom\\/dashboard\\/([^\\/]+)\\/([^\\/]+)/);
    const ws=(pm&&pm[1])||q.get('ws'), sid=(pm&&pm[2])||q.get('sid'), token=q.get('token');
    function card(v,l){ return `<div class="kpi"><div class="v">${v}</div><div class="l">${l}</div></div>`; }
    async function load(){
      try{
        const r = await fetch(`/loom/c/${ws}/${sid}/dashboard?token=${encodeURIComponent(token)}`);
        const j = await r.json();
        if(j.ok){ const s=j.summary;
          document.getElementById('grid').innerHTML =
            card(s.tokens.total,'总 token') + card(s.tokens.input,'input') +
            card(s.tokens.output,'output') + card(s.calls,'LLM 调用') +
            card(s.materials,'素材') + card(s.knowledge_bytes,'知识库字节');
        }
      }catch(e){}
      setTimeout(load, 3000);
    }
    load();
    </script>
    </body></html>
    """
  end
end
