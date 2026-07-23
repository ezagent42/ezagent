defmodule Ezagent.Integration.UserCreateMembershipTest do
  @moduledoc """
  2026-07-10 golive gap regression — `mix ezagent.user.create` assigns a
  new user's `users.workspace_uri` (via `Ezagent.Users.create/3`) but,
  before the fix, never added the user to that workspace's `member_uris`.

  The "my workspaces" view (`Workspace.list_workspaces_for/2`) filters by
  MEMBERSHIP; a non-admin caller's wildcard `workspace_uri: :any` caps
  contribute NOTHING to the cap-scope branch (SPEC §3.3.b). So an
  operator-created user was assigned a workspace they could not see —
  this hit all 6 golive users (live-remediated via `add_member`).

  The mix task can't be driven inside ExUnit (its
  `Application.ensure_all_started/1` fights the test supervision tree),
  so this test exercises the SAME two writes the fixed task now performs
  in sequence — `Ezagent.Users.create/3` then
  `Ezagent.Workspace.add_member/2` — and pins the observable invariant:

    assigned workspace ⟹ membership ⟹ visible via list_workspaces_for.

  It also validates the task's workspace-NAME derivation
  (`Ezagent.URI.workspace_name!/1`) and the idempotency of a re-run.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Workspace.Store
  alias Ezagent.Users

  setup do
    ws_name = "user-create-member-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = signed_workspace_ctx!(workspace_uri)

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "assigned workspace implies membership (golive gap fix)" do
    test "after Users.create + add_member, the user is a member and the workspace is visible",
         %{ws_name: ws_name} do
      # Workspace-first URI shape (SPEC v3 Amendment 2):
      # entity://<workspace>/<type>/<name>.
      user_uri_str = "entity://#{ws_name}/user/alice"
      user_uri = Ezagent.URI.new!(user_uri_str)

      # The task's derivation of the workspace NAME from the user URI —
      # `Ezagent.URI.workspace_name!/1` — MUST recover the assigned
      # workspace. This is the exact call the fixed mix task makes; pin
      # it so a broken derivation ships red, not green.
      assert Ezagent.URI.workspace_name!(user_uri) == ws_name

      # A NON-admin wildcard cap (the historical `default_caps` shape:
      # session-kind, behavior :any, action :any → `workspace_uri: :any`).
      # Per SPEC §3.3.b this contributes NOTHING to the cap-scope branch,
      # so visibility of `ws_name` depends ONLY on membership.
      wildcard_cap = Ezagent.Capability.cap(:session, :any, :any)

      # Step 1 (task): create the user row (assigns workspace_uri).
      assert {:ok, _decoded} = Users.create(user_uri, "temp-pw-not-secret", [])
      :ok = ensure_principal(user_uri)

      # BEFORE add_member: not a member; wildcard cap drops → NOT visible.
      refute member?(ws_name, user_uri)

      refute visible?(ws_name, user_uri, [wildcard_cap]),
             "workspace should NOT be visible before membership (this IS the golive bug)"

      # Step 2 (task's fix): add the user to the workspace derived from
      # their URI — exactly `add_member(workspace_name!(user_uri), uri)`.
      assert :ok = Workspace.add_member(Ezagent.URI.workspace_name!(user_uri), user_uri)

      # AFTER: member_uris contains the user AND the workspace is visible
      # via the membership branch, despite the wildcard cap.
      assert member?(ws_name, user_uri)

      assert visible?(ws_name, user_uri, [wildcard_cap]),
             "workspace must be visible once the user is a member"
    end

    test "re-adding an existing member is idempotent (member_uris not corrupted)", %{
      ws_name: ws_name
    } do
      user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/bob")

      assert {:ok, _} = Users.create(user_uri, "temp-pw-not-secret", [])

      assert :ok = Workspace.add_member(ws_name, user_uri)
      members_after_first = current_members(ws_name)
      assert user_uri_in?(members_after_first, user_uri)

      # Second add — the exact double-assign a re-run of `user.create`
      # would produce. Must NOT duplicate the member.
      assert :ok = Workspace.add_member(ws_name, user_uri)
      members_after_second = current_members(ws_name)

      assert length(members_after_second) == length(members_after_first)
      assert count_occurrences(members_after_second, user_uri) == 1
    end
  end

  describe "Workspace.create_user/3 facade (dispatch-backed path — same golive gap)" do
    test "create_user makes the new user a member and the workspace visible", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      user_uri_str = "entity://#{ws_name}/user/carol"
      user_uri = Ezagent.URI.new!(user_uri_str)

      wildcard_cap = Ezagent.Capability.cap(:session, :any, :any)

      assert {:ok, %{user_uri: ^user_uri_str}} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "temp-pw-not-secret", caps: ""},
                 admin_ctx
               )

      :ok = ensure_principal(user_uri)

      # The facade added membership after the create_user dispatch.
      assert member?(ws_name, user_uri)

      assert visible?(ws_name, user_uri, [wildcard_cap]),
             "workspace must be visible to the created user via membership"
    end

    test "a second (duplicate) create_user does not corrupt member_uris", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      user_uri_str = "entity://#{ws_name}/user/dave"
      user_uri = Ezagent.URI.new!(user_uri_str)

      assert {:ok, _} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "first", caps: ""},
                 admin_ctx
               )

      assert member?(ws_name, user_uri)
      assert count_occurrences(current_members(ws_name), user_uri) == 1

      # Second create on the same URI fails the unique constraint BEFORE
      # add_member is reached — membership must remain intact + un-duplicated.
      assert {:error, _} =
               Workspace.create_user(
                 workspace_uri,
                 %{user_uri: user_uri_str, password: "second", caps: ""},
                 admin_ctx
               )

      assert count_occurrences(current_members(ws_name), user_uri) == 1
    end
  end

  # --- helpers -------------------------------------------------------

  defp current_members(ws_name) do
    %{members: members} = Store.get_by_name(ws_name)
    members
  end

  defp member?(ws_name, %URI{} = user_uri) do
    user_uri_in?(current_members(ws_name), user_uri)
  end

  defp user_uri_in?(members, %URI{} = user_uri) do
    Enum.any?(members, &(URI.to_string(&1) == URI.to_string(user_uri)))
  end

  defp count_occurrences(members, %URI{} = user_uri) do
    Enum.count(members, &(URI.to_string(&1) == URI.to_string(user_uri)))
  end

  defp visible?(ws_name, %URI{} = caller_uri, caps) do
    current_caps = Ezagent.EntityCaps.load(caller_uri)

    caller_uri
    |> Workspace.list_workspaces_for(Enum.concat(current_caps, caps))
    |> Enum.any?(&(&1.name == ws_name))
  end

  defp ensure_principal(%URI{} = user_uri) do
    case Ezagent.SpawnRegistry.spawn(user_uri) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> flunk("principal spawn failed: #{inspect(reason)}")
    end
  end
end
