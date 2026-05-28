defmodule EzagentWeb.CustomerChatWidgetControllerTest do
  use EzagentWeb.ConnCase, async: true

  test "GET /customer-chat/widget.js serves javascript", %{conn: conn} do
    conn = get(conn, "/customer-chat/widget.js")
    assert response_content_type(conn, :js) =~ "javascript"
    body = response(conn, 200)
    assert body =~ "data-tenant"
    assert body =~ "/chat/"
    assert body =~ "iframe"
  end
end
