defmodule Ezagent.World.AdminDataTest do
  # async: false — these read global KindRegistry / ETS state.
  use ExUnit.Case, async: false

  test "overview state includes kpis, available_sessions, and session_template_names" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert is_map(state["kpis"])
    assert is_integer(state["kpis"]["sessions"])
    assert is_integer(state["kpis"]["agents"])
    assert is_list(state["available_sessions"])

    Enum.each(state["available_sessions"], fn row ->
      assert is_binary(row["uri"])
      assert is_binary(row["name"])
    end)

    assert is_list(state["session_template_names"])
    assert "default" in state["session_template_names"]
  end

  test "overview state is JSON-safe (no URI structs leak through)" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    {:ok, _encoded} = Jason.encode(state)
  end

  test "overview state with nil workspace_uri does not crash (guard rail)" do
    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: nil, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert is_map(state["kpis"])
    assert state["available_sessions"] == []
    assert is_list(state["session_template_names"])
  end

  test "overview state with non-workspace URI does not crash (guard rail)" do
    entity_uri = Ezagent.URI.agent("acme", "some-agent")

    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: entity_uri, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert is_map(state["kpis"])
    assert state["available_sessions"] == []
  end

  test "settings state does not expose registration controls to a non-admin caller" do
    state = Ezagent.World.AdminData.settings_state(nil)

    assert state["can_manage_registration"] == false
    refute Map.has_key?(state, "registration_open")
    refute Map.has_key?(state, "registration_require_invite")
    refute Map.has_key?(state, "registration_requests")
    assert is_map(state["smtp"])
  end
end
