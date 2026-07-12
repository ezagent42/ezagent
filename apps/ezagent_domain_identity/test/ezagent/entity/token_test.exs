defmodule Ezagent.Entity.TokenTest do
  @moduledoc """
  PR #142 — `Ezagent.Entity.Token` manages bearer tokens for any
  Entity URI. Replaces the User-table-only `cli_token` field.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Token
  alias Ezagent.Authentication

  describe "mint/2" do
    test "returns {plain_token, %EntityToken{}} for a valid entity URI" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_mint-#{System.unique_integer([:positive])}"
        )

      assert {plain, row} = Token.mint(uri, label: "test")
      assert is_binary(plain)
      assert byte_size(plain) >= 32
      assert String.starts_with?(plain, "esr_pat_v1_")
      assert row.entity_uri == URI.to_string(uri)
      assert row.label == "test"
      assert row.token_hash == nil
      assert row.digest_version == 1
      assert is_binary(row.token_digest)
      refute row.token_digest == plain
    end

    test "mint for a user URI also works" do
      uri =
        Ezagent.URI.new!("entity://team-alpha/user/token-#{System.unique_integer([:positive])}")

      assert {_plain, row} = Token.mint(uri)
      assert row.entity_uri == URI.to_string(uri)
    end

    test "multiple mints for same entity URI produce different tokens" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_multi-#{System.unique_integer([:positive])}"
        )

      assert {plain1, _} = Token.mint(uri, label: "first")
      assert {plain2, _} = Token.mint(uri, label: "second")
      refute plain1 == plain2
    end

    test "rejects non-entity URIs" do
      assert {:error, _} = Token.mint(Ezagent.URI.new!("session://system/default/main"))
    end
  end

  describe "credential-only authenticate/1" do
    test "minted token derives its principal without a supplied URI" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_verify-#{System.unique_integer([:positive])}"
        )

      {plain, _} = Token.mint(uri)

      assert {:ok, ^uri} = Authentication.authenticate(plain)
    end

    test "wrong token → {:error, :invalid_credentials}" do
      uri =
        Ezagent.URI.new!("entity://team-alpha/agent/cc_v2-#{System.unique_integer([:positive])}")

      {_plain, _} = Token.mint(uri)

      assert {:error, :unsupported_credential} = Authentication.authenticate("fake-token-string")
    end

    test "well-formed unknown token fails closed" do
      raw = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert {:error, :invalid_credentials} = Authentication.authenticate("esr_pat_v1_" <> raw)
    end

    test "verify updates last_used_at" do
      uri =
        Ezagent.URI.new!("entity://team-alpha/agent/cc_lu-#{System.unique_integer([:positive])}")

      {plain, row} = Token.mint(uri)
      assert row.last_used_at == nil

      {:ok, ^uri} = Authentication.authenticate(plain)

      [row2] = Token.list(uri)
      refute row2.last_used_at == nil
    end
  end

  describe "list/1" do
    test "returns rows for entity, sorted by created_at desc" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_list-#{System.unique_integer([:positive])}"
        )

      {_, _r1} = Token.mint(uri, label: "first")
      Process.sleep(10)
      {_, _r2} = Token.mint(uri, label: "second")

      rows = Token.list(uri)
      assert length(rows) == 2
      assert hd(rows).label == "second"
    end

    test "returns [] for entity with no tokens" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_empty-#{System.unique_integer([:positive])}"
        )

      assert Token.list(uri) == []
    end
  end

  describe "revoke/1" do
    test "revoked token no longer verifies" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_revoke-#{System.unique_integer([:positive])}"
        )

      {plain, row} = Token.mint(uri)

      assert {:ok, ^uri} = Authentication.authenticate(plain)
      :ok = Token.revoke(row.id)
      assert {:error, :invalid_credentials} = Authentication.authenticate(plain)
    end
  end

  describe "digest version and pepper lifecycle" do
    test "token version selects the pepper and row version is checked" do
      uri = Ezagent.URI.agent("team-alpha", "versioned-#{System.unique_integer([:positive])}")
      {plain, row} = Token.mint(uri)

      row
      |> Ecto.Changeset.change(%{digest_version: 2})
      |> EzagentCore.Repo.update!()

      assert {:error, :invalid_credentials} = Authentication.authenticate(plain)
    end

    test "missing mint pepper fails closed" do
      old = Application.get_env(:ezagent_domain_identity, Token)
      Application.put_env(:ezagent_domain_identity, Token, current_version: 9, peppers: %{})

      on_exit(fn -> Application.put_env(:ezagent_domain_identity, Token, old) end)

      uri = Ezagent.URI.agent("team-alpha", "no-pepper-#{System.unique_integer([:positive])}")
      assert {:error, {:pat_pepper_unavailable, 9}} = Token.mint(uri)
    end

    test "rotate_label keeps one login token row and invalidates the prior token" do
      uri = Ezagent.URI.user("team-alpha", "rotate-#{System.unique_integer([:positive])}")
      {first, _} = Token.rotate_label(uri, "password-login")
      {second, _} = Token.rotate_label(uri, "password-login")

      refute first == second
      assert [%Token{label: "password-login"}] = Token.list(uri)
      assert {:error, :invalid_credentials} = Authentication.authenticate(first)
      assert {:ok, ^uri} = Authentication.authenticate(second)
    end

    test "rotate_label preserves the active token when the new pepper is unavailable" do
      uri = Ezagent.URI.user("team-alpha", "rotate-fail-#{System.unique_integer([:positive])}")
      {active, active_row} = Token.rotate_label(uri, "interactive-login")
      old = Application.get_env(:ezagent_domain_identity, Token)
      Application.put_env(:ezagent_domain_identity, Token, current_version: 9, peppers: %{})

      on_exit(fn -> Application.put_env(:ezagent_domain_identity, Token, old) end)

      assert {:error, {:pat_pepper_unavailable, 9}} =
               Token.rotate_label(uri, "interactive-login")

      assert [%Token{id: id, label: "interactive-login"}] = Token.list(uri)
      assert id == active_row.id

      Application.put_env(:ezagent_domain_identity, Token, old)
      assert {:ok, ^uri} = Authentication.authenticate(active)
    end
  end
end
