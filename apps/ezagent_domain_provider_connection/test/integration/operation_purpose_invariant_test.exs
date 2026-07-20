Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.OperationPurposeInvariantTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationBackendRecord,
    BackendPairRegistry,
    CredentialReplacement,
    DriverRegistry,
    Operation
  }

  alias Ezagent.ProviderConnection.Test.Task8Fixtures
  alias EzagentCore.Repo

  setup do
    state = start_supervised!({Agent, fn -> Task8Fixtures.effect_state() end})
    owner = {__MODULE__, self()}
    :acquired = BackendPairRegistry.register(owner, Task8Fixtures.pair())
    :acquired = DriverRegistry.register(owner, Task8Fixtures.driver())

    previous =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations
      )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      Task8Fixtures.credential_implementations()
    )

    Application.put_env(:ezagent_domain_provider_connection, :task8_effect_state, state)

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)
      Application.delete_env(:ezagent_domain_provider_connection, :task8_effect_state)

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

  test "initial bind finalization performs zero prior revokes", %{state: state} do
    connection = Task8Fixtures.connection(%{connection_version: 4})
    attempt = attempt!(connection, "initial_bind")
    backend_record!(attempt, connection)
    operation = operation!(connection, attempt, nil, nil)

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)
    assert %{} = Agent.get(state, & &1.counts)
    assert is_nil(Repo.get!(Operation, operation.id).next_recovery_at)
  end

  test "canonical store changeset derives prior coordinates from the locked attempt purpose" do
    initial_connection =
      Task8Fixtures.connection(%{connection_version: 4, credential_version: 7})

    initial_attempt = attempt!(initial_connection, "initial_bind")

    initial_changeset =
      Operation.store_create_changeset(initial_attempt, initial_connection, %{
        operation_class: "store",
        correlation_id: "canonical-initial",
        bound_input_digest: "digest",
        prior_credential_ref: "caller-spoof",
        prior_credential_version: 99,
        next_recovery_at: DateTime.utc_now(),
        status: "prepared"
      })

    assert initial_changeset.valid?
    assert is_nil(Ecto.Changeset.get_field(initial_changeset, :prior_credential_ref))
    assert is_nil(Ecto.Changeset.get_field(initial_changeset, :prior_credential_version))

    reauthorize_connection =
      Task8Fixtures.connection(%{connection_version: 4, credential_version: 7})

    reauthorize_attempt = attempt!(reauthorize_connection, "reauthorize")

    reauthorize_changeset =
      Operation.store_create_changeset(reauthorize_attempt, reauthorize_connection, %{
        operation_class: "store",
        correlation_id: "canonical-reauthorize",
        bound_input_digest: "digest",
        next_recovery_at: DateTime.utc_now(),
        status: "prepared"
      })

    assert reauthorize_changeset.valid?

    assert Ecto.Changeset.get_field(reauthorize_changeset, :prior_credential_ref) ==
             reauthorize_connection.credential_backend_ref

    assert Ecto.Changeset.get_field(reauthorize_changeset, :prior_credential_version) == 7

    refute Operation.store_create_changeset(
             reauthorize_attempt,
             initial_connection,
             %{
               operation_class: "store",
               correlation_id: "canonical-mismatch",
               bound_input_digest: "digest",
               next_recovery_at: DateTime.utc_now(),
               status: "prepared"
             }
           ).valid?
  end

  test "reauthorization finalization revokes the exact prior coordinate once", %{state: state} do
    connection = Task8Fixtures.connection(%{connection_version: 4, credential_version: 7})
    attempt = attempt!(connection, "reauthorize")
    backend_record!(attempt, connection)

    operation =
      operation!(
        connection,
        attempt,
        connection.credential_backend_ref,
        connection.credential_version
      )

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)

    assert %{credential_revoke: 1} = Agent.get(state, & &1.counts)

    assert [command] =
             state
             |> Agent.get(& &1.calls)
             |> Map.fetch!(:credential_revoke)

    assert command.credential_ref == connection.credential_backend_ref
    assert command.expected_credential_version == connection.credential_version
    assert command.correlation_id == operation.correlation_id <> ":old"
    assert is_nil(Repo.get!(Operation, operation.id).next_recovery_at)
  end

  test "attempt identity coordinates are immutable after an operation relates to them", %{
    state: state
  } do
    for mutation <- [:purpose, :generation, :attempt_ref, :connection_scope] do
      connection = Task8Fixtures.connection(%{connection_version: 4, credential_version: 3})
      attempt = attempt!(connection, "reauthorize")

      operation!(
        connection,
        attempt,
        connection.credential_backend_ref,
        connection.credential_version
      )

      changes = attempt_identity_mutation(mutation)

      attempt
      |> Ecto.Changeset.change(changes)
      |> Ecto.Changeset.check_constraint(:purpose,
        name: :provider_authorization_attempts_immutable_coordinates_check
      )
      |> assert_immutable_attempt_constraint()
    end

    assert %{} = Agent.get(state, & &1.counts)
  end

  test "database relates store-operation prior coordinates to the real attempt purpose", %{
    state: state
  } do
    initial_connection = Task8Fixtures.connection(%{connection_version: 4, credential_version: 3})
    initial_attempt = attempt!(initial_connection, "initial_bind")

    assert_attempt_purpose_constraint(
      operation_changeset(
        initial_connection,
        initial_attempt,
        initial_connection.credential_backend_ref,
        3
      )
    )

    reauthorize_connection =
      Task8Fixtures.connection(%{connection_version: 4, credential_version: 3})

    reauthorize_attempt = attempt!(reauthorize_connection, "reauthorize")

    assert_attempt_purpose_constraint(
      operation_changeset(reauthorize_connection, reauthorize_attempt, nil, nil)
    )

    mismatched_connection = Task8Fixtures.connection(%{connection_version: 4})

    assert_attempt_purpose_constraint(
      operation_changeset(mismatched_connection, reauthorize_attempt, "credential-ref-old", 0)
    )

    assert %{} = Agent.get(state, & &1.counts)
  end

  defp attempt!(connection, purpose) do
    Task8Fixtures.attempt(connection, %{
      purpose: purpose,
      status: "consuming",
      attempt_version: 2,
      claim_token: "claim-#{System.unique_integer([:positive])}"
    })
  end

  defp operation!(connection, attempt, prior_ref, prior_version) do
    connection
    |> operation_changeset(attempt, prior_ref, prior_version)
    |> Repo.insert!()
  end

  defp operation_changeset(connection, attempt, prior_ref, prior_version) do
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
      prior_credential_ref: prior_ref,
      prior_credential_version: prior_version,
      next_recovery_at: now,
      status: "connection_committed"
    })
    |> Ecto.Changeset.check_constraint(:attempt_ref,
      name: :provider_connection_operations_attempt_purpose_check
    )
  end

  defp assert_attempt_purpose_constraint(changeset) do
    assert {:error, changeset} = Repo.insert(changeset)

    assert {"is invalid",
            [
              constraint: :check,
              constraint_name: "provider_connection_operations_attempt_purpose_check"
            ]} = changeset.errors[:attempt_ref]
  end

  defp assert_immutable_attempt_constraint(changeset) do
    assert {:error, changeset} = Repo.update(changeset)

    assert {"is invalid",
            [
              constraint: :check,
              constraint_name: "provider_authorization_attempts_immutable_coordinates_check"
            ]} = changeset.errors[:purpose]
  end

  defp attempt_identity_mutation(:purpose), do: %{purpose: "initial_bind"}
  defp attempt_identity_mutation(:generation), do: %{connection_version: 5}
  defp attempt_identity_mutation(:attempt_ref), do: %{attempt_ref: Ecto.UUID.generate()}

  defp attempt_identity_mutation(:connection_scope) do
    other = Task8Fixtures.connection(%{connection_version: 9})

    %{
      connection_id: other.connection_id,
      workspace_uri: other.workspace_uri,
      connection_version: other.connection_version
    }
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
