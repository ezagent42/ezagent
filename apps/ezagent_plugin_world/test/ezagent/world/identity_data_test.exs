defmodule Ezagent.World.IdentityDataTest do
  use ExUnit.Case, async: true

  test "agent_new_form state advertises which flavors require project_cwd" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.IdentityData.state_for(
        %{component: "agent_new_form", title: "New agent", path: "/identities/agents/new"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert "cc" in state["cwd_required_flavors"]
    assert "codex" in state["cwd_required_flavors"]
    assert "echo" in state["cwd_required_with_pty_flavors"]
    refute "curl" in state["cwd_required_flavors"]
  end
end
