defmodule Ezagent.DomainGit.D0BackendContractTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.D0BackendReuseGate, as: D0

  test "backend behaviours freeze exact callback sets and exclude plaintext retrieval" do
    assert Enum.sort(D0.ProviderAuthorizationBackend.behaviour_info(:callbacks)) ==
             Enum.sort(
               begin_authorization: 1,
               cancel_authorization: 1,
               consume_callback: 1,
               reauthenticate: 1
             )

    assert Enum.sort(D0.CredentialBackend.behaviour_info(:callbacks)) ==
             Enum.sort(
               consume_lease: 1,
               lease_for_operation: 1,
               replace: 1,
               revoke: 1,
               status: 1,
               store: 1
             )

    callbacks = D0.CredentialBackend.behaviour_info(:callbacks) |> Keyword.keys()

    refute Enum.any?([:decrypt, :get_plaintext, :fetch_secret, :export], fn name ->
             name in callbacks
           end)
  end

  test "closed backend errors are stable" do
    assert D0.Types.authorization_errors() == [
             :authorization_backend_unavailable,
             :invalid_authorization_subject,
             :invalid_acquisition_method,
             :governed_host_mismatch,
             :state_mismatch,
             :pkce_mismatch,
             :callback_expired,
             :callback_already_consumed,
             :callback_invalid,
             :external_account_mismatch,
             :reauthentication_required,
             :reauthentication_failed,
             :authorization_cancelled,
             :provider_authorization_denied,
             :provider_protocol_error,
             :stale_connection_version
           ]

    assert D0.Types.credential_errors() == [
             :credential_backend_unavailable,
             :credential_not_found,
             :credential_scope_mismatch,
             :credential_host_mismatch,
             :credential_revoked,
             :credential_expired,
             :credential_refresh_required,
             :credential_version_conflict,
             :operation_grant_missing,
             :operation_grant_invalid,
             :operation_not_permitted,
             :lease_not_found,
             :lease_expired,
             :lease_already_consumed,
             :lease_scope_mismatch,
             :lease_consume_failed,
             :credential_store_failed,
             :credential_replace_failed,
             :credential_revoke_failed
           ]
  end

  test "credential lease types freeze operation binding and version fields" do
    {:ok, types} = Code.Typespec.fetch_types(D0.Types)
    atoms = collect_atoms(types)

    assert :operation_class in atoms
    assert :lease_id in atoms
    assert :expected_version in atoms
    assert :observed_version in atoms
    refute :lease_ref in atoms
    refute :operation_digest in atoms
  end

  test "safe_envelope? rejects forbidden keys recursively and permits opaque refs" do
    refute D0.Types.safe_envelope?(%{
             "connection" => %{
               callbacks: [%{"credential_material" => "secret"}]
             }
           })

    refute D0.Types.safe_envelope?(%{result: {%{access_token: "secret"}, :ok}})

    assert D0.Types.safe_envelope?(%{
             "credential_ref" => "cred_opaque_1",
             lease_id: "lease_opaque_1",
             nested: [%{"authorization_ref" => "auth_opaque_1"}]
           })
  end

  @tag :d0_in_process_authorization
  test "in-process fake satisfies the shared authorization contract" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})

    descriptor = %{
      authorization: D0.InProcessFake,
      reset: fn -> D0.InProcessFake.reset(D0.InProcessFake) end,
      advance_time: fn seconds -> D0.InProcessFake.advance_time(D0.InProcessFake, seconds) end,
      authorization_count: fn -> D0.InProcessFake.authorization_count(D0.InProcessFake) end,
      credential_store_count: fn ->
        D0.InProcessFake.credential_store_count(D0.InProcessFake)
      end,
      provider_effect_count: fn -> D0.InProcessFake.provider_effect_count(D0.InProcessFake) end
    }

    assert :ok = D0.Conformance.authorization_cases(descriptor)
  end

  defp collect_atoms(term) when is_atom(term), do: MapSet.new([term])

  defp collect_atoms(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> collect_atoms()
  end

  defp collect_atoms(term) when is_list(term) do
    Enum.reduce(term, MapSet.new(), &MapSet.union(collect_atoms(&1), &2))
  end

  defp collect_atoms(_term), do: MapSet.new()
end
