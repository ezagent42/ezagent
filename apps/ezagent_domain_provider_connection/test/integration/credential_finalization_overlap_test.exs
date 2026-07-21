Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/d1_operation_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../support/d1_idempotent_credential_backend.ex", __DIR__))

defmodule Ezagent.ProviderConnection.CredentialFinalizationOverlapTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationBackendRecord,
    BackendPairRegistry,
    CredentialReplacement,
    DriverRegistry,
    Operation
  }

  alias Ezagent.ProviderConnection.Test.{
    D1IdempotentCredentialBackend,
    D1OperationFixtures,
    Task8Fixtures
  }

  alias EzagentCore.Repo

  setup do
    state = start_supervised!({Agent, fn -> D1IdempotentCredentialBackend.new_state() end})
    owner = {__MODULE__, self()}

    assert BackendPairRegistry.register(owner, Task8Fixtures.pair()) in [
             :acquired,
             :existing_identical
           ]

    assert DriverRegistry.register(owner, Task8Fixtures.driver()) in [
             :acquired,
             :existing_identical
           ]

    previous =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations
      )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      %{"credential-task8-v1" => D1IdempotentCredentialBackend}
    )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :d1_idempotent_credential_backend_state,
      state
    )

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)

      Application.delete_env(
        :ezagent_domain_provider_connection,
        :d1_idempotent_credential_backend_state
      )

      if previous do
        Application.put_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations,
          previous
        )
      else
        Application.delete_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations
        )
      end
    end)

    %{state: state}
  end

  test "prior revoke carries an explicit stable idempotency key", %{state: state} do
    operation = operation_fixture!()

    assert {:ok, %Operation{status: "finalized"}} =
             CredentialReplacement.commit(operation.id)

    snapshot = D1IdempotentCredentialBackend.snapshot(state)
    assert snapshot.missing_idempotency_keys == 0
    assert [command] = snapshot.invocations
    assert command.idempotency_key == operation.correlation_id <> ":old"
  end

  test "expired takeover overlaps an old claimant but applies one logical revoke", %{state: state} do
    operation = operation_fixture!()
    now = DateTime.utc_now()
    D1IdempotentCredentialBackend.put_barrier(state, self())

    old_claimant = Task.async(fn -> CredentialReplacement.commit(operation.id, now) end)
    assert_receive {:d1_revoke_effect, old_worker, first_command}

    new_claimant =
      Task.async(fn ->
        CredentialReplacement.commit(operation.id, DateTime.add(now, 31, :second))
      end)

    assert {:ok, %Operation{status: "finalized"}} = Task.await(new_claimant)
    send(old_worker, :release_d1_revoke)
    assert {:error, :stale_version} = Task.await(old_claimant)

    snapshot = D1IdempotentCredentialBackend.snapshot(state)
    assert length(snapshot.invocations) == 2
    assert MapSet.size(snapshot.logical_effects) == 1
    assert Enum.all?(snapshot.invocations, &(&1.idempotency_key == first_command.idempotency_key))
  end

  test "retry after effect succeeds without applying a second logical revoke", %{state: state} do
    operation = operation_fixture!()
    now = DateTime.utc_now()
    D1IdempotentCredentialBackend.fail_after_effect_once(state)

    assert {:error, :authorization_backend_unavailable} =
             CredentialReplacement.commit(operation.id, now)

    persisted = Repo.get!(Operation, operation.id)
    assert persisted.status == "connection_committed"
    assert persisted.next_recovery_at == operation.next_recovery_at

    assert {:ok, %Operation{status: "finalized"}} =
             CredentialReplacement.commit(operation.id, DateTime.add(now, 1, :second))

    snapshot = D1IdempotentCredentialBackend.snapshot(state)
    assert length(snapshot.invocations) == 2
    assert MapSet.size(snapshot.logical_effects) == 1
  end

  defp operation_fixture! do
    connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})

    attempt =
      D1OperationFixtures.attempt(connection, %{
        purpose: "reauthorize",
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-#{System.unique_integer([:positive])}"
      })

    backend_record!(attempt, connection)
    now = DateTime.utc_now()

    %Operation{}
    |> Ecto.Changeset.change(%{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      attempt_ref: attempt.attempt_ref,
      backend_pair_id: attempt.backend_pair_id,
      operation_class: "store",
      correlation_id: "store:#{attempt.correlation_id}",
      bound_input_digest: "digest",
      expected_connection_version: connection.connection_version,
      expected_authorization_ref: attempt.authorization_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version,
      attempt_version: attempt.attempt_version,
      attempt_claim_token: attempt.claim_token,
      handoff_ref: "handoff-ref",
      result_ref: "credential-ref-new",
      result_credential_version: connection.credential_version + 1,
      result_external_account_id: connection.external_account_id,
      result_display_login: connection.display_login,
      result_execution_identity: connection.execution_identity,
      result_authorization_ref: attempt.authorization_ref,
      result_authorization_version: 1,
      provider_result_ref: "provider-result-ref",
      result_permission_digest: "permissions-v2",
      result_expires_at: DateTime.add(now, 3_600, :second),
      prior_credential_ref: connection.credential_backend_ref,
      prior_credential_version: connection.credential_version,
      next_recovery_at: now,
      status: "connection_committed"
    })
    |> Repo.insert!()
  end

  defp backend_record!(attempt, connection) do
    now = DateTime.utc_now()

    %AuthorizationBackendRecord{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      workspace_uri: attempt.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      key_id: "test-v1",
      key_fingerprint: :crypto.hash(:sha256, :binary.copy(<<90>>, 32)),
      bound_input_digest: "digest",
      begin_correlation_id: "begin",
      owner_uri: connection.owner_uri,
      connection_id: attempt.connection_id,
      connection_version: attempt.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      execution_identity: connection.execution_identity,
      handoff_ref: "handoff-ref",
      handoff_ciphertext: "sealed-handoff",
      lifecycle_status: "consumed",
      expires_at: DateTime.add(now, 3_600, :second),
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end
end
