defmodule EzagentPluginLoom.Integration.CustomerSpaTest do
  @moduledoc "customer 前端壳:服务端返回 SPA HTML(浏览器内交互验证待 agent-browser)。"
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginLoom.WebPlug

  @opts WebPlug.init([])

  test "GET /app/:ws/:sid serves the customer SPA shell" do
    conn = conn(:get, "/app/ws1/sid1?token=t") |> WebPlug.call(@opts)

    assert conn.status == 200
    assert {"content-type", "text/html" <> _} = List.keyfind(conn.resp_headers, "content-type", 0)
    body = conn.resp_body
    # 壳关键元素 + 调本 plugin 端点
    assert body =~ "<title>Loom</title>"
    assert body =~ "/loom/c/"
    assert body =~ "/feed?token="
    assert body =~ "/messages"
    assert body =~ "renderNode"
  end

  test "SPA html is self-contained (no external script src)" do
    html = EzagentPluginLoom.CustomerSPA.html()
    refute html =~ ~r/<script\s+src=/
  end

  test "SPA extracts ws/sid from path, not query (regression: /c/null/null/*)" do
    # 回归:URL 把 ws/sid 放在 path(/loom/app/:ws/:sid),早期版本从 query 读 → null/null → 401。
    html = EzagentPluginLoom.CustomerSPA.html()
    assert html =~ "location.pathname.match"
    assert html =~ "/loom/app/"
  end
end
