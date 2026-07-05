defmodule Ezagent.World.IdentityDataTest do
  use EzagentCore.DataCase, async: false

  test "agent_new_form state advertises project_cwd as optional for file flavors" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.IdentityData.state_for(
        %{component: "agent_new_form", title: "New agent", path: "/identities/agents/new"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    refute "cc" in state["cwd_required_flavors"]
    refute "codex" in state["cwd_required_flavors"]
    # P2: echo (the only cwd-required-with-PTY flavor) retired into py, which has
    # no PTY-cwd rule — so no flavor requires cwd-with-PTY now.
    assert state["cwd_required_with_pty_flavors"] == []
    refute "curl" in state["cwd_required_flavors"]
  end

  test "agent_new_form state includes configured custom project_cwd roots" do
    ws = Ezagent.URI.workspace("acme")
    root = Path.join(System.tmp_dir!(), "ezagent-world-root")
    prev = System.get_env("EZAGENT_ALLOWED_CWD_ROOTS")
    System.put_env("EZAGENT_ALLOWED_CWD_ROOTS", root)

    on_exit(fn ->
      if prev,
        do: System.put_env("EZAGENT_ALLOWED_CWD_ROOTS", prev),
        else: System.delete_env("EZAGENT_ALLOWED_CWD_ROOTS")
    end)

    state =
      Ezagent.World.IdentityData.state_for(
        %{component: "agent_new_form", title: "New agent", path: "/identities/agents/new"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert state["allowed_project_cwd_roots"] == [Path.expand(root)]
  end

  test "agent_detail state of a non-existent agent is a clean not-found, not a shell (F2)" do
    # No app/registries are started in this plugin's unit test harness, so this
    # probe agent has NO live process AND NO snapshot — i.e. it does not exist.
    # F2: the builder must signal `agent_not_found` (so the React detail renders
    # a not-found empty state) instead of a hollow shell of "—"/"unknown" rows.
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

    assert state["agent_not_found"] == true
    assert state["agent_uri"] == URI.to_string(agent_uri)
    # The hollow-shell fields are NOT emitted for a non-existent agent.
    refute Map.has_key?(state, "granted_caps")
    refute Map.has_key?(state, "project_cwd")
  end

  test "create_error_message maps backend reasons to operator-facing text" do
    assert Ezagent.World.IdentityData.create_error_message(
             {:cwd_outside_allowed_roots, "/etc/passwd"}
           ) =~ "允许"

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

  test "create_error_message gives py's :missing_script a friendly hint, not a raw atom (F6)" do
    msg = Ezagent.World.IdentityData.create_error_message(:missing_script)
    assert is_binary(msg) and msg != ""
    # No raw `:missing_script` atom leaking to the operator.
    refute msg =~ "missing_script"
    assert msg =~ "script"
  end

  test "agent_new_form marks py as a script-required flavor (F6)" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.IdentityData.state_for(
        %{component: "agent_new_form", title: "New agent", path: "/identities/agents/new"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    assert "py" in state["script_required_flavors"]
  end

  test "agents_table state carries agent_flavors for the flavor filter (F1)" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.IdentityData.state_for(
        %{component: "agents_table", title: "Agents", path: "/identities/agents"},
        %{workspace_uri: ws, caller_uri: nil, caller_caps: MapSet.new()}
      )

    # The flavor filter chips read `agent_flavors`; without it the AgentsTable
    # FilterBar would render only the static All/Users/Agents chips.
    assert Map.has_key?(state, "agent_flavors")
    assert is_list(state["agent_flavors"])
    assert is_list(state["agents"])
  end
end
