defmodule Ezagent.World.UserDataMetadataTest do
  @moduledoc """
  Read-plane PR-4 rework (F4) — the users-table roster is enumerated
  through the caller-authorizing `Ezagent.Workspace.UserReads`
  chokepoint, and another user's account/security metadata (email,
  password presence, confirmation, disablement) is emitted ONLY for the
  caller themself or an operator. A redacted field renders `nil`
  (undisclosed), never `false` (which would assert the negation).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.UserData

  @sensitive ~w(email has_password confirmed email_verified disabled disabled_at disabled_by disabled_reason)

  setup do
    ws_name = "f4-users-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(ws_name, %{})
    ws = Ezagent.URI.workspace(ws_name)

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

    {:ok, ws: ws, ws_name: ws_name, viewer: viewer, other: other}
  end

  test "F4: a same-workspace member sees the roster but NOT another user's account/security metadata",
       %{ws: ws, viewer: viewer, other: other} do
    rows = UserData.list_users(viewer, ws)

    other_row = find_row(rows, other)
    viewer_row = find_row(rows, viewer)

    # The roster itself (URI + display name + presence) stays visible —
    # that's the workspace member directory.
    assert other_row["uri"] == URI.to_string(other)
    assert is_binary(other_row["display_name"])

    # …but every sensitive field is undisclosed (nil — never a negated value).
    for field <- @sensitive do
      assert Map.get(other_row, field) == nil,
             "expected #{field} undisclosed for a non-authorizing caller, got: #{inspect(Map.get(other_row, field))}"
    end

    # The caller's OWN row carries full metadata (self is an authorizing
    # relationship). A password-created user is auto-confirmed.
    assert viewer_row["has_password"] == true
    assert viewer_row["confirmed"] == true
    assert viewer_row["disabled"] == false
  end

  test "F4: an operator sees full metadata for every row", %{ws: ws, other: other} do
    rows = UserData.list_users(Ezagent.Entity.User.admin_uri(), ws)
    other_row = find_row(rows, other)

    assert other_row["has_password"] == true
    assert other_row["disabled"] == true
    assert other_row["disabled_reason"] == "offboarded"
    assert is_binary(other_row["email"])
  end

  test "F4: a non-member principal gets NO roster at all (fail-closed)", %{
    ws: ws,
    ws_name: ws_name
  } do
    outsider = Ezagent.URI.user(ws_name, "outsider")
    {:ok, _} = Ezagent.Users.create(outsider, nil, [])

    assert UserData.list_users(outsider, ws) == []
    assert UserData.list_users(nil, ws) == []
  end

  defp find_row(rows, %URI{} = uri) do
    Enum.find(rows, &(&1["uri"] == URI.to_string(uri))) ||
      raise "expected a row for #{URI.to_string(uri)}"
  end
end
