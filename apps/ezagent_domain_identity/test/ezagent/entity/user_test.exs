defmodule Ezagent.Entity.UserTest do
  use ExUnit.Case, async: true
  alias Ezagent.Entity.User
  alias Ezagent.Capability

  test "admin_uri/0 returns entity://user/system/admin" do
    uri = User.admin_uri()
    assert %URI{} = uri
    assert uri.scheme == "entity"
    assert uri.host == "user"
    # Phase 9 PR-8 (SPEC v3 §13.1): admin lives in workspace://system,
    # not workspace://team-alpha — Keycloak realm-admin model.
    assert uri.path == "/system/admin"
  end

  test "admin_caps/0 returns a MapSet containing exactly the structural all-caps cap" do
    caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
    assert %MapSet{} = caps
    assert MapSet.size(caps) == 1

    [cap] = MapSet.to_list(caps)
    assert cap.kind == :any
    assert cap.behavior == :any
    assert cap.instance == :any
    # Phase 9 PR-3 (SPEC v3 §4.4): admin's structural cap gains
    # `workspace_uri: :any` so it is cross-workspace by design.
    assert cap.workspace_uri == :any
    # PR #141 SPEC v2 §5.1: system://bootstrap → system://bootstrap/default
    assert cap.granted_by.scheme == "system"
    assert cap.granted_by.host == "bootstrap"
    assert cap.granted_by.path == "/default"
  end

  test "admin_caps cap matches any invocation" do
    [cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))

    assert Capability.matches?(cap, %{
             kind: :random,
             behavior: SomeMod,
             instance: URI.parse("entity://agent/team-alpha/test_anything"),
             workspace_uri: URI.new!("workspace://anything")
           })
  end

  test "admin_caps cap is refused by revoke/2" do
    [admin_cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))
    caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
    assert {:error, :cannot_revoke_admin} = Capability.revoke(caps, admin_cap)
  end

  test "Kind callbacks return Phase 3d values (Identity behavior added) + PR #126 ApiKeys" do
    assert User.type_name() == :user
    assert User.behaviors() == [Ezagent.Behavior.Identity, Ezagent.Behavior.ApiKeys]
    assert User.persistence() == {:snapshot, :on_change}
  end

  describe "default_caps/1 (PR 27 + Phase 9 PR-3)" do
    @workspace URI.new!("workspace://team-alpha")

    test "includes a kind=:session cap so every user can attempt session behaviors" do
      caps = User.default_caps(@workspace)

      assert is_list(caps)

      assert Enum.any?(caps, fn c ->
               c.kind == :session and c.behavior == :any and c.instance == :any
             end),
             "expected a session:any:any cap in default_caps, got: #{inspect(caps)}"
    end

    test "default caps are granted_by system://bootstrap (structural, not human-issued)" do
      for c <- User.default_caps(@workspace) do
        assert c.granted_by.scheme == "system"
        assert c.granted_by.host == "bootstrap"
      end
    end

    test "default_caps does NOT include the admin wildcard" do
      refute Enum.any?(User.default_caps(@workspace), fn c ->
               c.kind == :any and c.behavior == :any and c.instance == :any
             end),
             "default_caps must not grant the admin escape hatch to ordinary users"
    end

    test "default caps carry the workspace URI passed in (Phase 9 PR-3 §4.5)" do
      ws = URI.new!("workspace://team-alpha")

      for c <- User.default_caps(ws) do
        assert URI.to_string(c.workspace_uri) == "workspace://team-alpha",
               "default_caps/1 must propagate workspace_uri so per-user caps " <>
                 "are workspace-scoped (cross-workspace requires explicit cap)"
      end
    end
  end
end
