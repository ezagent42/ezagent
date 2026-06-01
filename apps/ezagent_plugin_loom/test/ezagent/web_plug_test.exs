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
  end

  describe "static assets" do
    test "GET /favicon.ico is served from the plugin priv" do
      conn = call(conn(:get, "/favicon.ico"))
      assert conn.status == 200
    end
  end

  # `POST /api/chat` was removed in the 2026-06-01 redesign (page generation
  # moved to LoomV0Worker dispatched by the session orchestrator).

  describe "unknown method" do
    test "DELETE on any path → 404" do
      conn = call(conn(:delete, "/whatever"))
      assert conn.status == 404
    end
  end
end
