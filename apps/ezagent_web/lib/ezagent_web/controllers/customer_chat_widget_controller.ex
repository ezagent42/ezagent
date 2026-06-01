defmodule EzagentWeb.CustomerChatWidgetController do
  @moduledoc """
  Serves the embeddable customer-chat widget loader as javascript.
  A business embeds:

      <script src="https://<host>/customer-chat/widget.js" data-tenant="acme"></script>

  The loader injects a floating launcher button; clicking it toggles an
  iframe pointing at `/chat/<tenant>?embed=1` (same LiveView as the
  hosted page). Style isolation comes from the iframe boundary.
  """
  use Phoenix.Controller, formats: [:json]

  @widget_js """
  (function () {
    var s = document.currentScript;
    var tenant = s.getAttribute('data-tenant');
    if (!tenant) { console.error('[ezagent-chat] missing data-tenant'); return; }
    var base = s.getAttribute('data-base-url') || (new URL(s.src)).origin;
    var primary = s.getAttribute('data-primary') || '#2563eb';

    var btn = document.createElement('button');
    btn.setAttribute('aria-label', 'Chat');
    btn.style.cssText = 'position:fixed;right:20px;bottom:20px;width:56px;height:56px;border:none;border-radius:50%;cursor:pointer;z-index:2147483646;box-shadow:0 4px 12px rgba(0,0,0,.2);background:' + primary + ';color:#fff;font-size:24px;';
    btn.textContent = '💬';

    var frame = document.createElement('iframe');
    frame.src = base + '/chat/' + encodeURIComponent(tenant) + '?embed=1';
    frame.style.cssText = 'position:fixed;right:20px;bottom:88px;width:380px;height:560px;max-width:calc(100vw - 40px);max-height:calc(100vh - 120px);border:none;border-radius:12px;box-shadow:0 8px 30px rgba(0,0,0,.25);z-index:2147483647;display:none;background:#fff;';

    var open = false;
    btn.addEventListener('click', function () {
      open = !open;
      frame.style.display = open ? 'block' : 'none';
    });

    document.body.appendChild(frame);
    document.body.appendChild(btn);
  })();
  """

  def widget(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, @widget_js)
  end
end
