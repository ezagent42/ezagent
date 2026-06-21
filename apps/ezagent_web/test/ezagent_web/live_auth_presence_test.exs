defmodule EzagentWeb.LiveAuthPresenceTest do
  @moduledoc """
  PR-B of the Presence rollout (SPEC `docs/superpowers/specs/2026-05-23-presence.md`
  rev 3 §7) — `EzagentWeb.LiveAuth.on_mount(:require_entity, ...)` now
  calls `Ezagent.Presence.track/3` on the WS-connected path. Auto-untrack
  fires when the LV socket process exits (Phoenix.Presence's monitor).

  These tests exercise the WS-connected path via `Phoenix.LiveViewTest.live/2`.
  The dead-render path (where `connected?(socket) == false`) is intentionally
  NOT tracked — covered implicitly by every existing LV test that does NOT
  assert on Presence side-effects.
  """

  use EzagentWeb.ConnCase
  import Phoenix.LiveViewTest

  defp admin_conn(conn) do
    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
      "current_workspace_uri" => "workspace://system"
    })
  end

  describe "LV mount tracks Presence on the connected socket" do
    test "world LV mount → Ezagent.Presence.present?(admin_uri) is true", %{conn: conn} do
      admin_uri = Ezagent.Entity.User.admin_uri()

      # Sanity: before mount, the admin URI is not tracked.
      refute Ezagent.Presence.present?(admin_uri)

      {:ok, _lv, _html} = live(admin_conn(conn), "/sessions")

      # After mount, Phoenix.Presence has the entry from THIS test's LV
      # socket. (The test process keeps the LV alive for the duration
      # of the test; cleanup happens when ExUnit teardown drops the pid.)
      assert Ezagent.Presence.present?(admin_uri)

      # The entry meta carries the documented :transport key.
      list = Ezagent.Presence.list(admin_uri)
      assert is_map(list)
      assert map_size(list) >= 1

      [metas] = Map.values(list) |> Enum.take(1)
      assert hd(metas).transport == :liveview
    end
  end
end
