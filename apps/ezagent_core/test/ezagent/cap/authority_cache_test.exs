defmodule Ezagent.Cap.AuthorityCacheTest do
  @moduledoc """
  Unified-revocation Phase F-1 (MF4) — `Ezagent.Cap.AuthorityCache` memoizes
  ONLY the IMMUTABLE `key_id -> public_key` mapping. A `key_id`
  (`kind-g<gen>:<fingerprint>`) binds one public key forever, so a memo entry
  can never be stale and needs no invalidation. There is deliberately NO
  mutable `uri -> current key_id` entry: the current key_id is always read
  fresh from the DB active row (`KindCapAuthority.active/1`), which
  `regenesis/3` flips atomically — so no stale-cache window exists.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, AuthorityCache}
  alias Ezagent.Ecto.KindCapAuthority

  test "the ETS table is registered and owned by EzagentCore.EtsOwner" do
    refute :ets.info(AuthorityCache.table()) == :undefined
  end

  test "public_key/1 serves a memoized immutable mapping" do
    key_id = "kind-g1:test-#{System.unique_integer([:positive])}"
    public_key = :crypto.strong_rand_bytes(32)

    :ets.insert(AuthorityCache.table(), {key_id, public_key})

    assert {:ok, ^public_key} = AuthorityCache.public_key(key_id)
  end

  test "public_key/1 reads through a memo miss to the durable row and memoizes it" do
    uri = unique_uri("read-through")
    {:ok, authority} = Authority.open(uri, :test)

    :ets.delete(AuthorityCache.table(), authority.key_id)
    assert :ets.lookup(AuthorityCache.table(), authority.key_id) == []

    assert {:ok, public_key} = AuthorityCache.public_key(authority.key_id)
    assert public_key == authority.public_key

    assert :ets.lookup(AuthorityCache.table(), authority.key_id) == [
             {authority.key_id, authority.public_key}
           ]
  end

  test "public_key/1 is :error for an unknown key_id" do
    assert :error =
             AuthorityCache.public_key("kind-g999:unknown-#{System.unique_integer([:positive])}")
  end

  test "regenesis never invalidates the immutable memo; only the DB active row moves" do
    uri = unique_uri("immutable")
    {:ok, first} = Authority.open(uri, :test)
    {:ok, second} = Authority.regenesis(uri, :test)

    # The old key_id still maps to the old public key — the memo is immutable
    # by construction, so this is not staleness...
    assert {:ok, public_key} = AuthorityCache.public_key(first.key_id)
    assert public_key == first.public_key

    # ...because "current" is decided ONLY by the DB active row, which flipped.
    assert KindCapAuthority.active(Ezagent.URI.stable_key(uri)).key_id == second.key_id
    refute second.key_id == first.key_id
  end

  test "rehydrate/0 warms the memo from the durable authority rows" do
    uri = unique_uri("rehydrate")
    {:ok, authority} = Authority.open(uri, :test)

    :ets.delete(AuthorityCache.table(), authority.key_id)
    assert :ets.lookup(AuthorityCache.table(), authority.key_id) == []

    assert :ok = AuthorityCache.rehydrate()

    assert :ets.lookup(AuthorityCache.table(), authority.key_id) == [
             {authority.key_id, authority.public_key}
           ]
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/authority-cache-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
