defmodule Ezagent.EntityTest do
  @moduledoc """
  PR #142 — `Ezagent.Entity.authenticate/2` is the entity-agnostic
  facade for "verify this URI presented this secret and return its caps".

  Today (pre-PR-#142) the login path is bcrypt-only against the User
  table; the CLI bearer-token path is a separate User-table lookup.
  PR #142 unifies both behind a single `authenticate/2` that dispatches
  on URI shape:

  - `entity://<workspace>/user/<name>` + password → bcrypt path
  - `entity://<workspace>/agent/<name>` + token → entity_tokens table path
  - anything else → `{:error, {:unsupported_entity_uri, uri}}`

  These tests assume PR #141 has merged (entity:// scheme registered;
  admin URI is `entity://system/user/admin`).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity
  alias Ezagent.Users

  describe "authenticate/2 — user URI + password (bcrypt path)" do
    test "happy: known user + correct password → {:ok, %{caps: caps}}" do
      uri_str = "entity://team-alpha/user/auth-test-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])

      uri = Ezagent.URI.new!(uri_str)

      assert {:ok, %{caps: caps}} = Entity.authenticate(uri, "correct-password")
      assert %MapSet{} = caps
      # default_caps + whatever the test added (just default here)
      assert MapSet.size(caps) >= 1
    end

    test "wrong password → {:error, :invalid_credentials}" do
      uri_str = "entity://team-alpha/user/auth-wrong-pw-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])

      uri = Ezagent.URI.new!(uri_str)

      assert {:error, :invalid_credentials} = Entity.authenticate(uri, "wrong-password")
    end

    test "unknown user → {:error, :no_such_user}" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/never-existed-#{System.unique_integer([:positive])}"
        )

      assert {:error, :no_such_user} = Entity.authenticate(uri, "anything")
    end

    test "admin (canonical entity://system/user/admin) + admin password works" do
      # Reseed sets admin's password to a known value via mix task —
      # this test mints fresh here to avoid coupling.
      admin_uri_str = "entity://system/user/admin"

      case Users.get_by_uri(admin_uri_str) do
        nil -> {:ok, _} = Users.create(admin_uri_str, "test-admin-pw", [])
        _ -> Users.set_password(admin_uri_str, "test-admin-pw")
      end

      assert {:ok, %{caps: _caps}} =
               Entity.authenticate(Ezagent.URI.new!(admin_uri_str), "test-admin-pw")
    end
  end

  describe "authenticate/2 — agent URI + token (entity_tokens path)" do
    test "happy: agent + valid token → {:ok, %{caps: caps}}" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_auth-test-#{System.unique_integer([:positive])}"
        )

      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "test-token")

      assert {:ok, %{caps: caps}} = Entity.authenticate(uri, plain_token)
      assert %MapSet{} = caps
    end

    test "wrong token → {:error, :invalid_credentials}" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_wrong-token-#{System.unique_integer([:positive])}"
        )

      {_plain, _row} = Ezagent.Entity.Token.mint(uri, label: "real")

      assert {:error, :invalid_credentials} = Entity.authenticate(uri, "fake-token-string")
    end

    test "unknown agent (no tokens) → {:error, :no_such_entity}" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_never-#{System.unique_integer([:positive])}"
        )

      assert {:error, :no_such_entity} = Entity.authenticate(uri, "any-token")
    end
  end

  describe "authenticate/2 — unsupported entity URIs" do
    test "session URI rejected" do
      uri = Ezagent.URI.new!("session://system/default/main")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate(uri, "x")
    end

    test "workspace URI rejected" do
      uri = Ezagent.URI.new!("workspace://team-alpha")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate(uri, "x")
    end

    test "non-entity scheme rejected" do
      uri = Ezagent.URI.new!("system://routing/default")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate(uri, "x")
    end
  end

  describe "authenticate/3 — password-only mode (task #87 login form)" do
    test "allow_user_tokens:false rejects a bearer token but accepts the password" do
      uri_str = "entity://team-alpha/user/pwonly-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])
      uri = Ezagent.URI.new!(uri_str)
      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "cli")

      # token must NOT authenticate on the form path
      assert {:error, :invalid_credentials} =
               Entity.authenticate(uri, plain_token, allow_user_tokens: false)

      # password still works on the form path
      assert {:ok, %{caps: _}} =
               Entity.authenticate(uri, "correct-password", allow_user_tokens: false)
    end

    test "authenticate/2 still accepts a user bearer token (back-compat for CLI/API)" do
      uri_str = "entity://team-alpha/user/tokcompat-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "pw", [])
      uri = Ezagent.URI.new!(uri_str)
      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "cli")

      assert {:ok, %{caps: _}} = Entity.authenticate(uri, plain_token)
    end

    test "disabled users cannot authenticate with password or user bearer token" do
      uri_str = "entity://team-alpha/user/disabled-auth-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])
      uri = Ezagent.URI.new!(uri_str)
      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "cli")

      assert {:ok, %{caps: _}} = Entity.authenticate(uri, "correct-password")
      assert {:ok, %{caps: _}} = Entity.authenticate(uri, plain_token)

      assert {:ok, _} = Users.disable(uri, "entity://system/user/admin", "blocked")

      assert {:error, :disabled} = Entity.authenticate(uri, "correct-password")
      assert {:error, :disabled} = Entity.authenticate(uri, plain_token)

      assert {:error, :disabled} =
               Entity.authenticate(uri, "correct-password", allow_user_tokens: false)
    end
  end
end
