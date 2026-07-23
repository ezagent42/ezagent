Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/d1_operation_fixtures.ex", __DIR__))

defmodule Ezagent.ProviderConnection.OperationPurposeInvariantTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationBackendRecord,
    BackendPairRegistry,
    CredentialReplacement,
    DriverRegistry,
    Operation
  }

  alias Ezagent.ProviderConnection.Test.{D1OperationFixtures, Task8Fixtures}
  alias EzagentCore.Repo

  setup do
    state = start_supervised!({Agent, fn -> Task8Fixtures.effect_state() end})
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
    connection = D1OperationFixtures.connection(%{connection_version: 4})
    attempt = attempt!(connection, "initial_bind")
    backend_record!(attempt, connection)
    operation = operation!(connection, attempt, nil, nil)

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)
    assert %{} = Agent.get(state, & &1.counts)
    assert is_nil(Repo.get!(Operation, operation.id).next_recovery_at)
  end

  test "canonical store changeset derives prior coordinates from the locked attempt purpose" do
    initial_connection =
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})

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

    assert Ecto.Changeset.get_field(initial_changeset, :expected_authorization_ref) ==
             initial_attempt.authorization_ref

    assert Ecto.Changeset.get_field(initial_changeset, :expected_authorization_version) ==
             initial_connection.authorization_version

    assert is_nil(Ecto.Changeset.get_field(initial_changeset, :prior_credential_ref))
    assert is_nil(Ecto.Changeset.get_field(initial_changeset, :prior_credential_version))

    reauthorize_connection =
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})

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

    assert Ecto.Changeset.get_field(reauthorize_changeset, :operation_class) == "replace"

    assert Ecto.Changeset.get_field(reauthorize_changeset, :prior_credential_ref) ==
             reauthorize_connection.credential_backend_ref

    assert Ecto.Changeset.get_field(reauthorize_changeset, :prior_credential_version) == 7

    assert Ecto.Changeset.get_field(reauthorize_changeset, :expected_authorization_ref) ==
             reauthorize_attempt.authorization_ref

    assert Ecto.Changeset.get_field(reauthorize_changeset, :expected_authorization_version) ==
             reauthorize_connection.authorization_version

    refute Operation.store_create_changeset(
             reauthorize_attempt,
             initial_connection,
             %{
               operation_class: "replace",
               correlation_id: "canonical-mismatch",
               bound_input_digest: "digest",
               next_recovery_at: DateTime.utc_now(),
               status: "prepared"
             }
           ).valid?

    refute Operation.store_create_changeset(
             %{reauthorize_attempt | backend_pair_id: "different-pair"},
             reauthorize_connection,
             %{
               operation_class: "replace",
               correlation_id: "canonical-pair-mismatch",
               bound_input_digest: "digest",
               next_recovery_at: DateTime.utc_now(),
               status: "prepared"
             }
           ).valid?
  end

  test "reauthorization finalization revokes the exact prior coordinate once", %{state: state} do
    connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})
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

  test "concurrent reauthorization finalizers admit one backend caller", %{state: state} do
    connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})
    attempt = attempt!(connection, "reauthorize")
    backend_record!(attempt, connection)

    operation =
      operation!(
        connection,
        attempt,
        connection.credential_backend_ref,
        connection.credential_version
      )

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :credential_revoke], test_pid))
    winner = Task.async(fn -> CredentialReplacement.commit(operation.id) end)

    assert_receive {:task8_barrier, :credential_revoke, worker, command}
    assert command.correlation_id == operation.correlation_id <> ":old"

    contender = Task.async(fn -> CredentialReplacement.commit(operation.id) end)
    refute_receive {:task8_barrier, :credential_revoke, _worker, _command}, 200
    assert {:error, :callback_in_progress} = Task.await(contender)

    send(worker, {:release_task8, :credential_revoke})
    assert {:ok, %Operation{status: "finalized"}} = Task.await(winner)
    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)
    assert %{credential_revoke: 1} = Agent.get(state, & &1.counts)
  end

  test "stale finalization claimant cannot complete after its lease is replaced", %{state: state} do
    connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 7})
    attempt = attempt!(connection, "reauthorize")
    backend_record!(attempt, connection)

    operation =
      operation!(
        connection,
        attempt,
        connection.credential_backend_ref,
        connection.credential_version
      )

    now = DateTime.utc_now()
    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :credential_revoke], test_pid))
    stale = Task.async(fn -> CredentialReplacement.commit(operation.id, now) end)

    assert_receive {:task8_barrier, :credential_revoke, worker, _command}

    operation
    |> Repo.reload!()
    |> Ecto.Changeset.change(
      lease_token: "replacement-claim",
      lease_until: DateTime.add(now, -1, :second)
    )
    |> Repo.update!()

    send(worker, {:release_task8, :credential_revoke})
    assert {:error, :stale_version} = Task.await(stale)
    assert Repo.get!(Operation, operation.id).status == "connection_committed"

    Agent.update(state, &put_in(&1, [:barriers, :credential_revoke], nil))

    assert {:ok, %Operation{status: "finalized"}} =
             CredentialReplacement.commit(operation.id, DateTime.add(now, 1, :second))

    assert %{credential_revoke: 2} = Agent.get(state, & &1.counts)
  end

  test "attempt identity coordinates are immutable after an operation relates to them", %{
    state: state
  } do
    for mutation <- [
          :purpose,
          :generation,
          :backend_pair,
          :backend_pair_clear,
          :attempt_ref,
          :connection_scope
        ] do
      connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})
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

  test "attempt backend pair permits one settlement and then becomes immutable" do
    connection = D1OperationFixtures.connection(%{connection_version: 4})

    attempt =
      D1OperationFixtures.attempt(connection, %{
        purpose: "reauthorize",
        status: "consumed",
        backend_pair_id: nil
      })

    assert {:ok, settled} =
             attempt
             |> Ecto.Changeset.change(backend_pair_id: connection.backend_pair_id)
             |> Repo.update()

    for backend_pair_id <- ["different-pair", nil] do
      settled
      |> Ecto.Changeset.change(backend_pair_id: backend_pair_id)
      |> Ecto.Changeset.check_constraint(:purpose,
        name: :provider_authorization_attempts_immutable_coordinates_check
      )
      |> assert_immutable_attempt_constraint()
    end
  end

  test "store operation keeps its authorization attempt alive" do
    connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})
    attempt = attempt!(connection, "reauthorize")

    operation!(
      connection,
      attempt,
      connection.credential_backend_ref,
      connection.credential_version
    )

    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.delete!(attempt)
      end

    assert error.constraint == "provider_connection_operations_attempt_ref_fkey"
  end

  test "connection backend binding settles once and then remains immutable" do
    unbound =
      D1OperationFixtures.connection(%{
        backend_pair_id: nil,
        authorization_backend_id: nil,
        credential_backend_id: nil
      })

    assert {:ok, settled} =
             unbound
             |> Ecto.Changeset.change(
               backend_pair_id: "pair-task8-v1",
               authorization_backend_id: "local-authorization-v1",
               credential_backend_id: "credential-task8-v1"
             )
             |> Repo.update()

    for changes <- [
          %{backend_pair_id: "different-pair"},
          %{authorization_backend_id: "different-authorization"},
          %{credential_backend_id: "different-credential"},
          %{
            backend_pair_id: nil,
            authorization_backend_id: nil,
            credential_backend_id: nil
          }
        ] do
      changeset =
        settled
        |> Ecto.Changeset.change(changes)
        |> Ecto.Changeset.check_constraint(:backend_pair_id,
          name: :provider_connections_immutable_binding_check
        )

      assert {:error, changeset} = Repo.update(changeset)
      assert changeset.errors[:backend_pair_id]
    end

    still_unbound =
      D1OperationFixtures.connection(%{
        backend_pair_id: nil,
        authorization_backend_id: nil,
        credential_backend_id: nil
      })

    half_binding =
      still_unbound
      |> Ecto.Changeset.change(backend_pair_id: "pair-task8-v1")
      |> Ecto.Changeset.check_constraint(:backend_pair_id,
        name: :provider_connections_backend_binding_check
      )

    assert {:error, half_binding} = Repo.update(half_binding)

    assert {"is invalid",
            [
              constraint: :check,
              constraint_name: "provider_connections_backend_binding_check"
            ]} = half_binding.errors[:backend_pair_id]
  end

  test "database relates store-operation prior coordinates to the real attempt purpose", %{
    state: state
  } do
    pending_connection =
      D1OperationFixtures.connection(%{
        status: "pending_authorization",
        connection_version: 4,
        credential_version: 0
      })

    pending_attempt = attempt!(pending_connection, "initial_bind")

    assert {:ok, %Operation{status: "prepared"}} =
             pending_attempt
             |> Operation.store_create_changeset(pending_connection, %{
               operation_class: "store",
               correlation_id: "pending-null-pair",
               bound_input_digest: "digest",
               next_recovery_at: DateTime.utc_now(),
               status: "prepared"
             })
             |> Repo.insert()

    initial_connection =
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})

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
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})

    reauthorize_attempt = attempt!(reauthorize_connection, "reauthorize")

    assert_attempt_purpose_constraint(
      operation_changeset(reauthorize_connection, reauthorize_attempt, nil, nil)
    )

    mismatched_connection = D1OperationFixtures.connection(%{connection_version: 4})

    assert_attempt_purpose_constraint(
      operation_changeset(mismatched_connection, reauthorize_attempt, "credential-ref-old", 0)
    )

    for changes <- [
          %{attempt_ref: Ecto.UUID.generate()},
          %{expected_connection_version: reauthorize_attempt.connection_version + 1},
          %{backend_pair_id: "wrong-pair"},
          %{expected_credential_version: reauthorize_connection.credential_version + 1},
          %{expected_credential_version: nil},
          %{prior_credential_ref: "tampered-prior"},
          %{prior_credential_version: reauthorize_connection.credential_version + 1}
        ] do
      reauthorize_connection
      |> operation_changeset(
        reauthorize_attempt,
        reauthorize_connection.credential_backend_ref,
        reauthorize_connection.credential_version
      )
      |> Ecto.Changeset.change(changes)
      |> assert_attempt_purpose_constraint()
    end

    assert {:error, missing_credential_changeset} =
             reauthorize_connection
             |> operation_changeset(
               reauthorize_attempt,
               reauthorize_connection.credential_backend_ref,
               reauthorize_connection.credential_version
             )
             |> Ecto.Changeset.change(
               status: "prepared",
               expected_credential_version: nil,
               correlation_id: "missing-prepared-credential-version"
             )
             |> Ecto.Changeset.check_constraint(:status,
               name: :provider_connection_operations_callback_prepare_check
             )
             |> Repo.insert()

    assert {"is invalid",
            [
              constraint: :check,
              constraint_name: "provider_connection_operations_callback_prepare_check"
            ]} = missing_credential_changeset.errors[:status]

    stale_generation_connection =
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})

    stale_generation_attempt = attempt!(stale_generation_connection, "reauthorize")

    stale_generation_connection
    |> Ecto.Changeset.change(
      connection_version: 5,
      authorization_backend_ref: "advanced-authorization-ref",
      authorization_version: stale_generation_connection.authorization_version + 1
    )
    |> Repo.update!()

    assert_attempt_purpose_constraint(
      operation_changeset(
        stale_generation_connection,
        stale_generation_attempt,
        stale_generation_connection.credential_backend_ref,
        stale_generation_connection.credential_version
      )
    )

    mismatched_pair_connection =
      D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})

    mismatched_pair_attempt =
      D1OperationFixtures.attempt(mismatched_pair_connection, %{
        purpose: "reauthorize",
        status: "consuming",
        backend_pair_id: "different-pair",
        attempt_version: 2,
        claim_token: "claim-#{System.unique_integer([:positive])}"
      })

    assert_attempt_purpose_constraint(
      operation_changeset(
        mismatched_pair_connection,
        mismatched_pair_attempt,
        mismatched_pair_connection.credential_backend_ref,
        mismatched_pair_connection.credential_version
      )
    )

    legacy_connection = D1OperationFixtures.connection(%{connection_version: 4})
    legacy_attempt = attempt!(legacy_connection, "legacy", "consumed")

    assert_attempt_purpose_constraint(
      operation_changeset(legacy_connection, legacy_attempt, nil, nil)
    )

    assert %{} = Agent.get(state, & &1.counts)
  end

  test "store operation attempt-derived coordinates cannot drift after insert" do
    for changes <- [
          %{expected_connection_version: 5},
          %{expected_credential_version: 4},
          %{backend_pair_id: "wrong-pair"},
          %{prior_credential_ref: "tampered-prior"},
          %{prior_credential_version: 4},
          %{operation_class: "replace"},
          %{attempt_ref: Ecto.UUID.generate()}
        ] do
      connection = D1OperationFixtures.connection(%{connection_version: 4, credential_version: 3})
      attempt = attempt!(connection, "reauthorize")

      operation =
        operation!(
          connection,
          attempt,
          connection.credential_backend_ref,
          connection.credential_version
        )

      operation
      |> Ecto.Changeset.change(changes)
      |> Ecto.Changeset.check_constraint(:attempt_ref,
        name: :provider_connection_operations_attempt_purpose_check
      )
      |> assert_operation_update_constraint()
    end
  end

  defp attempt!(connection, purpose, status \\ "consuming") do
    D1OperationFixtures.attempt(connection, %{
      purpose: purpose,
      status: status,
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
      result_authorization_version: connection.authorization_version + 1,
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

  defp assert_operation_update_constraint(changeset) do
    assert {:error, changeset} = Repo.update(changeset)

    assert {"is invalid",
            [
              constraint: :check,
              constraint_name: "provider_connection_operations_attempt_purpose_check"
            ]} = changeset.errors[:attempt_ref]
  end

  defp attempt_identity_mutation(:purpose), do: %{purpose: "initial_bind"}
  defp attempt_identity_mutation(:generation), do: %{connection_version: 5}
  defp attempt_identity_mutation(:backend_pair), do: %{backend_pair_id: "different-pair"}
  defp attempt_identity_mutation(:backend_pair_clear), do: %{backend_pair_id: nil}
  defp attempt_identity_mutation(:attempt_ref), do: %{attempt_ref: Ecto.UUID.generate()}

  defp attempt_identity_mutation(:connection_scope) do
    other = D1OperationFixtures.connection(%{connection_version: 9})

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
