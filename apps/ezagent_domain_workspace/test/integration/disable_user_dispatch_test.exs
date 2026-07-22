defmodule Ezagent.Integration.DisableUserDispatchTest do
  @moduledoc """
  Acceptance test for operator offboarding (task #180): the dispatch-backed
  `:disable_user` action on `Ezagent.ActionSet.WorkspaceUserAdmin`, reached via
  `Ezagent.Workspace.disable_user/3` — the SAME code path the auto-derived
  `mix ezagent workspace disable_user` CLI dispatches through.

  Verifies (through real `Ezagent.Invocation.dispatch/1` — step 5.5 CapBAC +
  the action body's cross-workspace check):

  - Happy path (admin): disable cuts login (reversible), attribution is the
    authenticated caller.
  - AuthZ: a workspace-scoped holder of the `disable_user` cap may disable; an
    empty-caps caller is denied `:missing_cap`.
  - Cross-workspace refusal and unknown-user handling.

  The HARD `delete_user` counterpart is a separate task (branch
  `feat/delete-user-atomic-revocation`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Users

  setup do
    ws_name = "disable-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx =
      Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

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
    end
  end

  describe "authorization (step 5.5 CapBAC)" do
    test "a caller holding the disable_user cap may disable", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name,
      user_uri_str: user_uri_str
    } do
      operator = URI.new!("entity://#{ws_name}/user/operator")
      target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, :disable_user)
      operator_cap = Ezagent.Test.CapHelper.signed_action_cap!(target, operator)

      {:ok, _pid} =
        Ezagent.Kind.spawn(User, %{
          uri: operator,
          initial_caps: MapSet.new([operator_cap])
        })

      operator_ctx = %{
        caller: operator,
        authenticated_principal: operator,
        caps: Ezagent.Identity.list_caps_for(operator)
      }

      assert {:ok, %{user_uri: ^user_uri_str}} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: "operator offboard"},
                 operator_ctx
               )

      assert Users.disabled?(user_uri_str)
    end

    test "an empty-caps caller is denied", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name,
      user_uri_str: user_uri_str
    } do
      nobody = URI.new!("entity://#{ws_name}/user/nobody")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: nobody, initial_caps: MapSet.new()})

      nobody_ctx = %{
        caller: nobody,
        authenticated_principal: nobody,
        caps: Ezagent.Identity.list_caps_for(nobody)
      }

      assert {:error, :missing_cap} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, reason: nil},
                 nobody_ctx
               )

      refute Users.disabled?(user_uri_str)
    end
  end

  describe "structural + not-found handling" do
    test "disable_user with a user in a different workspace is refused (cross-workspace)", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      other_user = "entity://some-other-ws/user/elsewhere"

      assert {:error, {:cross_workspace_user, _}} =
               Workspace.disable_user(
                 workspace_uri,
                 %{user_uri: other_user, reason: nil},
                 admin_ctx
               )
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
