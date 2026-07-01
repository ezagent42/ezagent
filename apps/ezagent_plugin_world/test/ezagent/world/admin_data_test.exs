defmodule Ezagent.World.AdminDataTest do
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
end
