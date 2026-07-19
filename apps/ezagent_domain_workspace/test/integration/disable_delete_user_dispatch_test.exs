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

  setup do
    ws_name = "offboard-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    # #1457 (per-Kind signing authority): dispatch step 5.5 only accepts
    # target-SIGNED caps now — build the genesis-admin ctx through the test
    # chokepoint (a wildcard workspace cap signed by the workspace Kind).
    admin_ctx =
      Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

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
    test "delete requires disable first (must_disable_first fail-loud on a live user)", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx,
      user_uri_str: user_uri_str
    } do
      # Change 2: genesis admin, but target not yet disabled → refused intact.
      assert {:error, :must_disable_first} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "premature"},
                 admin_ctx
               )

      refute Users.deleted?(user_uri_str)
      assert Users.verify_password(user_uri_str, "user-password")
    end

    test "admin deletes a disabled user; row tombstoned (URI not reclaimable) + login blocked",
         %{
           ws_name: ws_name,
           workspace_uri: workspace_uri,
           admin_ctx: admin_ctx,
           user_uri_str: user_uri_str
         } do
      # Disable-before-delete (Change 2).
      {:ok, _} =
        Workspace.disable_user(workspace_uri, %{user_uri: user_uri_str, reason: "off"}, admin_ctx)

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

  describe "authorization separation (step 5.5 CapBAC + genesis-admin gate)" do
    test "a workspace-admin-scoped cap holder may disable but is DENIED delete (genesis-admin-only)",
         %{
           workspace_uri: workspace_uri,
           ws_name: ws_name,
           user_uri_str: user_uri_str
         } do
      operator = URI.new!("entity://#{ws_name}/user/operator")

      # Change 1: give the operator BOTH cap subjects (so step 5.5 passes for
      # delete too) — proving the genesis-admin gate, NOT a missing cap, is
      # what rejects delete. This operator is a workspace-scoped admin, NOT
      # the genesis admin `entity://system/user/admin`. #1457: the caps must
      # be target-SIGNED artifacts.
      disable_target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, :disable_user)
      delete_target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, :delete_user)

      operator_ctx = %{
        caller: operator,
        caps:
          MapSet.new([
            Ezagent.Test.CapHelper.signed_action_cap!(disable_target, operator),
            Ezagent.Test.CapHelper.signed_action_cap!(delete_target, operator)
          ])
      }

      # disable_user: authorized (workspace-admin-grantable, reversible).
      assert {:ok, %{user_uri: ^user_uri_str}} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "operator offboard"},
                 operator_ctx
               )

      # delete_user: DENIED with :genesis_admin_only even though the cap IS
      # held and the user is now disabled — global identity destruction is
      # gated to the genesis admin alone.
      assert {:error, :genesis_admin_only} =
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

      assert {:error, :missing_cap} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: nil},
                 nobody_ctx
               )

      assert {:error, :missing_cap} =
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

  describe "delete_user cascades workspace-membership removal (Change 4)" do
    test "a user listed as a member of TWO workspaces is detached from BOTH on delete" do
      suffix = System.unique_integer([:positive])
      ws_a = "cascade-a-#{suffix}"
      ws_b = "cascade-b-#{suffix}"

      user = "entity://#{ws_a}/user/multi"
      user_uri = URI.new!(user)
      {:ok, _} = Users.create(user, "pw", [])

      # Seed the user into BOTH workspaces' member_uris (create-with-members
      # seeds DB + Kind directly — the ws_b entry is the cross-prefix "ghost"
      # membership Change 4 must sweep; add_member/2 would reject it).
      {:ok, _} = Workspace.create(ws_a, %{members: [user_uri]})
      {:ok, _} = Workspace.create(ws_b, %{members: [user_uri]})
      assert member?(ws_a, user)
      assert member?(ws_b, user)

      ws_a_uri = URI.new!("workspace://#{ws_a}")

      # #1457: the admin ctx must be signed by the TARGET workspace's
      # authority — the setup ctx is signed for the setup workspace and
      # would fail signature verification against ws_a.
      admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(ws_a_uri, User.admin_uri())

      {:ok, _} =
        Workspace.disable_user(ws_a_uri, %{user_uri: user, reason: "off"}, admin_ctx)

      assert {:ok, %{user_uri: ^user}} =
               Workspace.delete_user(ws_a_uri, %{user_uri: user, reason: "gone"}, admin_ctx)

      # Identity tombstoned AND detached from every workspace's member list.
      assert Users.deleted?(user)
      refute member?(ws_a, user)
      refute member?(ws_b, user)
    end
  end

  describe "add_member rejects a tombstoned user (task #180 fork-#3)" do
    test "a deleted user cannot be re-added as a workspace member", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx,
      user_uri_str: user_uri_str
    } do
      user_uri = URI.new!(user_uri_str)

      # Offboard: disable → delete.
      {:ok, _} =
        Workspace.disable_user(workspace_uri, %{user_uri: user_uri_str, reason: "off"}, admin_ctx)

      assert {:ok, _} =
               Workspace.delete_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "gone"},
                 admin_ctx
               )

      assert Users.deleted?(user_uri_str)

      # Re-adding the tombstoned URI is refused fail-loud (would otherwise grant a
      # fresh create_session cap + respawn the Kind — partial resurrection).
      assert {:error, :member_is_deleted} = Workspace.add_member(ws_name, user_uri)
      refute member?(ws_name, user_uri_str)
    end
  end

  defp member?(ws_name, user_str) do
    case Ezagent.Workspace.Store.get_by_name(ws_name) do
      %{members: members} when is_list(members) ->
        Enum.any?(members, fn m -> URI.to_string(m) == user_str end)

      _ ->
        false
    end
  end
end
