defmodule Ezagent.Entity.UserTest do
  use ExUnit.Case, async: true
  alias Ezagent.Entity.User
  alias Ezagent.Capability

  test "admin_uri/0 returns entity://system/user/admin" do
    uri = User.admin_uri()
    assert %URI{} = uri
    assert uri.scheme == "entity"
    assert uri.host == "system"
    # Phase 9 PR-8 (SPEC v3 §13.1): admin lives in workspace://system,
    # not workspace://team-alpha — Keycloak realm-admin model.
    assert uri.path == "/user/admin"
  end

  test "admin genesis cap is exactly the structural all-caps wildcard, self-granted by the admin entity" do
    caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    assert %MapSet{} = caps
    assert MapSet.size(caps) == 1

    [cap] = MapSet.to_list(caps)
    assert cap.kind == :any
    assert cap.behavior == :any
    assert cap.instance == :any
    # Phase 9 PR-3 (SPEC v3 §4.4): admin's structural cap gains
    # `workspace_uri: :any` so it is cross-workspace by design.
    assert cap.workspace_uri == :any
    # #154 genesis collapse (2026-06-20): the genesis cap is now granted by the
    # admin ENTITY (a real entity), NOT the eliminated `system://bootstrap`
    # principal. granted_by == entity://system/user/admin.
    assert cap.granted_by.scheme == "entity"
    assert URI.to_string(cap.granted_by) == URI.to_string(User.admin_uri())
  end

  test "admin_caps cap matches any invocation" do
    [cap] = MapSet.to_list(MapSet.new([Ezagent.Capability.admin_genesis_cap()]))

    assert Capability.matches?(cap, %{
             kind: :random,
             behavior: SomeMod,
             action: :any,
             instance: Ezagent.URI.new!("entity://team-alpha/agent/test_anything"),
             workspace_uri: URI.new!("workspace://anything")
           })
  end

  test "admin_caps cap is refused by revoke/2" do
    [admin_cap] = MapSet.to_list(MapSet.new([Ezagent.Capability.admin_genesis_cap()]))
    caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    assert {:error, :cannot_revoke_admin} = Capability.revoke(caps, admin_cap)
  end

  test "Kind callbacks return the User-Kind Behaviors (post ApiKeys-to-Agent flip)" do
    # Phase 3d added Identity; PR #126 added ApiKeys but Allen 2026-05-26
    # FLIPPED ApiKeys to the Agent Kind (agents hold their own keys); User
    # no longer carries it. HIGH-2 completion (2026-05-26) added
    # UserCredentials + UserTokens for dispatch-backed password + token
    # CRUD.
    assert User.type_name() == :user

    assert User.behaviors() == [
             Ezagent.ActionSet.Identity,
             Ezagent.ActionSet.UserCredentials,
             Ezagent.ActionSet.UserTokens
           ]

    refute Ezagent.ActionSet.ApiKeys in User.behaviors(),
           "ApiKeys MUST live on Agent Kind only (Allen 2026-05-26 flip); " <>
             "re-introducing it on User Kind would resurrect the per-user " <>
             "credential bag the flip dismantled."

    assert User.persistence() == {:snapshot, :on_change}
  end

  describe "default_caps/1 (PR-甲-2, #154 — narrowed to [])" do
    @workspace URI.new!("workspace://team-alpha")

    # PR-甲-2 (spec 2026-06-19-membership-mount-anon-model-design): the broad
    # `cap(:session, :any, :any)` baseline (granted_by system://bootstrap) is
    # REMOVED. Participation + join authority are granted per-session at the
    # trusted access points (owner-rooted), not as a creation baseline — so a
    # fresh user starts with NO standing session caps (least-privilege).
    test "returns [] — no broad session baseline (least-privilege, owner-rooted join)" do
      assert User.default_caps(@workspace) == [],
             "default_caps must be empty after PR-甲-2 — participation is " <>
               "per-session at join, not a universal baseline"
    end

    test "no session:any:any baseline is present (the removed #154 violation)" do
      refute Enum.any?(User.default_caps(@workspace), fn c ->
               c.kind == :session and c.behavior == :any and c.instance == :any
             end),
             "the broad workspace-wide session baseline must be gone"
    end

    test "no system://bootstrap-granted cap (the removed unowned-grant)" do
      refute Enum.any?(User.default_caps(@workspace), fn c ->
               c.granted_by.scheme == "system"
             end),
             "default_caps must mint no system://-granted cap (Decision #154)"
    end

    test "does NOT include the admin wildcard" do
      refute Enum.any?(User.default_caps(@workspace), fn c ->
               c.kind == :any and c.behavior == :any and c.instance == :any
             end),
             "default_caps must not grant the admin escape hatch to ordinary users"
    end
  end
end
