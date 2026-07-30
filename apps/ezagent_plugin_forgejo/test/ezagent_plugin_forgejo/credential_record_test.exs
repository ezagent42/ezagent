defmodule EzagentPluginForgejo.CredentialRecordTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias EzagentCore.Repo
  alias EzagentPluginForgejo.CredentialRecord

  @ws "workspace://acme"
  @credential Jason.encode!(%{"access_token" => "at-1", "refresh_token" => "rt-1"})

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a stored credential reads back exactly" do
    assert {:ok, %{credential_ref: ref, credential_version: 1}} =
             CredentialRecord.insert(@ws, @credential)

    assert {:ok, @credential} = CredentialRecord.fetch_credential(@ws, ref)
  end

  test "two inserts yield distinct refs" do
    {:ok, %{credential_ref: a}} = CredentialRecord.insert(@ws, @credential)
    {:ok, %{credential_ref: b}} = CredentialRecord.insert(@ws, @credential)
    refute a == b
  end

  # The whole reason this table exists. If it regresses, a credential sits in
  # plaintext in Postgres.
  test "the credential is not readable from the stored row" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    %{ciphertext: ciphertext, nonce: nonce, key_id: key_id} =
      Repo.get!(CredentialRecord, ref)

    stored = :erlang.term_to_binary({ciphertext, nonce, key_id})

    refute stored =~ "at-1"
    refute stored =~ "rt-1"
  end

  test "the row records the sealing key so rotation can open it later" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    %{key_id: key_id, key_fingerprint: fingerprint} = Repo.get!(CredentialRecord, ref)

    assert is_binary(key_id) and key_id != ""
    assert is_binary(fingerprint)
  end

  test "the row carries the workspace it belongs to" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert %{workspace_uri: @ws} = Repo.get!(CredentialRecord, ref)
  end

  test "replace with the expected version bumps it and rewrites the credential" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)
    rotated = Jason.encode!(%{"access_token" => "at-2", "refresh_token" => "rt-2"})

    assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
             CredentialRecord.replace(@ws, ref, rotated, 1)

    assert {:ok, ^rotated} = CredentialRecord.fetch_credential(@ws, ref)
  end

  test "replace with a stale version is refused and leaves the credential intact" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:error, :stale_version} = CredentialRecord.replace(@ws, ref, "should-not-land", 7)
    assert {:ok, @credential} = CredentialRecord.fetch_credential(@ws, ref)
  end

  test "replacing an unknown ref is a conflict" do
    assert {:error, :credential_conflict} = CredentialRecord.replace(@ws, "nope", "x", 1)
  end

  test "version reports the current version, and conflicts for an unknown ref" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:ok, 1} = CredentialRecord.version(ref)
    assert {:error, :credential_conflict} = CredentialRecord.version("nope")
  end

  test "a deleted credential can no longer be fetched" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert :ok = CredentialRecord.delete(ref)
    assert {:error, :credential_conflict} = CredentialRecord.fetch_credential(@ws, ref)
  end

  test "deleting twice stays ok" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)
    assert :ok = CredentialRecord.delete(ref)
    assert :ok = CredentialRecord.delete(ref)
  end

  # The table declares itself per-tenant (registered in
  # `PerTenantTablesHaveWorkspaceColumnTest`, whose contract is "a cross-tenant
  # read is a miss rather than a leak"). A `workspace_uri` column that no query
  # consults does not deliver that -- it is decoration. These pin the boundary.
  test "another workspace cannot read this credential" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:error, :credential_conflict} =
             CredentialRecord.fetch_credential("workspace://other", ref)

    assert {:ok, @credential} = CredentialRecord.fetch_credential(@ws, ref)
  end

  test "another workspace cannot replace this credential" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:error, :credential_conflict} =
             CredentialRecord.replace("workspace://other", ref, "stolen", 1)

    assert {:ok, @credential} = CredentialRecord.fetch_credential(@ws, ref)
  end

  # AAD binds a ciphertext to its row. Without this, a sealed credential copied
  # into another row would open there.
  test "a ciphertext moved to another row does not open" do
    {:ok, %{credential_ref: a}} = CredentialRecord.insert(@ws, @credential)
    {:ok, %{credential_ref: b}} = CredentialRecord.insert(@ws, "other-credential")

    %{key_id: key_id, key_fingerprint: fingerprint, nonce: nonce, ciphertext: ciphertext} =
      Repo.get!(CredentialRecord, a)

    Repo.update_all(
      from(r in CredentialRecord, where: r.credential_ref == ^b),
      set: [
        key_id: key_id,
        key_fingerprint: fingerprint,
        nonce: nonce,
        ciphertext: ciphertext
      ]
    )

    assert {:error, :authentication_failed} = CredentialRecord.fetch_credential(@ws, b)
  end
end
