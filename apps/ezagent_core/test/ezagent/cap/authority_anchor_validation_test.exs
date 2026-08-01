defmodule Ezagent.Cap.AuthorityAnchorValidationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, RevocationLedger}
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority
  alias EzagentCore.Repo

  setup do
    Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
    end)

    :ok
  end

  test "anchor loading rejects corrupt, unsafe, non-capability, and invalid grant terms" do
    target = unique_target("term")
    {:ok, _authority} = Authority.open(target, :agent)
    row = active_row(target)
    valid = :erlang.binary_to_term(row.anchor, [:safe])

    invalid_terms = [
      <<131, 255>>,
      :erlang.term_to_binary(fn -> :unsafe end),
      :erlang.term_to_binary(%{not: :a_capability}),
      :erlang.term_to_binary(%{valid | grant_id: nil}),
      :erlang.term_to_binary(%{valid | grant_id: String.upcase(valid.grant_id)})
    ]

    for encoded <- invalid_terms do
      replace_anchor!(active_row(target), encoded)
      assert {:error, :invalid_authority_anchor} = Authority.anchor(target)
    end
  end

  test "anchor loading checks the authority row binding" do
    target = unique_target("binding")
    {:ok, authority} = Authority.open(target, :agent)
    row = active_row(target)
    valid = :erlang.binary_to_term(row.anchor, [:safe])
    other_target = unique_target("other")

    wrong_target =
      valid |> Map.put(:instance, other_target) |> then(&Authority.sign(authority, &1))

    replace_anchor!(row, :erlang.term_to_binary(wrong_target))
    assert {:error, :invalid_authority_anchor} = Authority.anchor(target)

    row = active_row(target)
    replace_anchor!(row, :erlang.term_to_binary(valid))

    row
    |> Ecto.Changeset.change(key_id: "kind-g1:wrong-row-key")
    |> Repo.update!()

    assert {:error, :invalid_authority_anchor} = Authority.anchor(target)
  end

  test "anchor loading rejects stale and revoked grants" do
    target = unique_target("freshness")
    {:ok, _generation_one} = Authority.open(target, :agent)
    old_row = active_row(target)

    {:ok, _generation_two} = Authority.regenesis(target, :agent)
    replace_anchor!(active_row(target), old_row.anchor)
    assert {:error, :invalid_authority_anchor} = Authority.anchor(target)

    current_target = unique_target("revoked")
    {:ok, _authority} = Authority.open(current_target, :agent)
    assert {:ok, anchor} = Authority.anchor(current_target)
    assert {:ok, _marker} = RevocationLedger.mark(revocation_attrs(anchor))
    assert {:error, :invalid_authority_anchor} = Authority.anchor(current_target)
  end

  test "anchor loading fails closed when the revocation ledger is unreadable" do
    target = unique_target("ledger-error")
    {:ok, _authority} = Authority.open(target, :agent)
    Application.put_env(:ezagent_core, :cap_revocation_ledger_force_read_error, true)

    assert {:error, :invalid_authority_anchor} = Authority.anchor(target)
  end

  defp active_row(target) do
    target
    |> Ezagent.URI.stable_key()
    |> KindCapAuthority.active()
  end

  defp replace_anchor!(row, encoded) do
    row
    |> Ecto.Changeset.change(anchor: encoded)
    |> Repo.update!()
  end

  defp revocation_attrs(%Capability{} = anchor) do
    %{
      grant_id: anchor.grant_id,
      workspace_uri: anchor.workspace_uri |> Ezagent.URI.stable_key(),
      holder_uri: anchor.grantee_uri |> Ezagent.URI.stable_key(),
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(anchor))),
      revoked_at: DateTime.utc_now(),
      target_uri: anchor.instance |> Ezagent.URI.stable_key(),
      key_id: anchor.key_id
    }
  end

  defp unique_target(suffix) do
    Ezagent.URI.agent("team-alpha", "anchor-#{suffix}-#{System.unique_integer([:positive])}")
  end
end
