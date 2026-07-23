Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/remote_refresh_exchange_endpoint.ex", __DIR__))

defmodule Ezagent.ProviderConnection.CallbackSourceMatrixTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    BackendPairRegistry,
    DriverRegistry,
    Operation,
    Store
  }

  alias Ezagent.ProviderConnection.Test.Task8Fixtures
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

  test "reauthorization callback from an expired connection is admitted to the consume phase",
       %{state: _state} do
    connection = Task8Fixtures.connection(%{status: "expired"})

    attempt =
      Task8Fixtures.attempt(connection, %{
        purpose: "reauthorize",
        status: "pending",
        correlation_id: "expired-reauth-callback"
      })

    seed_backend_record!(connection, attempt, lifecycle_status: "pending")

    result =
      Store.execute(
        :consume_callback,
        %{attempt_ref: attempt.attempt_ref, correlation_id: "expired-reauth-callback"},
        %{self_uri: Task8Fixtures.owner()}
      )

    # The source gate must admit the spec-sanctioned reauthorization source
    # (spec §4: reauthorize callbacks from active/degraded/expired); the flow
    # then reaches the consume phase and leaves its durable prepared
    # operation instead of dying at the gate with :connection_terminal.
    refute result == {:error, :connection_terminal}

    assert Repo.get_by!(Operation,
             backend_pair_id: attempt.backend_pair_id,
             operation_class: "replace",
             correlation_id: "replace:expired-reauth-callback"
           ).status == "prepared"
  end

  test "callback from a refresh_required connection is rejected at the source gate", %{
    state: _state
  } do
    connection = Task8Fixtures.connection(%{status: "refresh_required"})

    attempt =
      Task8Fixtures.attempt(connection, %{
        purpose: "initial_bind",
        status: "pending",
        correlation_id: "refresh-required-callback"
      })

    assert {:error, :connection_terminal} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: "refresh-required-callback"},
               %{self_uri: Task8Fixtures.owner()}
             )

    refute Repo.get_by(Operation,
             backend_pair_id: attempt.backend_pair_id,
             correlation_id: "store:refresh-required-callback"
           )

    refute Repo.get_by(Operation,
             backend_pair_id: attempt.backend_pair_id,
             correlation_id: "replace:refresh-required-callback"
           )
  end

  test "a user callback retry in the backend_committed window drives the idempotent commit",
       %{state: _state} do
    connection = Task8Fixtures.connection(%{status: "pending_authorization"})

    attempt =
      Task8Fixtures.attempt(connection, %{
        purpose: "initial_bind",
        status: "consuming",
        correlation_id: "backend-committed-retry",
        claim_token: "retry-claim",
        claim_until: DateTime.add(DateTime.utc_now(), 60, :second),
        attempt_version: 1
      })

    record = seed_backend_record!(connection, attempt, lifecycle_status: "consumed")

    operation =
      Operation.store_create_changeset(attempt, connection, %{
        operation_class: "store",
        correlation_id: "store:backend-committed-retry",
        bound_input_digest: "placeholder",
        next_recovery_at: DateTime.utc_now(),
        status: "prepared"
      })
      |> Repo.insert!()

    operation =
      operation
      |> Operation.provider_ownership_changeset(%{
        handoff_ref: "handoff-retry",
        result_external_account_id: "acct-retry",
        result_display_login: "retry-user",
        result_execution_identity: "connected_user",
        result_authorization_ref: attempt.authorization_ref,
        result_authorization_version: 1,
        provider_result_ref: "provider-result-retry",
        result_permission_digest: "permissions-retry",
        result_expires_at: nil
      })
      |> Repo.update!()

    operation =
      operation
      |> Operation.credential_ownership_changeset("backend_committed", %{
        result_ref: "credential-ref-retry",
        result_credential_version: 3
      })
      |> Repo.update!()

    # Pin the durable command digest to the seeded rows, exactly as the
    # prepared path would have computed it.
    digest = Operation.callback_digest(record, attempt, connection)

    operation =
      operation
      |> Ecto.Changeset.change(bound_input_digest: digest)
      |> Repo.update!()

    assert {:ok, receipt} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: "backend-committed-retry"},
               %{self_uri: Task8Fixtures.owner()}
             )

    assert receipt.connection_id == connection.connection_id
    assert receipt.status == "active"
    assert receipt.version == connection.connection_version + 1

    assert Repo.get!(Operation, operation.id).status == "finalized"
    assert Repo.get!(AuthorizationAttempt, attempt.attempt_ref).status == "consumed"
  end

  defp seed_backend_record!(connection, attempt, opts) do
    lifecycle_status = Keyword.fetch!(opts, :lifecycle_status)

    %{
      id: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      execution_identity: connection.execution_identity || "connected_user",
      key_id: "key-1",
      key_fingerprint: "fingerprint-1",
      nonce: "nonce",
      ciphertext: "ciphertext",
      bound_input_digest: attempt.bound_subject_digest,
      begin_correlation_id: "begin-#{attempt.correlation_id}",
      owner_uri: connection.owner_uri,
      connection_id: connection.connection_id,
      connection_version: attempt.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: attempt.requested_permission_digest,
      redirect_uri_id: attempt.redirect_uri_id,
      expires_at: attempt.expires_at,
      lifecycle_status: lifecycle_status
    }
    |> AuthorizationBackendRecord.create_changeset()
    |> Ecto.Changeset.change(
      handoff_ref: if(lifecycle_status == "consumed", do: "handoff-seed", else: nil),
      handoff_ciphertext: if(lifecycle_status == "consumed", do: "sealed", else: nil)
    )
    |> Repo.insert!()
  end
end
