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

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  defp admin_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
    })
  end

  describe "LV mount tracks Presence on the connected socket" do
    test "admin LV mount → Ezagent.Presence.present?(admin_uri) is true" do
      admin_uri = Ezagent.Entity.User.admin_uri()

      # Sanity: before mount, the admin URI is not tracked.
      refute Ezagent.Presence.present?(admin_uri)

      {:ok, _lv, _html} = live(admin_conn(), "/admin/settings")

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
