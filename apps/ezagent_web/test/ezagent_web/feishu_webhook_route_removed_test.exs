defmodule EzagentWeb.FeishuWebhookRouteRemovedTest do
  @moduledoc """
  Regression for #204 -- the public HTTP Feishu webhook route
  (`forward "/api/feishu/webhook", EzagentPluginFeishu.WebhookPlug`) was
  removed from the router. It was an unauthenticated public endpoint (no
  Encrypt-Key / signature verification): a forged POST carrying a victim's
  `open_id` could reach `EzagentPluginFeishu.InboundDispatcher` then
  `SenderResolver` then impersonation.

  Neither GET nor POST reaches `WebhookPlug` (which would answer 200):

    * POST matches no route (there is no POST catch-all), so the router
      raises `Phoenix.Router.NoRouteError` (`plug_status: 404`). This is the
      #204 attack vector (a forged event POST) -- the load-bearing assertion.
    * GET falls through to the browser catch-all
      (`get "/*path", FallbackController, :not_found`) and returns a normal
      404 response, not the webhook's 200.

  Re-adding the forward without the #204 signature verification turns these
  assertions red.

  The WS inbound path (`EzagentPluginFeishu.WsClient`) is unaffected: it
  calls the shared entry point `EzagentPluginFeishu.InboundDispatcher`
  directly, never through this HTTP route. Its coverage lives in
  `apps/ezagent_plugin_feishu/test/inbound_dispatcher_test.exs` and
  `apps/ezagent_plugin_feishu/test/webhook_plug_test.exs`.
  """
  use EzagentWeb.ConnCase, async: true

  @path "/api/feishu/webhook"

  test "POST to removed webhook route raises 404 (the #204 attack vector)", %{conn: conn} do
    assert_error_sent 404, fn ->
      post(conn, @path, %{"type" => "url_verification", "challenge" => "x"})
    end
  end

  test "GET to removed webhook route returns 404, not the webhook 200", %{conn: conn} do
    conn = conn |> put_req_header("accept", "text/html") |> get(@path)
    assert conn.status == 404
  end
end
