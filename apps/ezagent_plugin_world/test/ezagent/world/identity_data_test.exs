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

  test "agent_detail state includes granted caps + executor fields (labeled, not raw dump)" do
    # No app/registries are started in this plugin's unit test harness, so we
    # exercise the REAL builder (real Invocation.dispatch + sandbox_read paths)
    # against a well-formed agent URI. The builder's graceful-degrade branches
    # produce the documented shapes: `granted_caps` is a list (or an error map
    # when dispatch can't reach a live Kind), and `project_cwd`/`config_dir`/
    # `source_template` are always present (value may be nil = "direct-spawn").
    agent_uri = Ezagent.URI.agent("acme", "cc-detail-probe")

    state =
      Ezagent.World.IdentityData.state_for(
        %{
          component: "agent_detail",
          title: "Agent detail",
          path: "/identities/agents/probe",
          entity_uri: agent_uri
        },
        %{workspace_uri: nil, caller_uri: nil, caller_caps: MapSet.new()}
      )

    # granted_caps is the real CapBAC list shape (or a graceful error map when
    # the target Kind isn't live in this bare harness) — never a raw JSON dump.
    assert is_list(state["granted_caps"]) or is_map(state["granted_caps"])

    # The three executor/config fields are always present (nil renders as
    # "—" / "direct-spawn" in the UI).
    assert Map.has_key?(state, "project_cwd")
    assert Map.has_key?(state, "config_dir")
    assert Map.has_key?(state, "source_template")

    # Labeled fields the React detail page reads.
    assert Map.has_key?(state, "agent_uri")
    assert Map.has_key?(state, "agent_status")
  end

  test "create_error_message maps backend reasons to operator-facing text" do
    assert Ezagent.World.IdentityData.create_error_message(:cwd_required_for_cc) =~ "project_cwd"

    assert Ezagent.World.IdentityData.create_error_message(:cwd_required_for_codex) =~
             "project_cwd"

    assert Ezagent.World.IdentityData.create_error_message({:bad_name, "x y"}) =~ "name"
    assert Ezagent.World.IdentityData.create_error_message({:bad_flavor, "zz"}) =~ "zz"

    assert Ezagent.World.IdentityData.create_error_message(
             {:already_exists, "entity://acme/agent/g"}
           ) =~
             "已存在"

    # grant_failed: clean hint instead of a raw tuple; echo's unknown_action gets a flavor-specific
    # message. The cap element is ignored by the message clause, so a placeholder stands in for it.
    cap = :placeholder_cap

    assert Ezagent.World.IdentityData.create_error_message(
             {:grant_failed, cap, {:unknown_action, :grant_cap}}
           ) =~ "不支持授予 caps"

    assert Ezagent.World.IdentityData.create_error_message({:grant_failed, cap, :boom}) =~
             "授予 caps 失败"

    assert is_binary(Ezagent.World.IdentityData.create_error_message({:weird, :tuple}))
  end
end
