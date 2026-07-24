defmodule Ezagent.Entity.ProfileTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile

  describe "ensure_agent_display_name/2" do
    test "allocates a workspace-unique agent name and keeps same-URI retries idempotent" do
      agent_one = Ezagent.URI.new!("entity://team-alpha/agent/one")
      agent_two = Ezagent.URI.new!("entity://team-alpha/agent/two")

      assert {:ok, %Profile{display_name: "builder"}} =
               Profile.ensure_agent_display_name(agent_one, "builder")

      assert {:ok, %Profile{display_name: "builder-2"}} =
               Profile.ensure_agent_display_name(agent_two, "builder")

      assert {:ok, %Profile{display_name: "builder"}} =
               Profile.ensure_agent_display_name(agent_one, "ignored-on-retry")
    end

    test "no-email Users can share names without consuming an Agent name" do
      assert {:ok, %Profile{display_name: "builder"}} =
               Profile.upsert(%{
                 entity_uri: "entity://team-alpha/user/no-email-one",
                 display_name: "builder"
               })

      assert {:ok, %Profile{display_name: "builder"}} =
               Profile.upsert(%{
                 entity_uri: "entity://team-alpha/user/no-email-two",
                 display_name: "builder"
               })

      assert {:ok, %Profile{display_name: "builder"}} =
               Profile.ensure_agent_display_name(
                 Ezagent.URI.new!("entity://team-alpha/agent/one"),
                 "builder"
               )
    end

    test "rejects a canonical non-Agent URI before reading or writing a profile" do
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/not-an-agent")

      assert {:error, :not_agent_uri} =
               Profile.ensure_agent_display_name(user_uri, "builder")

      assert Profile.get(user_uri) == nil
    end

    test "bounds generated suffixes to the database display-name limit" do
      first = Ezagent.URI.new!("entity://team-alpha/agent/max-name-one")
      second = Ezagent.URI.new!("entity://team-alpha/agent/max-name-two")
      max_length_name = String.duplicate("a", 255)

      assert {:ok, %Profile{display_name: ^max_length_name}} =
               Profile.ensure_agent_display_name(first, max_length_name)

      assert {:ok, %Profile{display_name: suffixed}} =
               Profile.ensure_agent_display_name(second, max_length_name)

      assert String.length(suffixed) == 255
      assert String.ends_with?(suffixed, "-2")
    end

    test "returns a changeset error for a name longer than the database column" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/overlong")

      assert {:error, changeset} =
               Profile.ensure_agent_display_name(agent_uri, String.duplicate("a", 256))

      assert "should be at most 255 character(s)" in errors_on(changeset).display_name
      assert Profile.get(agent_uri) == nil
    end
  end

  test "an Agent profile does not prevent a User with the same display name" do
    agent_one = Ezagent.URI.new!("entity://team-alpha/agent/one")

    assert {:ok, %Profile{display_name: "builder"}} =
             Profile.ensure_agent_display_name(agent_one, "builder")

    assert {:ok, %Profile{display_name: "builder"}} =
             Profile.upsert(%{
               entity_uri: "entity://team-alpha/user/builder",
               display_name: "builder",
               email: "builder@example.com"
             })
  end

  test "upsert/1 returns a changeset error for a duplicate Agent display name" do
    {:ok, _} =
      Profile.ensure_agent_display_name(
        Ezagent.URI.new!("entity://team-alpha/agent/one"),
        "builder"
      )

    assert {:error, changeset} =
             Profile.upsert(%{
               entity_uri: "entity://team-alpha/agent/two",
               display_name: "builder"
             })

    assert "has already been taken" in errors_on(changeset).display_name
  end

  test "upsert/1 inserts then updates the same entity_uri" do
    {:ok, p1} = Profile.upsert(%{entity_uri: "entity://team-alpha/user/x", display_name: "X"})
    assert p1.display_name == "X"

    {:ok, p2} =
      Profile.upsert(%{entity_uri: "entity://team-alpha/user/x", display_name: "X Renamed"})

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
      Profile.upsert(%{
        entity_uri: "entity://team-alpha/user/a",
        display_name: "A",
        email: "dup@example.com"
      })

    assert {:error, changeset} =
             Profile.upsert(%{
               entity_uri: "entity://team-alpha/user/b",
               display_name: "B",
               email: "dup@example.com"
             })

    assert "has already been taken" in errors_on(changeset).email
  end

  test "get/1 and by_email/1 accept a %URI{} or string" do
    {:ok, _} =
      Profile.upsert(%{entity_uri: "entity://team-alpha/agent/echo", display_name: "Echo Bot"})

    assert Profile.get(Ezagent.URI.new!("entity://team-alpha/agent/echo")).display_name ==
             "Echo Bot"
  end

  # task #87 — email is the login account, so uniqueness must be
  # case-insensitive. upsert/1 lowercases on write, so we feed a mixed-case
  # email straight to the DB (bypassing normalize) to actually exercise the
  # lower(email) unique index (Codex plan-review #1).
  test "lower(email) unique index rejects a case-variant raw insert" do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://team-alpha/user/ci1",
        display_name: "CI1",
        email: "dup@ci.com"
      })

    raw = %Profile{
      entity_uri: "entity://team-alpha/user/ci2",
      display_name: "CI2",
      email: "DUP@ci.com",
      workspace_uri: "workspace://team-alpha"
    }

    # A raw struct insert (no declared unique_constraint) surfaces the DB
    # rejection as an Ecto.ConstraintError — proving the lower(email) index
    # caught the case-variant collision at the database level.
    assert_raise Ecto.ConstraintError, fn -> EzagentCore.Repo.insert(raw) end
  end
end
