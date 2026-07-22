Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.CredentialReplacementTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationBackendRecord,
    BackendPairRegistry,
    CredentialReplacement,
    DriverRegistry,
    Operation
  }

  alias Ezagent.ProviderConnection.Test.{Task8Driver, Task8Fixtures}
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

      if previous,
        do:
          Application.put_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations,
            previous
          ),
        else:
          Application.delete_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations
          )
    end)

    %{state: state}
  end

  test "CAS installs the backend receipt version and finalizes the attempt and handoff" do
    connection =
      Task8Fixtures.connection(%{status: "pending_authorization", connection_version: 4})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-2"
      })

    backend_record!(attempt)
    operation = operation!(connection, attempt, %{result_credential_version: 9})

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)

    updated = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert updated.status == "active"
    assert updated.credential_backend_ref == "credential-ref-new"
    assert updated.credential_version == 9
    assert updated.connection_version == 5

    assert Repo.get!(Ezagent.ProviderConnection.AuthorizationAttempt, attempt.attempt_ref).status ==
             "consumed"

    record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    assert record.lifecycle_status == "shredded"
    assert is_nil(record.handoff_ciphertext)
    assert %DateTime{} = record.shredded_at
  end

  test "stale base credential version never replaces the pointer" do
    connection =
      Task8Fixtures.connection(%{
        status: "active",
        connection_version: 4,
        credential_version: 3
      })

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-2"
      })

    operation = operation!(connection, attempt, %{})

    connection
    |> Ezagent.ProviderConnection.Connection.transition_changeset(%{
      credential_backend_ref: "credential-ref-concurrent",
      credential_version: 4,
      connection_version: 5
    })
    |> Repo.update!()

    assert {:error, :stale_version} = CredentialReplacement.commit(operation.id)

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).credential_backend_ref ==
             "credential-ref-concurrent"
  end

  test "old pointer revoke failure remains durable and exact retry finalizes it", %{state: state} do
    connection =
      Task8Fixtures.connection(%{status: "active", connection_version: 4})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-2"
      })

    backend_record!(attempt)
    operation = operation!(connection, attempt, %{result_credential_version: 9})

    Agent.update(
      state,
      &put_in(&1, [:replies, :credential_revoke], {:error, :backend_unavailable})
    )

    assert {:error, :authorization_backend_unavailable} =
             CredentialReplacement.commit(operation.id)

    assert Repo.get!(Operation, operation.id).status == "connection_committed"

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).credential_backend_ref ==
             "credential-ref-new"

    Agent.update(
      state,
      &update_in(&1.replies, fn replies -> Map.delete(replies, :credential_revoke) end)
    )

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(operation.id)
    assert %{credential_revoke: 2} = Agent.get(state, & &1.counts)
  end

  test "reauthorization identity drift keeps the old pointer and retries stable cleanup obligations",
       %{state: state} do
    connection = Task8Fixtures.connection(%{status: "active", connection_version: 4})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-2"
      })

    backend_record!(attempt)

    operation =
      operation!(connection, attempt, %{
        result_external_account_id: "account-drift"
      })

    Agent.update(
      state,
      &put_in(&1, [:replies, :discard_callback_result], {:error, :backend_unavailable})
    )

    assert {:error, :account_conflict} = CredentialReplacement.commit(operation.id)

    unchanged = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert unchanged.status == "active"
    assert unchanged.external_account_id == connection.external_account_id
    assert unchanged.credential_backend_ref == "credential-ref-old"

    cleanup_pending = Repo.get!(Operation, operation.id)
    assert cleanup_pending.status == "cleanup_pending"
    assert cleanup_pending.safe_error_code == "account_conflict"
    assert cleanup_pending.provider_cleanup_status == "pending"
    assert cleanup_pending.provider_cleanup_error_code == "backend_unavailable"
    assert cleanup_pending.credential_cleanup_status == "confirmed"

    assert %{discard_callback_result: 1, credential_revoke: 1} =
             Agent.get(state, & &1.counts)

    Agent.update(
      state,
      &update_in(&1.replies, fn replies -> Map.delete(replies, :discard_callback_result) end)
    )

    assert :ok = CredentialReplacement.cleanup(operation.id)
    assert {:error, :account_conflict} = CredentialReplacement.commit(operation.id)

    finalized = Repo.get!(Operation, operation.id)
    assert finalized.status == "finalized"
    assert finalized.safe_error_code == "account_conflict"

    assert %{discard_callback_result: 2, credential_revoke: 1} =
             Agent.get(state, & &1.counts)
  end

  test "duplicate initial binding has one winner and a stable compensated loser", %{state: state} do
    winner_connection =
      Task8Fixtures.connection(%{status: "pending_authorization", connection_version: 4})

    loser_connection =
      Task8Fixtures.connection(%{status: "pending_authorization", connection_version: 4})

    winner_attempt =
      Task8Fixtures.attempt(winner_connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "winner-claim"
      })

    loser_attempt =
      Task8Fixtures.attempt(loser_connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "loser-claim"
      })

    backend_record!(winner_attempt)
    backend_record!(loser_attempt)

    result_identity = %{
      result_external_account_id: "shared-account",
      result_execution_identity: "connected_user"
    }

    winner = operation!(winner_connection, winner_attempt, result_identity)
    loser = operation!(loser_connection, loser_attempt, result_identity)

    assert {:ok, %Operation{status: "finalized"}} = CredentialReplacement.commit(winner.id)
    assert {:error, :account_conflict} = CredentialReplacement.commit(loser.id)
    assert {:error, :account_conflict} = CredentialReplacement.commit(loser.id)

    assert Repo.get!(Ezagent.ProviderConnection.Connection, winner_connection.connection_id).status ==
             "active"

    failed =
      Repo.get!(Ezagent.ProviderConnection.Connection, loser_connection.connection_id)

    assert failed.status == "failed"
    assert failed.last_error_code == "account_conflict"
    assert is_nil(failed.external_account_id)
    assert is_nil(failed.credential_backend_ref)

    compensated = Repo.get!(Operation, loser.id)
    assert compensated.status == "finalized"
    assert compensated.safe_error_code == "account_conflict"
    assert compensated.provider_cleanup_status == "confirmed"
    assert compensated.credential_cleanup_status == "confirmed"

    assert %{discard_callback_result: 1, credential_revoke: 1} =
             Agent.get(state, & &1.counts)
  end

  test "concurrent duplicate binding exposes only a complete winner or complete loser aggregate" do
    connections =
      for claim <- ["left-claim", "right-claim"] do
        connection =
          Task8Fixtures.connection(%{status: "pending_authorization", connection_version: 4})

        attempt =
          Task8Fixtures.attempt(connection, %{
            status: "consuming",
            attempt_version: 2,
            claim_token: claim
          })

        backend_record!(attempt)

        operation =
          operation!(connection, attempt, %{
            result_external_account_id: "concurrent-shared-account",
            result_execution_identity: "connected_user"
          })

        {connection, attempt, operation}
      end

    results =
      connections
      |> Task.async_stream(
        fn {_connection, _attempt, operation} ->
          CredentialReplacement.commit(operation.id)
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Operation{status: "finalized"}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :account_conflict})) == 1

    [{loser_connection, loser_attempt, loser_operation}] =
      Enum.filter(connections, fn {connection, _attempt, _operation} ->
        Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
          "failed"
      end)

    assert Repo.get!(Ezagent.ProviderConnection.AuthorizationAttempt, loser_attempt.attempt_ref).status ==
             "cancelled"

    loser = Repo.get!(Operation, loser_operation.id)
    assert loser.status == "finalized"
    assert loser.safe_error_code == "account_conflict"
    assert loser.provider_cleanup_status == "confirmed"
    assert loser.credential_cleanup_status == "confirmed"

    failed =
      Repo.get!(Ezagent.ProviderConnection.Connection, loser_connection.connection_id)

    assert is_nil(failed.external_account_id)
    assert is_nil(failed.credential_backend_ref)
  end

  test "fence publishes terminal state only after the handoff is coherently shredded" do
    connection =
      Task8Fixtures.connection(%{status: "active", connection_version: 4})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "terminal-claim"
      })

    operation =
      operation!(connection, attempt, %{
        status: "prepared",
        provider_result_ref: nil,
        handoff_ref: nil,
        result_ref: nil,
        result_credential_version: nil,
        result_external_account_id: nil,
        result_display_login: nil,
        result_execution_identity: nil,
        result_authorization_ref: nil,
        result_authorization_version: nil,
        result_permission_digest: nil,
        result_expires_at: nil,
        next_recovery_at: DateTime.utc_now()
      })

    connection
    |> Ezagent.ProviderConnection.Connection.transition_changeset(%{
      status: "revoking",
      connection_version: 5
    })
    |> Repo.update!()

    assert {:error, :credential_conflict} = CredentialReplacement.fence(operation.id)
    assert Repo.get!(Operation, operation.id).status == "prepared"

    assert Repo.get!(Ezagent.ProviderConnection.AuthorizationAttempt, attempt.attempt_ref).status ==
             "consuming"
  end

  defp operation!(connection, attempt, overrides) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
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
          result_credential_version: 7,
          result_external_account_id: connection.external_account_id || "account-1",
          result_display_login: connection.display_login || "alice",
          result_execution_identity: connection.execution_identity || "connected_user_account_1",
          result_authorization_ref: attempt.authorization_ref,
          result_authorization_version: 1,
          provider_result_ref: "provider-result-ref",
          result_permission_digest: "permissions-v1",
          result_expires_at: DateTime.add(now, 3_600, :second),
          prior_credential_ref: connection.credential_backend_ref,
          prior_credential_version:
            if(connection.credential_backend_ref, do: connection.credential_version),
          next_recovery_at: now,
          status: "backend_committed"
        },
        overrides
      )

    operation =
      %Operation{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!()

    if is_binary(operation.provider_result_ref) do
      :ok =
        Task8Driver.remember_callback_result(
          %{
            owner_uri: connection.owner_uri,
            workspace_uri: connection.workspace_uri,
            provider_id: connection.provider_id,
            acquisition_method: connection.acquisition_method,
            governed_host: connection.governed_host,
            backend_pair_id: operation.backend_pair_id,
            operation_id: operation.id,
            connection_id: operation.connection_id,
            expected_connection_version: operation.expected_connection_version,
            attempt_ref: attempt.attempt_ref,
            authorization_ref: operation.expected_authorization_ref,
            expected_authorization_version: operation.expected_authorization_version,
            correlation_id: operation.correlation_id,
            command_digest: operation.bound_input_digest,
            expected_credential_version: operation.expected_credential_version
          },
          operation.provider_result_ref
        )
    end

    operation
  end

  defp backend_record!(attempt) do
    now = DateTime.utc_now()

    %AuthorizationBackendRecord{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      workspace_uri: attempt.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      key_id: "test-v1",
      key_fingerprint: :crypto.hash(:sha256, :binary.copy(<<90>>, 32)),
      bound_input_digest: attempt.bound_subject_digest,
      begin_correlation_id: "begin",
      owner_uri: URI.to_string(Task8Fixtures.owner()),
      connection_id: attempt.connection_id,
      connection_version: attempt.connection_version,
      provider_id: "task8-provider",
      governed_host: "git.example",
      acquisition_method: "oauth_user",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      execution_identity: "connected_user_account_1",
      consume_correlation_id: attempt.correlation_id,
      consume_input_digest: "consume-digest",
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
