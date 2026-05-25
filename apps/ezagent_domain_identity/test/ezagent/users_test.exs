defmodule Ezagent.UsersTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Users

  describe "create/3" do
    # PR 27 (Allen 2026-05-18): Users.create prepends
    # `Ezagent.Entity.User.default_caps()` so every new user has a baseline
    # set (session.chat today) and creation sites don't have to remember
    # the boilerplate. These tests cover both the empty-caller-caps and
    # custom-caller-caps shapes.

    test "empty caller caps → user still has default_caps installed" do
      uri = "entity://user/team-alpha/test-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, "secret", [])

      assert URI.to_string(decoded.uri) == uri
      assert is_binary(decoded.password_hash)
      assert decoded.password_hash != "secret"

      default = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-alpha"))
      assert length(decoded.caps) == length(default)

      assert Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end)
    end

    test "nil password leaves password_hash nil" do
      uri = "entity://user/team-alpha/nopw-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, nil, [])
      assert decoded.password_hash == nil
    end

    test "caller caps + default_caps both round-trip through JSON" do
      uri = "entity://user/team-alpha/caps-#{System.unique_integer([:positive])}"

      cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        instance: :any,
        # Phase 9 PR-3 (SPEC v3 §4): caps are now workspace-scoped.
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: ~U[2026-05-16 00:00:00.000000Z]
      }

      {:ok, decoded} = Users.create(uri, "x", [cap])

      assert Enum.any?(decoded.caps, fn c ->
               c.kind == :workspace and c.behavior == Ezagent.Behavior.Workspace
             end)

      assert Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end)
    end

    test "duplicate uri returns error" do
      uri = "entity://user/team-alpha/dup-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])
      assert {:error, _changeset} = Users.create(uri, "y", [])
    end
  end

  describe "verify_password/2" do
    test "true for correct password" do
      uri = "entity://user/team-alpha/verify-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      assert Users.verify_password(uri, "right-pw")
    end

    test "false for wrong password" do
      uri = "entity://user/team-alpha/wrong-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      refute Users.verify_password(uri, "WRONG")
    end

    test "false for nonexistent user (no timing leak)" do
      refute Users.verify_password("entity://user/team-alpha/does-not-exist", "anything")
    end

    test "false for user with NULL password_hash (must set_password first)" do
      uri = "entity://user/team-alpha/nopw-vp-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])

      refute Users.verify_password(uri, "anything")
    end
  end

  describe "set_password/2" do
    test "updates an existing user's hash" do
      uri = "entity://user/team-alpha/setpw-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "old", [])

      assert {:ok, _} = Users.set_password(uri, "new")
      refute Users.verify_password(uri, "old")
      assert Users.verify_password(uri, "new")
    end

    test "set_password on NULL-hash row enables login" do
      uri = "entity://user/team-alpha/enable-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])
      refute Users.verify_password(uri, "anything")

      {:ok, _} = Users.set_password(uri, "now-set")
      assert Users.verify_password(uri, "now-set")
    end

    test "returns :not_found for unknown uri" do
      assert {:error, :not_found} =
               Users.set_password("entity://user/team-alpha/never-existed-#{System.unique_integer()}", "x")
    end
  end

  describe "list_all/0 + get_by_uri/1" do
    test "lists every row + lookup roundtrip" do
      uri = "entity://user/team-alpha/list-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])

      uris = Users.list_all() |> Enum.map(fn d -> URI.to_string(d.uri) end)
      assert uri in uris

      assert %{uri: %URI{}} = Users.get_by_uri(uri)
    end

    test "get_by_uri returns nil for unknown" do
      assert nil ==
               Users.get_by_uri("entity://user/team-alpha/no-such-#{System.unique_integer([:positive])}")
    end
  end
end
