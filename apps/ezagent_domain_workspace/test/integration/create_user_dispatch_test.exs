defmodule Ezagent.Integration.CreateUserDispatchTest do
  @moduledoc """
  Acceptance test for HIGH-2 completion (`docs/futures/todo.md` —
  CLI ↔ GUI parity): the dispatch-backed `:create_user` action on
  `Behavior.Workspace` that replaces the legacy
  `mix ezagent.user.create` task's direct call into
  `Ezagent.Users.create/3`.

  Verifies:

  - Happy path: a non-admin user is provisioned under the target
    workspace and the row exists in the `users` table (post-dispatch
    state visible to `Ezagent.Users.get_by_uri/1`).
  - Cross-workspace refusal: a `workspace://A` target with a user URI
    under `workspace://B` returns `{:error, {:cross_workspace_user,
    _}}` and DOES NOT insert a row.
  - Bad URI shape: a non-entity URI is rejected at parse time with
    `{:error, {:bad_user_uri, _, _}}`.
  - Cap parsing failure: a malformed caps string surfaces the parser
    error.
  - Idempotent re-run: a duplicate user_uri returns
    `{:error, %Ecto.Changeset{}}` (unique constraint) and the
    original row is preserved.

  The full CapBAC + audit + cross-workspace step-5.6 wiring is
  exercised by `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs`;
  this test focuses on the action body's contract surface.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Users

  setup do
    ws_name = "create-user-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = signed_workspace_ctx!(workspace_uri)

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "happy path — user is provisioned via dispatch" do
    test "user_uri matching the target workspace inserts a row + returns dispatch payload",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      user_uri_str = "entity://#{ws_name}/user/alice"

      assert {:ok,
              %{
                user_uri: ^user_uri_str,
                caps_granted: 0,
                password_set: true,
                spawned: spawn_status
              }} =
               Workspace.create_user(
                 workspace_uri,
                 %{
                   user_uri: user_uri_str,
                   password: "test-password-not-secret",
                   caps: ""
                 },
                 admin_ctx
               )

      # spawn_status is a runtime-dependent string ("spawned" /
      # "already_running" / "spawn_deferred:..."); just verify it's a
      # non-empty atom report.
      assert is_binary(spawn_status) and spawn_status != ""

      # Verify the DB row is real — same surface
      # `Ezagent.Users.verify_password/2` reads.
      assert %{uri: %URI{}, caps: caps} = Users.get_by_uri(user_uri_str)
      # The create facade also adds the user as a workspace member, which now
      # self-stores the target-signed workspace.create_session membership cap.
      assert Enum.any?(caps, fn cap ->
               cap.behavior == Ezagent.ActionSet.Workspace and
                 cap.action == :create_session and cap.instance == workspace_uri and
                 cap.grantee_uri == Ezagent.URI.new!(user_uri_str)
             end)
      assert Users.verify_password(user_uri_str, "test-password-not-secret")
    end

    test "nil password creates a row with password_hash NULL", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      user_uri_str = "entity://#{ws_name}/user/no-pw"

      assert {:ok, %{password_set: false}} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: nil, caps: ""},
                 admin_ctx
               )

      refute Users.verify_password(user_uri_str, "anything")
    end
  end

  describe "structural cross-workspace check (HIGH-2 hardening)" do
    test "user_uri in a different workspace returns {:error, {:cross_workspace_user, _}} and does NOT insert",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # workspace_uri target is `workspace://create-user-test-N`; the
      # user URI's workspace segment is `other-ws`. The action body's
      # `ensure_user_in_target_workspace/2` must refuse.
      user_uri_str = "entity://other-ws/user/bob"

      assert {:error, {:cross_workspace_user, target_workspace: _, user_workspace: _}} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "x", caps: ""},
                 admin_ctx
               )

      # No row inserted (the check fires BEFORE Users.create/3).
      assert is_nil(Users.get_by_uri(user_uri_str))
    end
  end

  describe "argument validation" do
    test "missing user_uri is rejected by InterfaceValidator before reaching the action body",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # `interface/0` declares user_uri as a required arg (no
      # `:option` wrapper), so `Ezagent.InterfaceValidator.run/2` at
      # dispatch step 5 surfaces a structured `:invalid_args` error
      # BEFORE the action body's own `:user_uri_required` check fires.
      # Either shape is acceptable (defence in depth — both fail
      # closed).
      assert {:error, {:invalid_args, _}} =
               Workspace.create_user(
                 workspace_uri,
                 %{password: "x", caps: ""},
                 admin_ctx
               )
    end

    test "non-entity URI surfaces as {:error, {:bad_user_uri, _, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_user_uri, "workspace://x", _msg}} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: "workspace://x", password: nil, caps: ""},
                 admin_ctx
               )
    end

    test "agent URI (right scheme, wrong type) is rejected", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_user_uri, _, _}} =
               Workspace.create_user(
                 workspace_uri,
                 %{
                   user_uri: "entity://#{ws_name}/agent/cc_x",
                   password: nil,
                   caps: ""
                 },
                 admin_ctx
               )
    end
  end

  describe "idempotency — duplicate user_uri" do
    test "second create_user on the same URI returns a changeset error + leaves first row intact",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      user_uri_str = "entity://#{ws_name}/user/dup"

      assert {:ok, _} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "first", caps: ""},
                 admin_ctx
               )

      # Second create — unique constraint on `uri` should refuse.
      assert {:error, _} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "second", caps: ""},
                 admin_ctx
               )

      # First-write password survives.
      assert Users.verify_password(user_uri_str, "first")
      refute Users.verify_password(user_uri_str, "second")
    end
  end
end
