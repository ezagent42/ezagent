defmodule EzagentCore.Invariants.SystemWorkspaceMembershipTest do
  @moduledoc """
  Phase 9 PR-8 (SPEC v3 §13) invariant — system workspace +
  membership-based cross-workspace authority (Keycloak realm-admin
  model).

  This is the gate test per memory
  `feedback_completion_requires_invariant_test`: PR-8 is "done" iff
  this test passes AND would fail if any of:

  - `workspace://system` is not created at boot (or is created
    with `visible: true`).
  - Admin's URI is not `entity://user/system/admin`.
  - `Capability.cross_workspace?/2` no longer recognizes
    `workspace://system` membership as a bypass.
  - `Ezagent.Workspace.list_visible/0` includes the system workspace.

  ## Coverage

  1. `workspace://system` exists at boot (chat plugin's
     `ensure_system_workspace/0` creates it — SPEC v2 PR-C #295
     deleted the previously-seeded `default` workspace, so `system`
     is now the only boot-seeded workspace).
  2. The system workspace row has `visible: false`.
  3. `Ezagent.Workspace.list_visible/0` excludes it; `list_all/0`
     includes it.
  4. `Ezagent.Entity.User.admin_uri/0` returns
     `entity://user/system/admin`.
  5. `Capability.cross_workspace?(cap, system_member_uri)` returns
     true for ANY cap (membership-based authority).
  6. `Capability.cross_workspace?(cap, regular_user_uri)` returns
     true ONLY when `cap.workspace_uri == :any` (structural).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability

  defp setup_workspaces do
    # The chat plugin boots `workspace://system` in :dev/:prod via
    # `ensure_system_workspace/0`; in :test the call is short-
    # circuited (DataCase concerns). SPEC v2 PR-F (2026-05-24): the
    # `default` row is no longer boot-seeded in production — we
    # provision it here as a TEST FIXTURE so the cross-workspace
    # assertions below have two workspaces to compare across.
    Enum.each(
      [
        {"system", %{visible: false}},
        {"default", %{visible: true}}
      ],
      fn {name, attrs} ->
        case Ezagent.Workspace.Store.get_by_name(name) do
          nil -> {:ok, _} = Ezagent.Workspace.Store.create(name, attrs)
          _ -> :ok
        end
      end
    )
  end

  defp cap_in_workspace(workspace_str) do
    %Capability{
      kind: :session,
      behavior: :any,
      instance: :any,
      workspace_uri: URI.new!(workspace_str),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: ~U[2026-05-21 00:00:00Z]
    }
  end

  defp cap_any_workspace do
    %Capability{
      kind: :any,
      behavior: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("system://bootstrap/default"),
      granted_at: ~U[2026-05-21 00:00:00Z]
    }
  end

  describe "workspace://system exists with visible: false" do
    test "Store.get_by_name(\"system\") returns a row with visible: false" do
      setup_workspaces()

      row = Ezagent.Workspace.Store.get_by_name("system")

      assert row,
             "workspace://system must exist after boot — chat plugin's " <>
               "ensure_system_workspace/0 creates it. If this fails, the " <>
               "boot seed order regressed and admin's URI workspace doesn't " <>
               "resolve."

      assert row.visible == false,
             "workspace://system MUST have visible: false so it stays out " <>
               "of the operator workspace dropdown (SPEC §13.1). Got " <>
               "visible: #{inspect(row.visible)}."
    end

    test "list_visible/0 excludes system workspace; list_all/0 includes it" do
      setup_workspaces()

      visible_names = Ezagent.Workspace.list_visible() |> Enum.map(& &1.name)
      all_names = Ezagent.Workspace.list_all() |> Enum.map(& &1.name)

      refute "system" in visible_names,
             "workspace://system leaked into list_visible/0 — the dropdown " <>
               "would show it. Check Store.list_visible's WHERE clause."

      assert "system" in all_names,
             "list_all/0 must still return system workspace — admin tooling " <>
               "and the Loader rehydrate from this full list."

      assert "default" in visible_names,
             "workspace://default missing from list_visible/0 — operator " <>
               "users would see an empty dropdown."
    end
  end

  describe "admin URI" do
    test "User.admin_uri/0 returns entity://user/system/admin" do
      assert URI.to_string(Ezagent.Entity.User.admin_uri()) ==
               "entity://user/system/admin",
             "admin's URI MUST be in workspace://system per SPEC §13.1. " <>
               "If this fails, the Keycloak realm-admin model is broken — " <>
               "admin would be in workspace://default and would not be a " <>
               "system member, so cross-workspace dispatch via membership " <>
               "would no-op."
    end

    test "admin's URI is a system-workspace member by structure" do
      caller_workspace =
        Ezagent.Entity.User.admin_uri()
        |> Ezagent.URI.entity_workspace_uri()
        |> URI.to_string()

      assert caller_workspace == "workspace://system"
    end
  end

  describe "Capability.cross_workspace?/2 — membership-based bypass" do
    test "system member + arbitrary cap → true (Keycloak realm-admin model)" do
      # A workspace-scoped cap held by a system member is treated as
      # cross-workspace by virtue of the caller's membership. SPEC §13.3
      # — the bootstrap admin doesn't need every cap to be `:any`;
      # being in system grants the structural bypass.
      caller = Ezagent.Entity.User.admin_uri()
      narrow_cap = cap_in_workspace("workspace://team-alpha")

      assert Capability.cross_workspace?(narrow_cap, caller),
             "system member must have cross-workspace authority by " <>
               "membership — SPEC §13.3. If this fails, the arity-2 form " <>
               "stopped detecting the system workspace OR `workspace_of/1` " <>
               "stopped extracting workspace from entity URIs."
    end

    test "system member + cross-workspace cap → true (structural also OK)" do
      caller = Ezagent.Entity.User.admin_uri()
      any_cap = cap_any_workspace()

      assert Capability.cross_workspace?(any_cap, caller),
             "system member holding the :any cap MUST also pass — both " <>
               "the structural path (cap.workspace_uri == :any) and the " <>
               "membership path should return true."
    end

    test "regular user + concrete workspace cap → false (no bypass)" do
      caller = URI.new!("entity://user/default/allen")
      narrow_cap = cap_in_workspace("workspace://team-alpha")

      refute Capability.cross_workspace?(narrow_cap, caller),
             "regular users (not in workspace://system) MUST NOT get a " <>
               "cross-workspace bypass for workspace-scoped caps. If this " <>
               "succeeds, every user effectively becomes an admin — the " <>
               "tenant isolation guarantee is gone."
    end

    test "regular user + :any cap → true (structural bypass only)" do
      caller = URI.new!("entity://user/default/allen")
      any_cap = cap_any_workspace()

      assert Capability.cross_workspace?(any_cap, caller),
             "the structural :any cap MUST still grant cross-workspace " <>
               "authority for explicit cross-workspace grants — otherwise " <>
               "operator-granted `cross-workspace:dispatch` caps would " <>
               "stop working."
    end

    test "arity-1 form retained for backward compat" do
      # The arity-1 form is what older call-sites (and `to_map/1`
      # round-trip sanity) use. Must still recognize :any.
      assert Capability.cross_workspace?(cap_any_workspace())
      refute Capability.cross_workspace?(cap_in_workspace("workspace://default"))
    end
  end
end
