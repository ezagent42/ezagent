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
             :correlation_conflict,
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
             :correlation_conflict,
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
             :request_plan_invalid,
             :provider_response_invalid,
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

  test "mutating callbacks reconcile exact retries and reject conflicting reuse" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})

    descriptor = %{
      authorization: D0.InProcessFake,
      credential: D0.InProcessFake,
      reset: fn -> D0.InProcessFake.reset(D0.InProcessFake) end,
      prepare_lease: &D0.InProcessFake.prepare_lease/1,
      command_effect_count: fn -> D0.InProcessFake.command_effect_count(D0.InProcessFake) end
    }

    assert :ok = D0.Conformance.reconciliation_cases(descriptor)
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

  @tag :d0_in_process_credential
  test "in-process fake satisfies the shared credential lease contract" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})

    descriptor = %{
      credential: D0.InProcessFake,
      adapter_probe: D0.AdapterProbe,
      reset: fn -> D0.InProcessFake.reset(D0.InProcessFake) end,
      advance_time: fn seconds -> D0.InProcessFake.advance_time(D0.InProcessFake, seconds) end,
      provider_effect_count: fn -> D0.InProcessFake.provider_effect_count(D0.InProcessFake) end
    }

    assert :ok = D0.Conformance.credential_cases(descriptor)
  end

  @tag :d0_remote_shaped
  test "remote-shaped fake satisfies shared contracts without serializing sensitive wrappers" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})
    D0.RemoteTransport.reset_payloads()

    descriptor = %{
      authorization: D0.RemoteShapedFake,
      credential: D0.RemoteShapedFake,
      adapter_probe: D0.RemoteAdapterProbe,
      reset: fn -> D0.RemoteShapedFake.reset() end,
      advance_time: &D0.RemoteShapedFake.advance_time/1,
      authorization_count: &D0.RemoteShapedFake.authorization_count/0,
      credential_store_count: &D0.RemoteShapedFake.credential_store_count/0,
      provider_effect_count: &D0.RemoteShapedFake.provider_effect_count/0,
      prepare_lease: &D0.RemoteShapedFake.prepare_lease/1,
      command_effect_count: &D0.RemoteShapedFake.command_effect_count/0
    }

    assert :ok = D0.Conformance.authorization_cases(descriptor)
    assert :ok = D0.Conformance.credential_cases(descriptor)
    assert :ok = D0.Conformance.reconciliation_cases(descriptor)

    payloads = D0.RemoteTransport.payloads()
    assert payloads != []
    assert Enum.all?(payloads, &is_binary/1)
    refute Enum.any?(payloads, &String.contains?(&1, "gho-D0-SENTINEL"))
    refute Enum.any?(payloads, &String.contains?(&1, "SensitiveCredential"))
    assert Enum.any?(payloads, &String.contains?(&1, "sealed_credential"))
  end

  @tag :d0_remote_shaped
  test "remote-shaped fake reconciles after-commit response loss by correlation id" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})
    D0.RemoteTransport.reset_payloads()
    :ok = D0.RemoteShapedFake.reset()

    subject = remote_subject()

    {:ok, started} =
      D0.RemoteShapedFake.begin_authorization(%{
        subject: subject,
        acquisition_method: "oauth_user",
        requested_permissions_digest: "requested-digest-1",
        redirect_uri_id: "github-callback",
        correlation_id: "corr-remote-begin"
      })

    callback_request = %{
      authorization_ref: started.authorization_ref,
      expected_subject: subject,
      correlation_id: "corr-remote-callback",
      callback_envelope: %{
        state: started.redirect["state"],
        pkce_digest: started.redirect["pkce_digest"],
        governed_host: "github.com",
        external_account_id: "github-user-42",
        acquisition_origin: :repository_consent
      }
    }

    D0.RemoteTransport.fail_next(:after_commit)

    assert {:error, :authorization_backend_unavailable} =
             D0.RemoteShapedFake.consume_callback(callback_request)

    assert {:ok, %{external_account_id: "github-user-42"}} =
             D0.RemoteShapedFake.consume_callback(callback_request)

    scope = remote_scope()

    {:ok, record} =
      D0.RemoteShapedFake.store(%{
        scope: scope,
        credential_material: "gho-D0-SENTINEL",
        expected_absent: true,
        correlation_id: "corr-remote-store"
      })

    replace_request = %{
      credential_ref: record.credential_ref,
      expected_scope: scope,
      expected_version: 1,
      credential_material: "gho-D0-ROTATED",
      correlation_id: "corr-remote-replace"
    }

    D0.RemoteTransport.fail_next(:after_commit)

    assert {:error, :credential_backend_unavailable} =
             D0.RemoteShapedFake.replace(replace_request)

    assert {:ok, %{version: 2}} = D0.RemoteShapedFake.replace(replace_request)

    lease_request = %{
      credential_ref: record.credential_ref,
      expected_scope: scope,
      expected_version: 2,
      operation_class: :create_change_request,
      operation_grant: %{
        receiver: :provider_adapter,
        credential_ref: record.credential_ref,
        expected_scope: scope,
        expected_version: 2,
        operation_class: :create_change_request
      },
      correlation_id: "corr-remote-lease"
    }

    D0.RemoteTransport.fail_next(:after_commit)

    assert {:error, :credential_backend_unavailable} =
             D0.RemoteShapedFake.lease_for_operation(lease_request)

    assert {:ok, %{lease_id: lease_id}} = D0.RemoteShapedFake.lease_for_operation(lease_request)
    assert lease_id == "lease-1"
  end

  @tag :d0_remote_shaped
  test "remote serializer rejects sensitive wrappers in requests and responses" do
    sensitive = %D0.SensitiveCredential{value: "gho-D0-SENTINEL"}
    D0.RemoteTransport.reset_payloads()

    request_error =
      assert_raise ArgumentError, ~r/SensitiveCredential cannot cross/, fn ->
        D0.RemoteTransport.round_trip(:probe, %{sensitive: sensitive}, fn _, _ -> :ok end)
      end

    refute Exception.message(request_error) =~ "gho-D0-SENTINEL"
    assert D0.RemoteTransport.payloads() == []

    response_error =
      assert_raise ArgumentError, ~r/SensitiveCredential cannot cross/, fn ->
        D0.RemoteTransport.round_trip(:probe, %{safe: "opaque-ref"}, fn _, _ ->
          %{sensitive: sensitive}
        end)
      end

    refute Exception.message(response_error) =~ "gho-D0-SENTINEL"
    refute Enum.any?(D0.RemoteTransport.payloads(), &String.contains?(&1, "gho-D0-SENTINEL"))
  end

  @tag :d0_remote_shaped
  test "tampered sealed lease fails closed without wrapper or provider effect" do
    start_supervised!({D0.InProcessFake, name: D0.InProcessFake})
    D0.RemoteTransport.reset_payloads()
    :ok = D0.RemoteShapedFake.reset()
    scope = remote_scope()

    {:ok, record} =
      D0.RemoteShapedFake.store(%{
        scope: scope,
        credential_material: "gho-D0-SENTINEL",
        expected_absent: true,
        correlation_id: "corr-tamper-store"
      })

    request = %{
      credential_ref: record.credential_ref,
      expected_scope: scope,
      expected_version: 1,
      operation_class: :create_change_request,
      operation_grant: %{
        receiver: :provider_adapter,
        credential_ref: record.credential_ref,
        expected_scope: scope,
        expected_version: 1,
        operation_class: :create_change_request
      },
      correlation_id: "corr-tamper-lease"
    }

    :ok = D0.RemoteShapedFake.tamper_next_sealed_response()

    assert {:error, :provider_response_invalid} =
             D0.RemoteShapedFake.lease_for_operation(request)

    assert D0.RemoteShapedFake.provider_effect_count() == 0
    refute Enum.any?(D0.RemoteTransport.payloads(), &String.contains?(&1, "gho-D0-SENTINEL"))
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

  defp remote_subject do
    Map.put(remote_scope(), :connection_version, 1)
  end

  defp remote_scope do
    %{
      owner_uri: Ezagent.URI.user("acme", "alice"),
      workspace_uri: Ezagent.URI.workspace("acme"),
      provider_id: "github",
      governed_host: "github.com",
      connection_id: "conn-1"
    }
  end
end
