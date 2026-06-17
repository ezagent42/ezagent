defmodule EzagentPluginLoom.Integration.FrontendServingTest do
  @moduledoc "Phase 1:真实 loom 前端(loom_ui)服务 + boot/chat 端点(history/whoami)。"
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginLoom.WebPlug

  @opts WebPlug.init([])

  test "SPA 兜底:GET /<ws>/<sid> 返回真实前端 index.html" do
    conn = conn(:get, "/demo/main") |> WebPlug.call(@opts)
    assert conn.status == 200
    assert {"content-type", "text/html" <> _} = List.keyfind(conn.resp_headers, "content-type", 0)
    # 真实 Next 导出:index.html 引用 hash 命名的 _next chunk。
    assert conn.resp_body =~ "_next"
  end

  test "静态资源经 Plug.Static(favicon 存在)" do
    conn = conn(:get, "/favicon.ico") |> WebPlug.call(@opts)
    assert conn.status == 200
  end

  test "history 返回裸 list(空 session → [])" do
    conn =
      conn(:get, "/api/demo/nosuch-#{System.unique_integer([:positive])}/history")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body))
  end

  test "whoami ok" do
    conn = conn(:get, "/whoami") |> WebPlug.call(@opts)
    assert %{"ok" => true} = Jason.decode!(conn.resp_body)
  end
end
