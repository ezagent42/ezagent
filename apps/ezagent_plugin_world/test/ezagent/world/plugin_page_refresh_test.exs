defmodule Ezagent.World.PluginPageRefreshTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.PluginPageRefresh

  @entity_uri Ezagent.URI.new!("entity://refresh-test/agent/board")

  test "calls the declared plugin-owned partial-state callback" do
    page = %{data_builder: Ezagent.World.PluginPageRefreshBuilder}

    assert {:ok, %{"entity_uri" => entity_uri, "marker" => "updated"}} =
             PluginPageRefresh.build_state(page, @entity_uri, %{marker: "updated"})

    assert entity_uri == URI.to_string(@entity_uri)
  end

  test "uses a SliceChange event's entity as the generic refresh source" do
    page = %{data_builder: Ezagent.World.PluginPageRefreshBuilder}

    assert {:ok, %{"entity_uri" => entity_uri, "marker" => "slice-change"}} =
             PluginPageRefresh.build_state_for_slice_change(
               page,
               %{uri: @entity_uri, slice_key: :kanban},
               %{marker: "slice-change"}
             )

    assert entity_uri == URI.to_string(@entity_uri)
  end

  test "fails closed for a malformed SliceChange event" do
    page = %{data_builder: Ezagent.World.PluginPageRefreshBuilder}

    assert {:error, :invalid_slice_change} =
             PluginPageRefresh.build_state_for_slice_change(page, %{slice_key: :kanban}, %{})
  end

  test "fails closed for a registered page without refresh_state/2" do
    assert {:error, :missing_refresh_state} =
             PluginPageRefresh.build_state(%{data_builder: String}, @entity_uri, %{})
  end

  test "does not treat an unknown plugin page as a refreshable surface" do
    assert :not_registered = PluginPageRefresh.build_state(nil, @entity_uri, %{})
  end
end
