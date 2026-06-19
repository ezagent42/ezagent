defmodule Ezagent.UsersTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Users

  describe "create/3" do
    # PR-甲-2 (Allen 2026-06-19, #154): `Users.create` still prepends
    # `Ezagent.Entity.User.default_caps()`, but that is now `[]` (the broad
    # session baseline is removed — participation is granted per-session at
    # join, owner-rooted). So an empty-caller-caps create yields a user with
    # NO standing caps; a custom-caps create round-trips exactly the supplied
    # caps with nothing added.

    test "empty caller caps → user starts with NO standing caps (default_caps is [])" do
      uri = "entity://team-alpha/user/test-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, "secret", [])

      assert URI.to_string(decoded.uri) == uri
      assert is_binary(decoded.password_hash)
      assert decoded.password_hash != "secret"

      default = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-alpha"))
      assert default == []
      assert length(decoded.caps) == length(default)

      refute Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end),
             "PR-甲-2: no broad session baseline is installed at create"
    end

    test "nil password leaves password_hash nil" do
      uri = "entity://team-alpha/user/nopw-#{System.unique_integer([:positive])}"

      {:ok, decoded} = Users.create(uri, nil, [])
      assert decoded.password_hash == nil
    end

    test "caller caps round-trip through JSON (no session baseline added — #154 甲-2)" do
      uri = "entity://team-alpha/user/caps-#{System.unique_integer([:positive])}"

      cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        instance: :any,
        # Phase 9 PR-3 (SPEC v3 §4): caps are now workspace-scoped.
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-16 00:00:00.000000Z]
      }

      {:ok, decoded} = Users.create(uri, "x", [cap])

      assert Enum.any?(decoded.caps, fn c ->
               c.kind == :workspace and c.behavior == Ezagent.Behavior.Workspace
             end)

      # PR-甲-2: default_caps is [], so the ONLY cap is the caller-supplied one
      # — no broad session baseline is prepended.
      refute Enum.any?(decoded.caps, fn c ->
               c.kind == :session and c.behavior == :any
             end),
             "no session baseline should be added to the caller's caps"

      assert length(decoded.caps) == 1, "exactly the one caller-supplied cap"
    end

    test "duplicate uri returns error" do
      uri = "entity://team-alpha/user/dup-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])
      assert {:error, _changeset} = Users.create(uri, "y", [])
    end
  end

  describe "verify_password/2" do
    test "true for correct password" do
      uri = "entity://team-alpha/user/verify-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      assert Users.verify_password(uri, "right-pw")
    end

    test "false for wrong password" do
      uri = "entity://team-alpha/user/wrong-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "right-pw", [])

      refute Users.verify_password(uri, "WRONG")
    end

    test "false for nonexistent user (no timing leak)" do
      refute Users.verify_password("entity://team-alpha/user/does-not-exist", "anything")
    end

    test "false for user with NULL password_hash (must set_password first)" do
      uri = "entity://team-alpha/user/nopw-vp-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])

      refute Users.verify_password(uri, "anything")
    end
  end

  describe "set_password/2" do
    test "updates an existing user's hash" do
      uri = "entity://team-alpha/user/setpw-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "old", [])

      assert {:ok, _} = Users.set_password(uri, "new")
      refute Users.verify_password(uri, "old")
      assert Users.verify_password(uri, "new")
    end

    test "set_password on NULL-hash row enables login" do
      uri = "entity://team-alpha/user/enable-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, nil, [])
      refute Users.verify_password(uri, "anything")

      {:ok, _} = Users.set_password(uri, "now-set")
      assert Users.verify_password(uri, "now-set")
    end

    test "returns :not_found for unknown uri" do
      assert {:error, :not_found} =
               Users.set_password("entity://team-alpha/user/never-existed-#{System.unique_integer()}", "x")
    end
  end

  describe "list_all/0 + get_by_uri/1" do
    test "lists every row + lookup roundtrip" do
      uri = "entity://team-alpha/user/list-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "x", [])

      uris = Users.list_all() |> Enum.map(fn d -> URI.to_string(d.uri) end)
      assert uri in uris

      assert %{uri: %URI{}} = Users.get_by_uri(uri)
    end

    test "get_by_uri returns nil for unknown" do
      assert nil ==
               Users.get_by_uri("entity://team-alpha/user/no-such-#{System.unique_integer([:positive])}")
    end
  end
end
