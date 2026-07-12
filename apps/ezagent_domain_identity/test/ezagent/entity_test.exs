defmodule Ezagent.EntityTest do
  @moduledoc """
  Password authentication is deliberately separate from bearer-token
  authentication. This module covers the PAT-independent human login path;
  `Ezagent.Authentication.authenticate/1` resolves versioned PAT principals.

  These tests assume PR #141 has merged (entity:// scheme registered;
  admin URI is `entity://system/user/admin`).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity
  alias Ezagent.Users

  describe "authenticate_password/2 — separate human password flow" do
    test "happy: known user + correct password → {:ok, %{caps: caps}}" do
      uri_str = "entity://team-alpha/user/auth-test-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])

      uri = Ezagent.URI.new!(uri_str)

      assert {:ok, %{caps: caps}} = Entity.authenticate_password(uri, "correct-password")
      assert %MapSet{} = caps
      # default_caps + whatever the test added (just default here)
      assert MapSet.size(caps) >= 1
    end

    test "wrong password → {:error, :invalid_credentials}" do
      uri_str = "entity://team-alpha/user/auth-wrong-pw-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])

      uri = Ezagent.URI.new!(uri_str)

      assert {:error, :invalid_credentials} = Entity.authenticate_password(uri, "wrong-password")
    end

    test "unknown user → {:error, :no_such_user}" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/never-existed-#{System.unique_integer([:positive])}"
        )

      assert {:error, :no_such_user} = Entity.authenticate_password(uri, "anything")
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
               Entity.authenticate_password(Ezagent.URI.new!(admin_uri_str), "test-admin-pw")
    end
  end

  describe "authenticate_password/2 — unsupported entity URIs" do
    test "session URI rejected" do
      uri = Ezagent.URI.new!("session://system/default/main")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate_password(uri, "x")
    end

    test "workspace URI rejected" do
      uri = Ezagent.URI.new!("workspace://team-alpha")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate_password(uri, "x")
    end

    test "non-entity scheme rejected" do
      uri = Ezagent.URI.new!("system://routing/default")
      assert {:error, {:unsupported_entity_uri, ^uri}} = Entity.authenticate_password(uri, "x")
    end
  end

  describe "password flow never accepts a PAT" do
    test "rejects a bearer token but accepts the password" do
      uri_str = "entity://team-alpha/user/pwonly-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])
      uri = Ezagent.URI.new!(uri_str)
      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "cli")

      # token must NOT authenticate on the form path
      assert {:error, :invalid_credentials} =
               Entity.authenticate_password(uri, plain_token)

      # password still works on the form path
      assert {:ok, %{caps: _}} =
               Entity.authenticate_password(uri, "correct-password")
    end

    test "disabled users cannot authenticate with password or user bearer token" do
      uri_str = "entity://team-alpha/user/disabled-auth-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri_str, "correct-password", [])
      uri = Ezagent.URI.new!(uri_str)
      {plain_token, _row} = Ezagent.Entity.Token.mint(uri, label: "cli")

      assert {:ok, %{caps: _}} = Entity.authenticate_password(uri, "correct-password")
      assert {:error, :invalid_credentials} = Entity.authenticate_password(uri, plain_token)

      assert {:ok, _} = Users.disable(uri, "entity://system/user/admin", "blocked")

      assert {:error, :disabled} = Entity.authenticate_password(uri, "correct-password")
      assert {:error, :disabled} = Entity.authenticate_password(uri, plain_token)
    end
  end
end
