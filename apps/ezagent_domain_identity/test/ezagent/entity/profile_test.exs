defmodule Ezagent.Entity.ProfileTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile

  test "upsert/1 inserts then updates the same entity_uri" do
    {:ok, p1} = Profile.upsert(%{entity_uri: "entity://team-alpha/user/x", display_name: "X"})
    assert p1.display_name == "X"

    {:ok, p2} = Profile.upsert(%{entity_uri: "entity://team-alpha/user/x", display_name: "X Renamed"})
    assert p2.display_name == "X Renamed"

    assert Profile.get("entity://team-alpha/user/x").display_name == "X Renamed"
  end

  test "by_email/1 resolves email to profile, case-insensitively" do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://team-alpha/user/allen",
        display_name: "Allen",
        email: "allen@example.com"
      })

    assert Profile.by_email("ALLEN@example.com").entity_uri == "entity://team-alpha/user/allen"
    assert Profile.by_email("nobody@example.com") == nil
  end

  test "email uniqueness is enforced" do
    {:ok, _} =
      Profile.upsert(%{entity_uri: "entity://team-alpha/user/a", display_name: "A", email: "dup@example.com"})

    assert {:error, changeset} =
             Profile.upsert(%{
               entity_uri: "entity://team-alpha/user/b",
               display_name: "B",
               email: "dup@example.com"
             })

    assert "has already been taken" in errors_on(changeset).email
  end

  test "get/1 and by_email/1 accept a %URI{} or string" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://team-alpha/agent/echo", display_name: "Echo Bot"})
    assert Profile.get(Ezagent.URI.new!("entity://team-alpha/agent/echo")).display_name == "Echo Bot"
  end
end
