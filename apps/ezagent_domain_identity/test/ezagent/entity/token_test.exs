defmodule Ezagent.Entity.TokenTest do
  @moduledoc """
  PR #142 — `Ezagent.Entity.Token` manages bearer tokens for any
  Entity URI. Replaces the User-table-only `cli_token` field.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Token

  describe "mint/2" do
    test "returns {plain_token, %EntityToken{}} for a valid entity URI" do
      uri = URI.parse("entity://agent/team-alpha/cc_mint-#{System.unique_integer([:positive])}")

      assert {plain, row} = Token.mint(uri, label: "test")
      assert is_binary(plain)
      assert byte_size(plain) >= 32
      assert row.entity_uri == URI.to_string(uri)
      assert row.label == "test"
      assert row.token_hash != plain
      assert is_binary(row.token_hash)
    end

    test "mint for a user URI also works" do
      uri = URI.parse("entity://user/team-alpha/token-#{System.unique_integer([:positive])}")
      assert {_plain, row} = Token.mint(uri)
      assert row.entity_uri == URI.to_string(uri)
    end

    test "multiple mints for same entity URI produce different tokens" do
      uri = URI.parse("entity://agent/team-alpha/cc_multi-#{System.unique_integer([:positive])}")
      assert {plain1, _} = Token.mint(uri, label: "first")
      assert {plain2, _} = Token.mint(uri, label: "second")
      refute plain1 == plain2
    end

    test "rejects non-entity URIs" do
      assert {:error, _} = Token.mint(URI.parse("session://default/system/main"))
    end
  end

  describe "verify/2" do
    test "minted token verifies + returns {:ok, %{caps: caps}}" do
      uri = URI.parse("entity://agent/team-alpha/cc_verify-#{System.unique_integer([:positive])}")
      {plain, _} = Token.mint(uri)

      assert {:ok, %{caps: caps}} = Token.verify(uri, plain)
      assert %MapSet{} = caps
    end

    test "wrong token → {:error, :invalid_credentials}" do
      uri = URI.parse("entity://agent/team-alpha/cc_v2-#{System.unique_integer([:positive])}")
      {_plain, _} = Token.mint(uri)

      assert {:error, :invalid_credentials} = Token.verify(uri, "fake-token-string")
    end

    test "no tokens for entity → {:error, :no_such_entity}" do
      uri = URI.parse("entity://agent/team-alpha/cc_v3-#{System.unique_integer([:positive])}")
      assert {:error, :no_such_entity} = Token.verify(uri, "anything")
    end

    test "verify on wrong URI even with right plain string → {:error, :invalid_credentials}" do
      uri_a = URI.parse("entity://agent/team-alpha/cc_va-#{System.unique_integer([:positive])}")
      uri_b = URI.parse("entity://agent/team-alpha/cc_vb-#{System.unique_integer([:positive])}")
      {plain_a, _} = Token.mint(uri_a)

      # Try using A's token against B
      assert {:error, _} = Token.verify(uri_b, plain_a)
    end

    test "verify updates last_used_at" do
      uri = URI.parse("entity://agent/team-alpha/cc_lu-#{System.unique_integer([:positive])}")
      {plain, row} = Token.mint(uri)
      assert row.last_used_at == nil

      {:ok, _} = Token.verify(uri, plain)

      [row2] = Token.list(uri)
      refute row2.last_used_at == nil
    end
  end

  describe "list/1" do
    test "returns rows for entity, sorted by created_at desc" do
      uri = URI.parse("entity://agent/team-alpha/cc_list-#{System.unique_integer([:positive])}")
      {_, _r1} = Token.mint(uri, label: "first")
      Process.sleep(10)
      {_, _r2} = Token.mint(uri, label: "second")

      rows = Token.list(uri)
      assert length(rows) == 2
      assert hd(rows).label == "second"
    end

    test "returns [] for entity with no tokens" do
      uri = URI.parse("entity://agent/team-alpha/cc_empty-#{System.unique_integer([:positive])}")
      assert Token.list(uri) == []
    end
  end

  describe "revoke/1" do
    test "revoked token no longer verifies" do
      uri = URI.parse("entity://agent/team-alpha/cc_revoke-#{System.unique_integer([:positive])}")
      {plain, row} = Token.mint(uri)

      assert {:ok, _} = Token.verify(uri, plain)
      :ok = Token.revoke(row.id)
      assert {:error, _} = Token.verify(uri, plain)
    end
  end
end
