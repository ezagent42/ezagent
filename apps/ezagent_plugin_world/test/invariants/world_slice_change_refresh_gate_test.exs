defmodule Ezagent.World.SliceChangeRefreshGateTest do
  use ExUnit.Case, async: true

  @world_live Path.expand("../../lib/ezagent_plugin_world/world_live.ex", __DIR__)

  @session_state Path.expand("../../lib/ezagent/world/conversation_session_state.ex", __DIR__)
  test "World refreshes through SliceChange rather than plugin-specific signals" do
    source = File.read!(@world_live)

    assert String.contains?(source, "{:slice_changed, %{uri: %URI{} = entity_uri} = event}")
    assert String.contains?(source, "Ezagent.Notifications.subscribe_slice_change")
    assert String.contains?(source, "RefreshSurfaceRegistry")
    assert String.contains?(source, "schedule_active_surface_refresh")

    refute String.contains?(source, ":view_changed")
    refute String.contains?(source, ":caps_changed")
    refute String.contains?(source, ":kanban_changed")
  end

  test "SliceChange identity updates are the sole caps refresh trigger" do
    source = File.read!(@world_live)

    assert String.contains?(source, "refresh_caps_after_identity_change")
    assert String.contains?(source, "%{slice_key: :identity}")
  end

  test "active sessions subscribe to SliceChange and refresh through the common route path" do
    world_live = File.read!(@world_live)
    session_state = File.read!(@session_state)

    assert String.contains?(
             session_state,
             "Ezagent.Notifications.subscribe_slice_change(session_uri)"
           )

    assert String.contains?(world_live, "world:surface_state")
    assert String.contains?(world_live, "Process.send_after")
    refute String.contains?(world_live, "refresh_current_session_after_slice_change")
    refute String.contains?(world_live, "PluginPageRefresh")
    refute String.contains?(world_live, "Hello")
  end
end
