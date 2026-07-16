defmodule Ezagent.Integration.DisableDeleteUserDispatchTest do
  @moduledoc """
  Acceptance test for operator offboarding (task #180): the dispatch-backed
  `:disable_user` (reversible soft-disable) and `:delete_user` (HARD,
  admin-only tombstone) actions on `Ezagent.ActionSet.WorkspaceUserAdmin`,
  reached via the `Ezagent.Workspace.{disable_user,delete_user}/3` facades —
  the SAME code path the auto-derived `mix ezagent workspace {disable,delete}_user`
  CLI dispatches through.

  Verifies (all through real `Ezagent.Invocation.dispatch/1` — step 5.5
  CapBAC + the action body's cross-workspace check):

  - Happy path (admin): disable cuts login (reversible); delete tombstones
    the row (RETAINED → URI not reclaimable) + blocks login + is durable.
  - AuthZ separation: a caller holding ONLY `disable_user` may disable but
    is DENIED `delete_user` (distinct cap subjects — delete is strictly
    admin-gated). An empty-caps caller is denied both.
  - Cross-workspace refusal and unknown-user handling.

  Attribution (`disabled_by` / `deleted_by`) is the AUTHENTICATED
  `ctx.caller`, never a caller-supplied arg.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Users
  alias Ezagent.ActionSet.WorkspaceUserAdmin

  setup do
    ws_name = "offboard-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    # Seed a real user to offboard.
    user_uri_str = "entity://#{ws_name}/user/target"
    {:ok, _} = Users.create(user_uri_str, "user-password", [])

    {:ok,
     ws_name: ws_name,
     workspace_uri: workspace_uri,
     admin_ctx: admin_ctx,
     user_uri_str: user_uri_str}
  end

  describe "disable_user — reversible soft-disable via dispatch" do
    test "admin disables a user; login is cut and attribution is the caller", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx,
      user_uri_str: user_uri_str
    } do
      assert Users.verify_password(user_uri_str, "user-password")

      assert {:ok, %{user_uri: ^user_uri_str, disabled_by: disabled_by, disabled_at: disabled_at}} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "offboarded"},
                 admin_ctx
               )

      assert disabled_by == URI.to_string(User.admin_uri())
      assert is_binary(disabled_at) and disabled_at != ""
      refute Users.verify_password(user_uri_str, "user-password")
      assert Users.disabled?(user_uri_str)
      # Reversible: identity/history preserved (row still present, not deleted).
      refute Users.deleted?(user_uri_str)
    end
  end

  describe "delete_user — HARD tombstone via dispatch" do
    test "admin deletes a user; row tombstoned (URI not reclaimable) + login blocked", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx,
      user_uri_str: user_uri_str
    } do
      assert {:ok, %{user_uri: ^user_uri_str, deleted_by: deleted_by, deleted_at: deleted_at}} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "left company"},
                 admin_ctx
               )

      assert deleted_by == URI.to_string(User.admin_uri())
      assert is_binary(deleted_at) and deleted_at != ""

      # Tombstone, not purge: the row is RETAINED (audit + URI occupied).
      assert Users.deleted?(user_uri_str)
      assert Users.get_by_uri(user_uri_str)
      refute Users.verify_password(user_uri_str, "user-password")

      # No silent URI reclaim: re-creating the same URI is refused.
      assert {:error, _} = Users.create(user_uri_str, "new-password", [])

      # A brand-new user in the SAME workspace still provisions fine.
      other = "entity://#{ws_name}/user/fresh"
      assert {:ok, _} = Users.create(other, "x", [])
    end
  end

  describe "authorization separation (step 5.5 CapBAC)" do
    test "caller holding ONLY disable_user may disable but is DENIED delete_user", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name,
      user_uri_str: user_uri_str
    } do
      operator = URI.new!("entity://#{ws_name}/user/operator")

      # A scoped operator holding the disable_user cap subject ONLY —
      # NOT delete_user (distinct action axis since SPEC 2026-05-27).
      operator_ctx = %{
        caller: operator,
        caps:
          MapSet.new([
            Ezagent.Capability.cap(:workspace, WorkspaceUserAdmin, :disable_user)
          ])
      }

      # disable_user: authorized.
      assert {:ok, %{user_uri: ^user_uri_str}} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "operator offboard"},
                 operator_ctx
               )

      # delete_user: DENIED — holding disable_user does not authorize delete.
      assert {:error, :unauthorized} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "should be denied"},
                 operator_ctx
               )

      # Destructive delete did NOT happen — the user is only disabled.
      refute Users.deleted?(user_uri_str)
      assert Users.get_by_uri(user_uri_str)
    end

    test "empty-caps caller is denied both disable and delete", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name,
      user_uri_str: user_uri_str
    } do
      nobody_ctx = %{
        caller: URI.new!("entity://#{ws_name}/user/nobody"),
        caps: MapSet.new()
      }

      assert {:error, :unauthorized} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: nil},
                 nobody_ctx
               )

      assert {:error, :unauthorized} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: nil},
                 nobody_ctx
               )

      refute Users.disabled?(user_uri_str)
      refute Users.deleted?(user_uri_str)
    end
  end

  describe "structural + not-found handling" do
    test "delete_user with a user in a different workspace is refused (cross-workspace)", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      other_user = "entity://some-other-ws/user/elsewhere"

      assert {:error, {:cross_workspace_user, _}} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: other_user, reason: nil},
                 admin_ctx
               )

      assert is_nil(Users.get_by_uri(other_user))
    end

    test "disable_user on an unknown (but in-workspace) user returns not_found", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      ghost = "entity://#{ws_name}/user/ghost-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: ghost, reason: nil},
                 admin_ctx
               )
    end
  end
end
