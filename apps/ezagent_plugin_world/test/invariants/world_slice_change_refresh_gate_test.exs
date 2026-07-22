defmodule Ezagent.World.SliceChangeRefreshGateTest do
  use ExUnit.Case, async: true

  @world_live Path.expand("../../lib/ezagent_plugin_world/world_live.ex", __DIR__)

  test "World refreshes through SliceChange rather than plugin-specific signals" do
    source = File.read!(@world_live)

    assert String.contains?(source, "{:slice_changed, %{uri: %URI{} = entity_uri} = event}")
    assert String.contains?(source, "Ezagent.Notifications.subscribe_slice_change")
    assert String.contains?(source, "build_state_for_slice_change")

    refute String.contains?(source, ":view_changed")
    refute String.contains?(source, ":caps_changed")
    refute String.contains?(source, ":kanban_changed")
  end

  test "SliceChange identity updates are the sole caps refresh trigger" do
    source = File.read!(@world_live)

    assert String.contains?(source, "refresh_caps_after_identity_change")
    assert String.contains?(source, "%{slice_key: :identity}")
  end
end
