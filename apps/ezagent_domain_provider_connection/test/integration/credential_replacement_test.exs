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
        status: "pending_authorization",
        connection_version: 4,
        credential_version: 3
      })

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        attempt_version: 2,
        claim_token: "claim-2"
      })

    operation = operation!(connection, attempt, %{expected_credential_version: 2})

    assert {:error, :stale_version} = CredentialReplacement.commit(operation.id)

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).credential_backend_ref ==
             "credential-ref-old"
  end

  test "old pointer revoke failure remains durable and exact retry finalizes it", %{state: state} do
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

  defp operation!(connection, attempt, overrides) do
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
          expected_credential_version: connection.credential_version,
          attempt_version: attempt.attempt_version,
          attempt_claim_token: attempt.claim_token,
          handoff_ref: "handoff-ref",
          result_ref: "credential-ref-new",
          result_credential_version: 7,
          prior_credential_ref: connection.credential_backend_ref,
          prior_credential_version: connection.credential_version,
          status: "backend_committed"
        },
        overrides
      )

    %Operation{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
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
      bound_input_digest: "digest",
      begin_correlation_id: "begin",
      owner_uri: URI.to_string(Task8Fixtures.owner()),
      connection_id: attempt.connection_id,
      connection_version: attempt.connection_version,
      provider_id: "task8-provider",
      governed_host: "git.example",
      acquisition_method: "oauth_user",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      execution_identity: "connected_user:account-1",
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
