defmodule Ezagent.World.UserDataDetailTest do
  @moduledoc """
  Read-plane PR-4 re-review — the per-URI user DEEP-LINK
  (`/identities/users/:uri`) routes through the caller-authorizing
  `Ezagent.Workspace.UserReads.user/2` chokepoint:

    * a same-workspace member deep-linking ANOTHER user gets the
      directory-level payload only — every account/security field is
      undisclosed (`nil`, never a negated value) and
      `can_view_metadata` is false;
    * a non-member / CROSS-TENANT caller is denied BEFORE existence is
      checked (`user_unauthorized`, no metadata, no existence oracle);
    * self and operators get the full account/security metadata;
    * an authorized caller deep-linking a missing user gets
      `user_not_found`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.UserData

  @sensitive ~w(email has_password confirmed email_verified disabled disabled_at disabled_by disabled_reason)

  setup do
    ws_name = "dl-users-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(ws_name, %{})

    viewer = Ezagent.URI.user(ws_name, "viewer")
    other = Ezagent.URI.user(ws_name, "other")
    {:ok, _} = Ezagent.Users.create(viewer, "viewer-pw", [])
    {:ok, _} = Ezagent.Users.create(other, "other-pw", [])
    {:ok, _} = Ezagent.Users.disable(other, "entity://system/user/admin", "offboarded")

    {:ok, _profile} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: URI.to_string(other),
        display_name: "Other User",
        email: "other-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [viewer, other])

    # A SECOND tenant with its own user — the cross-tenant target.
    ws_b_name = "dl-users-b-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(ws_b_name, %{})
    user_b = Ezagent.URI.user(ws_b_name, "someone")
    {:ok, _} = Ezagent.Users.create(user_b, "someone-pw", [])

    {:ok, _profile} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: URI.to_string(user_b),
        display_name: "Tenant B User",
        email: "someone-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, viewer: viewer, other: other, user_b: user_b, ws_b_name: ws_b_name}
  end

  defp detail(caller, user_uri), do: UserData.detail_state(%{}, user_uri, caller, MapSet.new())

  test "a same-workspace member deep-linking ANOTHER user gets NO account/security metadata",
       %{viewer: viewer, other: other} do
    state = detail(viewer, other)

    refute state["user_unauthorized"]
    refute state["user_not_found"]
    assert state["user_uri"] == URI.to_string(other)
    assert state["can_view_metadata"] == false
    assert is_binary(state["display_name"])

    for field <- @sensitive do
      assert Map.get(state, field) == nil,
             "expected #{field} undisclosed for a non-authorizing caller, got: #{inspect(Map.get(state, field))}"
    end
  end

  test "a CROSS-TENANT deep-link is denied outright — no metadata, no row data",
       %{viewer: viewer, user_b: user_b} do
    state = detail(viewer, user_b)

    assert state["user_unauthorized"] == true
    refute state["user_not_found"]

    for field <- ["display_name", "cap_count", "granted_caps" | @sensitive] do
      assert Map.get(state, field) == nil,
             "expected #{field} absent for a cross-tenant caller, got: #{inspect(Map.get(state, field))}"
    end
  end

  test "a provisioned NON-member deep-linking another user is denied",
       %{viewer: viewer, other: other} do
    outsider = Ezagent.URI.user(Ezagent.URI.workspace_name!(other), "outsider")
    {:ok, _} = Ezagent.Users.create(outsider, nil, [])

    assert detail(outsider, other)["user_unauthorized"] == true
    assert detail(nil, other)["user_unauthorized"] == true
    assert detail(outsider, viewer)["user_unauthorized"] == true
  end

  test "a denied caller gets NO existence oracle — ghost and real URIs are indistinguishable",
       %{viewer: viewer, ws_b_name: ws_b_name, user_b: user_b} do
    ghost_b = Ezagent.URI.user(ws_b_name, "ghost")

    assert detail(viewer, ghost_b)["user_unauthorized"] == true
    # Same denial shape as the real cross-tenant user — never user_not_found.
    assert detail(viewer, user_b)["user_unauthorized"] == true
  end

  test "self deep-link sees full own metadata", %{viewer: viewer} do
    state = detail(viewer, viewer)

    assert state["can_view_metadata"] == true
    assert state["has_password"] == true
    assert state["confirmed"] == true
    assert state["disabled"] == false
  end

  test "an operator deep-linking another user sees full metadata", %{other: other} do
    state = detail(Ezagent.Entity.User.admin_uri(), other)

    refute state["user_unauthorized"]
    assert state["can_view_metadata"] == true
    assert state["has_password"] == true
    assert state["disabled"] == true
    assert state["disabled_reason"] == "offboarded"
    assert is_binary(state["email"])
  end

  test "an authorized caller deep-linking a MISSING user gets user_not_found", %{viewer: viewer} do
    ghost = Ezagent.URI.user(Ezagent.URI.workspace_name!(viewer), "ghost")
    state = detail(viewer, ghost)

    assert state["user_not_found"] == true
    refute state["user_unauthorized"]
  end
end
