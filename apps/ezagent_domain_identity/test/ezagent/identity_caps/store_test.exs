defmodule Ezagent.IdentityCaps.StoreTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Cap.{Delivery, RevocationLedger}
  alias Ezagent.Capability
  alias Ezagent.IdentityCaps.Store
  alias EzagentCore.Repo

  @workspace URI.new!("workspace://identity-caps-store")
  @issuer URI.new!("entity://identity-caps-store/user/issuer")

  setup do
    Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
    end)

    :ok
  end

  test "persist/load is the complete durable authority" do
    holder = agent_uri("roundtrip")
    grant = issued_cap(holder, :send)
    caps = licensed_caps(holder, [grant])

    assert :ok = Store.persist(holder, caps)
    assert Store.status(holder) == :active
    assert identity_keys(Store.load(holder)) == identity_keys(caps)
    assert {:ok, durable} = Store.fetch_durable_caps(holder)
    assert identity_keys(durable) == identity_keys(caps)
  end

  test "genesis initialization remains staged across target authority setup and preserves grants on activation" do
    holder = agent_uri("genesis")
    grant = issued_cap(holder, :send)

    refute Ezagent.Cap.Authority.has_authority_history?(holder)
    assert :ok = Store.initialize(holder, [grant])
    assert Store.status(holder) == :staged
    assert {:ok, [^grant]} = Store.load_initial(holder)
    assert {:ok, []} = Store.fetch_durable_caps(holder)
    assert {:error, :identity_caps_already_initialized} = Store.initialize(holder, [])

    license = self_license(holder)
    assert Ezagent.Cap.Authority.has_authority_history?(holder)
    assert {:ok, [^grant]} = Store.load_initial(holder)

    assert :ok = Store.provision_created_identity(holder, %{caps: MapSet.new([license])})
    assert Store.status(holder) == :active
    assert identity_keys(Store.load(holder)) == identity_keys([license, grant])
  end

  test "missing and corrupt rows are explicit read failures" do
    missing = agent_uri("missing")
    assert {:error, :identity_caps_missing} = Store.fetch_durable_caps(missing)

    corrupt = agent_uri("corrupt")
    assert :ok = Store.persist(corrupt, licensed_caps(corrupt, []))

    from(row in Store, where: row.uri == ^Ezagent.URI.stable_key(corrupt))
    |> Repo.update_all(set: [caps_json: "null"])

    assert {:error, :invalid_caps_json} = Store.fetch_durable_caps(corrupt)
  end

  test "a revoked artifact makes the whole carrier unreadable" do
    holder = agent_uri("revoked-carrier")
    grant = issued_cap(holder, :send)
    assert :ok = Store.persist(holder, licensed_caps(holder, [grant]))
    assert :ok = mark_revoked(holder, grant)

    assert {:error, {:revoked_capability_grants, [grant_id]}} =
             Store.fetch_durable_caps(holder)

    assert grant_id == grant.grant_id
  end

  test "revoke resolves the trusted stored artifact and ignores caller grant metadata" do
    holder = agent_uri("stored-revoke")
    stored = issued_cap(holder, :send)
    assert :ok = Store.persist(holder, licensed_caps(holder, [stored]))
    assert :ok = Ezagent.Identity.absorb_cap(holder, stored)

    pending =
      Repo.one!(
        from(delivery in Delivery,
          where: delivery.grant_id == ^stored.grant_id and delivery.status == :pending
        )
      )

    attacker_id = Ecto.UUID.generate()
    caller = %{stored | grant_id: attacker_id, signature: :crypto.strong_rand_bytes(64)}

    assert {:ok, resolved} = Store.revoke_cap(holder, caller)
    assert resolved.grant_id == stored.grant_id
    refute cap_present?(Store.load(holder), stored)

    assert {:ok, revoked} =
             RevocationLedger.revoked_grant_ids(@workspace, [stored.grant_id, attacker_id])

    assert revoked == MapSet.new([stored.grant_id])
    assert Repo.get(Delivery, pending.id) == nil
  end

  test "an absent-row revoke accepts only an exact current artifact for this holder" do
    holder = agent_uri("exact-absent")
    exact = issued_cap(holder, :send)
    wrong_holder = agent_uri("wrong-holder")

    assert {:error, :invalid_exact_revocation_artifact} =
             Store.revoke_cap(wrong_holder, exact)

    assert {:ok, ^exact} = Store.revoke_cap(holder, exact)
    assert {:ok, ids} = RevocationLedger.revoked_grant_ids(@workspace, [exact.grant_id])
    assert ids == MapSet.new([exact.grant_id])
  end

  test "a fresh re-grant of the same logical permission remains effective" do
    holder = agent_uri("regrant")
    original = issued_cap(holder, :send)
    assert :ok = Store.persist(holder, licensed_caps(holder, [original]))
    assert {:ok, ^original} = Store.revoke_cap(holder, original)

    regrant = issued_cap(holder, :send)
    refute regrant.grant_id == original.grant_id
    assert :ok = Store.persist(holder, licensed_caps(holder, [regrant]))
    assert cap_present?(Store.load(holder), regrant)
  end

  test "all cap-set writers reject revoked artifacts" do
    holder = agent_uri("writer-gate")
    revoked = issued_cap(holder, :send)
    assert :ok = mark_revoked(holder, revoked)

    assert {:error, {:revoked_capability_grants, [revoked_id]}} =
             Store.persist(holder, licensed_caps(holder, [revoked]))

    assert revoked_id == revoked.grant_id

    assert {:error, {:revoked_capability_grants, [^revoked_id]}} =
             Store.initialize(holder, [revoked])
  end

  test "tombstones remain terminal under ordinary persistence" do
    holder = agent_uri("tombstone")
    caps = licensed_caps(holder, [issued_cap(holder, :send)])
    assert :ok = Store.persist(holder, caps)
    assert :ok = Store.tombstone(holder)
    assert :ok = Store.persist(holder, caps)
    assert Store.status(holder) == :tombstoned
    assert Store.load(holder) == []
  end

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://identity-caps-store/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now(),
      grant_id: Ecto.UUID.generate()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp licensed_caps(receiver, caps), do: [self_license(receiver) | caps]

  defp self_license(receiver) do
    {:ok, type} = Ezagent.URI.type(receiver)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Ezagent.Cap.Authority.open(receiver, kind)

    requested =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Identity,
        :self_license,
        receiver,
        Ezagent.URI.workspace_of(receiver)
      )

    intent = Ezagent.Cap.Grant.freeze(receiver, receiver, receiver, requested)

    Ezagent.Cap.Authority.with_current(authority, fn ->
      {:ok, license} = Ezagent.Cap.Authority.issue_self_license_current(intent)
      license
    end)
  end

  defp mark_revoked(holder, cap) do
    attrs = %{
      grant_id: cap.grant_id,
      workspace_uri: holder |> Ezagent.URI.workspace_of() |> Ezagent.URI.stable_key(),
      holder_uri: Ezagent.URI.stable_key(holder),
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(cap))),
      revoked_at: DateTime.utc_now(),
      target_uri: Ezagent.URI.stable_key(cap.instance),
      key_id: cap.key_id
    }

    case RevocationLedger.mark(attrs) do
      {:ok, _marker} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_uri(suffix) do
    URI.new!("entity://identity-caps-store/agent/#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp identity_keys(caps), do: caps |> Enum.map(&Capability.identity_key/1) |> MapSet.new()
  defp cap_present?(caps, cap), do: Capability.identity_key(cap) in identity_keys(caps)
end
