defmodule EzagentPluginLoom.WebPlugTest do
  @moduledoc """
  Plug tests for the loom frontend entry (`EzagentPluginLoom.WebPlug`).

  These exercise routing + serving deterministically (no network). The
  real DeepSeek round-trip (sanitize → system-prompt prepend → jsx) is
  verified by the live e2e (see docs/loom integration spec §11), not here.

  Note: `forward "/loom"` strips the `/loom` prefix, so the plug sees
  paths like `/system/s_x`, `/api/chat`, `/favicon.ico` (no `/loom`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts EzagentPluginLoom.WebPlug.init([])

  defp call(conn), do: EzagentPluginLoom.WebPlug.call(conn, @opts)

  describe "page serving (SPA fallback)" do
    test "GET /:ws/:sid returns the static index.html with /loom asset refs" do
      conn = call(conn(:get, "/system/s_test"))

      assert conn.status == 200
      assert conn.resp_body =~ "<!DOCTYPE html>"
      # basePath:'/loom' → assets are absolute under /loom, so deep page
      # paths still resolve them.
      assert conn.resp_body =~ "/loom/_next/"

      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
    end

    test "any GET path falls back to index (client routes by URL, not the server)" do
      conn = call(conn(:get, "/anything/deep/here"))
      assert conn.status == 200
      assert conn.resp_body =~ "<!DOCTYPE html>"
    end

    # 新标签预览：/loom/preview/<ws>/<sid>（plug 看到的是去掉 /loom 前缀的
    # /preview/<ws>/<sid>）走 SPA 兜底 → 同一份 index.html，客户端读 URL 渲染
    # 纯预览。纯前端路由，后端无专门 handler，仅靠这条兜底。
    test "GET /preview/:ws/:sid falls back to index (preview link is client-routed)" do
      conn = call(conn(:get, "/preview/system/s_demo4"))
      assert conn.status == 200
      assert conn.resp_body =~ "<!DOCTYPE html>"
      assert conn.resp_body =~ "/loom/_next/"
    end
  end

  describe "static assets" do
    test "GET /favicon.ico is served from the plugin priv" do
      conn = call(conn(:get, "/favicon.ico"))
      assert conn.status == 200
    end
  end

  # `POST /api/chat` was removed in the 2026-06-01 redesign (page generation
  # moved to LoomV0Worker dispatched by the session orchestrator).

  describe "POST /api/:ws/:sid/stop (中断当前生成)" do
    # 无在跑 claude / 未注册编排器时仍确定性返回 200 {ok:true}:
    # `ClaudeCode.stop/1` 对空 ETS 匹配 → :ok;orchestrator lookup :error → :ok。
    # 真正的"杀 claude + 清在飞回合"由 ClaudeCodeTest / LoomOrchestratorTest 单测,
    # 端到端中断由 live e2e 覆盖。
    test "返回 200 且 body 为 {ok:true}（幂等,无活动 session 也不崩）" do
      conn = call(conn(:post, "/api/system/s_test/stop"))
      assert conn.status == 200
      assert %{"ok" => true} = Jason.decode!(conn.resp_body)
    end

    test "GET 同路径不命中 stop（仅 POST）" do
      conn = call(conn(:get, "/api/system/s_test/stop"))
      # SPA fallback 接住 GET → 返回 index.html，而非 stop 的 JSON。
      assert conn.resp_body =~ "<!DOCTYPE html>"
    end
  end

  describe "unknown method" do
    test "DELETE on any path → 404" do
      conn = call(conn(:delete, "/whatever"))
      assert conn.status == 404
    end
  end
end
