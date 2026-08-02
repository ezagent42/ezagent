defmodule Ezagent.Cap.RevocationLedgerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.RevocationLedger
  alias Ezagent.Cap.Delivery
  alias Ezagent.Ecto.CapRevocation

  @workspace Ezagent.URI.new!("workspace://revocation-ledger")
  @other_workspace Ezagent.URI.new!("workspace://other-ledger")

  setup do
    Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
    end)

    :ok
  end

  test "markers are idempotent, absorbing, and workspace scoped" do
    grant_id = Ecto.UUID.generate()
    live_grant_id = Ecto.UUID.generate()
    attrs = marker_attrs(grant_id)

    assert {:ok, first} = RevocationLedger.mark(attrs)
    assert {:ok, repeated} = RevocationLedger.mark(%{attrs | target_uri: "changed-audit"})
    assert repeated.grant_id == first.grant_id
    assert repeated.target_uri == first.target_uri

    assert {:ok, revoked} =
             RevocationLedger.revoked_grant_ids(@workspace, [grant_id, live_grant_id])

    assert revoked == MapSet.new([grant_id])

    assert {:ok, other_workspace_revoked} =
             RevocationLedger.revoked_grant_ids(@other_workspace, [grant_id])

    assert other_workspace_revoked == MapSet.new()
  end

  test "empty grant-id batches avoid a database query and return empty" do
    assert {:ok, revoked} = RevocationLedger.revoked_grant_ids(@workspace, [])
    assert revoked == MapSet.new()
  end

  test "a ledger read failure stays distinct so authorization callers can deny" do
    Application.put_env(:ezagent_core, :cap_revocation_ledger_force_read_error, true)

    assert {:error, :forced_ledger_read_error} =
             RevocationLedger.revoked_grant_ids(@workspace, [Ecto.UUID.generate()])
  end

  test "ledger APIs reject noncanonical grant identities before querying" do
    canonical = Ecto.UUID.generate()

    assert {:error, :invalid_grant_id} = RevocationLedger.mark(marker_attrs("not-a-uuid"))

    assert {:error, :invalid_grant_id} =
             RevocationLedger.revoked_grant_ids(@workspace, [String.upcase(canonical)])

    assert {:error, :invalid_grant_id} =
             RevocationLedger.revoked_grant_ids(@workspace, ["not-a-uuid"])
  end

  test "ledger and outbox schemas use required UUID grant identities" do
    assert CapRevocation.__schema__(:type, :grant_id) == :binary_id
    assert Delivery.__schema__(:type, :grant_id) == :binary_id

    attrs = %{
      workspace_uri: Ezagent.URI.stable_key(@workspace),
      target_uri: "entity://revocation-ledger/agent/target",
      op: :absorb_cap,
      payload: <<1>>,
      payload_version: 1,
      payload_identity: "payload",
      status: :pending,
      attempts: 0,
      next_retry_at: DateTime.utc_now()
    }

    changeset = Delivery.changeset(%Delivery{}, attrs)
    refute changeset.valid?
    assert %{grant_id: ["can't be blank"]} = errors_on(changeset)
  end

  defp marker_attrs(grant_id) do
    %{
      grant_id: grant_id,
      workspace_uri: Ezagent.URI.stable_key(@workspace),
      holder_uri: "entity://revocation-ledger/user/alice",
      cap_identity_key: :crypto.hash(:sha256, "logical-cap"),
      target_uri: "session://revocation-ledger/default/chat",
      key_id: "kind-g1:key",
      revoked_at: DateTime.utc_now()
    }
  end
end
