defmodule Ezagent.World.AdminDataTest do
  # async: false — these read global KindRegistry state. Settings state also
  # reads `app_settings`, so the test must own a SQL Sandbox connection.
  use EzagentCore.DataCase, async: false

  @admin Ezagent.Entity.User.admin_uri()

  test "overview state includes kpis, available_sessions, and session_template_names" do
    ws = Ezagent.URI.workspace("acme")

    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: ws, caller_uri: @admin, caller_caps: MapSet.new()}
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
        %{workspace_uri: ws, caller_uri: @admin, caller_caps: MapSet.new()}
      )

    {:ok, _encoded} = Jason.encode(state)
  end

  test "overview state with nil workspace_uri does not crash (guard rail)" do
    state =
      Ezagent.World.AdminData.state_for(
        %{component: "overview", title: "Overview", path: "/"},
        %{workspace_uri: nil, caller_uri: @admin, caller_caps: MapSet.new()}
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
        %{workspace_uri: entity_uri, caller_uri: @admin, caller_caps: MapSet.new()}
      )

    assert is_map(state["kpis"])
    assert state["available_sessions"] == []
  end

  # F5 (read-plane PR-4 rework): a non-operator caller is REJECTED — the
  # state carries an explicit `unauthorized` marker and NO data keys, so a
  # denied caller can never be shown a coerced empty table (was: `[]` for
  # the entity registry, zero-count KPIs for dashboard/overview).
  describe "F5 — non-operator callers get an explicit unauthorized state, not an empty table" do
    setup do
      non_operator =
        Ezagent.URI.new!("entity://team-alpha/user/plain-#{System.unique_integer([:positive])}")

      {:ok, non_operator: non_operator}
    end

    test "dashboard kpis", %{non_operator: caller} do
      state =
        Ezagent.World.AdminData.state_for(
          %{component: "dashboard", title: "Admin Dashboard", path: "/admin"},
          %{workspace_uri: nil, caller_uri: caller, caller_caps: MapSet.new()}
        )

      assert state["unauthorized"] == true
      refute Map.has_key?(state, "kpis")
      refute Map.has_key?(state, "cc_orchestrator_status")
    end

    test "overview kpis", %{non_operator: caller} do
      state =
        Ezagent.World.AdminData.state_for(
          %{component: "overview", title: "Overview", path: "/overview"},
          %{workspace_uri: nil, caller_uri: caller, caller_caps: MapSet.new()}
        )

      assert state["unauthorized"] == true
      refute Map.has_key?(state, "kpis")
      refute Map.has_key?(state, "available_sessions")
    end

    test "entity_registry rows", %{non_operator: caller} do
      state =
        Ezagent.World.AdminData.state_for(
          %{component: "entity_registry", title: "Entity Registry", path: "/admin/registry"},
          %{workspace_uri: nil, caller_uri: caller, caller_caps: MapSet.new()}
        )

      assert state["unauthorized"] == true
      refute Map.has_key?(state, "entities")
    end

    test "templates rows", %{non_operator: caller} do
      state =
        Ezagent.World.AdminData.state_for(
          %{component: "templates", title: "Templates", path: "/admin/templates"},
          %{workspace_uri: nil, caller_uri: caller, caller_caps: MapSet.new()}
        )

      assert state["unauthorized"] == true
      refute Map.has_key?(state, "templates")
    end

    test "a nil caller is rejected too (fail-closed)" do
      state =
        Ezagent.World.AdminData.state_for(
          %{component: "entity_registry", title: "Entity Registry", path: "/admin/registry"},
          %{workspace_uri: nil, caller_uri: nil, caller_caps: MapSet.new()}
        )

      assert state["unauthorized"] == true
      refute Map.has_key?(state, "entities")
    end
  end

  describe "F5 — operator callers get the data" do
    test "entity_registry lists the registry for the bootstrap admin" do
      uri_str =
        "session://team-alpha/default/admin-data-#{System.unique_integer([:positive])}"

      :ok = Ezagent.KindRegistry.put_new(uri_str, self())

      state =
        Ezagent.World.AdminData.state_for(
          %{component: "entity_registry", title: "Entity Registry", path: "/admin/registry"},
          %{workspace_uri: nil, caller_uri: @admin, caller_caps: MapSet.new()}
        )

      refute Map.has_key?(state, "unauthorized")
      assert Enum.any?(state["entities"], &(&1["uri"] == uri_str))
    end

    test "templates lists template rows for a promoted (non-bootstrap) operator" do
      promoted =
        Ezagent.URI.new!("entity://system/user/promoted-#{System.unique_integer([:positive])}")

      state =
        Ezagent.World.AdminData.state_for(
          %{component: "templates", title: "Templates", path: "/admin/templates"},
          %{workspace_uri: nil, caller_uri: promoted, caller_caps: MapSet.new()}
        )

      refute Map.has_key?(state, "unauthorized")
      assert is_list(state["templates"])
    end
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
