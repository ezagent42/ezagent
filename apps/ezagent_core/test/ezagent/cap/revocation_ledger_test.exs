defmodule Ezagent.Cap.RevocationLedgerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.RevocationLedger

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
    attrs = marker_attrs("grant-1")

    assert {:ok, first} = RevocationLedger.mark(attrs)
    assert {:ok, repeated} = RevocationLedger.mark(%{attrs | target_uri: "changed-audit"})
    assert repeated.grant_id == first.grant_id
    assert repeated.target_uri == first.target_uri

    assert {:ok, revoked} =
             RevocationLedger.revoked_grant_ids(@workspace, ["grant-1", "grant-live"])

    assert revoked == MapSet.new(["grant-1"])

    assert {:ok, other_workspace_revoked} =
             RevocationLedger.revoked_grant_ids(@other_workspace, ["grant-1"])

    assert other_workspace_revoked == MapSet.new()
  end

  test "empty grant-id batches avoid a database query and return empty" do
    assert {:ok, revoked} = RevocationLedger.revoked_grant_ids(@workspace, [])
    assert revoked == MapSet.new()
  end

  test "a ledger read failure stays distinct so authorization callers can deny" do
    Application.put_env(:ezagent_core, :cap_revocation_ledger_force_read_error, true)

    assert {:error, :forced_ledger_read_error} =
             RevocationLedger.revoked_grant_ids(@workspace, ["grant-unreadable"])
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
