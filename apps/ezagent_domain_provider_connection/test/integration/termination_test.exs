Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.TerminationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationBackendRecord,
    BackendPairRegistry,
    DriverRegistry,
    Operation,
    Selector,
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

  for action <- [:revoke, :disconnect] do
    terminal = if action == :revoke, do: "revoked", else: "disconnected"
    closing = if action == :revoke, do: "revoking", else: "disconnecting"

    test "#{action} reaches terminal only after independently durable provider and credential obligations",
         %{state: state} do
      action = unquote(action)
      terminal = unquote(terminal)
      closing = unquote(closing)
      connection = Task8Fixtures.connection(%{connection_version: 8, credential_version: 3})
      _attempt = Task8Fixtures.attempt(connection)

      Agent.update(
        state,
        &put_in(&1, [:replies, :provider_revoke], {:error, :backend_unavailable})
      )

      args = %{connection_id: connection.connection_id, expected_version: 8}
      ctx = %{self_uri: Task8Fixtures.owner()}

      assert {:error, :authorization_backend_unavailable} = Store.execute(action, args, ctx)

      assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
               closing

      assert {:error, :connection_not_found} = Selector.select(scope(connection))

      obligations =
        Repo.all(from(o in Operation, where: o.connection_id == ^connection.connection_id))

      assert Enum.sort(Enum.map(obligations, & &1.status)) == ["backend_committed", "prepared"]

      Agent.update(
        state,
        &update_in(&1.replies, fn replies -> Map.delete(replies, :provider_revoke) end)
      )

      assert {:ok, terminal_result = %{status: ^terminal, version: 10}} =
               Store.execute(action, args, ctx)

      assert {:ok, ^terminal_result} = Store.execute(action, args, ctx)

      assert Enum.all?(
               Repo.all(
                 from(o in Operation, where: o.connection_id == ^connection.connection_id)
               ),
               &(&1.status == "finalized")
             )

      assert %{provider_revoke: 2, credential_revoke: 1} = Agent.get(state, & &1.counts)
    end
  end

  test "wrong owner or stale expected version performs no effect", %{state: state} do
    connection = Task8Fixtures.connection(%{connection_version: 3})
    _attempt = Task8Fixtures.attempt(connection)

    assert {:error, :invalid_authorization_subject} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 3},
               %{self_uri: Ezagent.URI.new!("entity://acme/user/mallory")}
             )

    assert {:error, :stale_version} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 2},
               %{self_uri: Task8Fixtures.owner()}
             )

    assert Agent.get(state, & &1.counts) == %{}
  end

  test "locked terminal proof rejects every mutable operation-coordinate drift", %{state: state} do
    mutants = [
      :wrong_suffix,
      :extra_suffix,
      :backend_pair,
      :expected_connection_version,
      :expected_credential_version,
      :bound_input_digest,
      :provider_handoff,
      :credential_handoff
    ]

    Enum.each(mutants, fn mutant ->
      connection =
        Task8Fixtures.connection(%{
          connection_version: 30,
          credential_version: 3,
          external_account_id: "terminal-mutant-#{mutant}"
        })

      _attempt = Task8Fixtures.attempt(connection)

      Agent.update(state, fn current ->
        current
        |> put_in([:replies, :provider_revoke], {:error, :backend_unavailable})
      end)

      args = %{connection_id: connection.connection_id, expected_version: 30}
      ctx = %{self_uri: Task8Fixtures.owner()}

      assert {:error, :authorization_backend_unavailable} = Store.execute(:revoke, args, ctx)

      Agent.update(state, fn current ->
        update_in(current, [:replies], &Map.delete(&1, :provider_revoke))
      end)

      operations =
        Repo.all(
          from(row in Operation,
            where: row.connection_id == ^connection.connection_id,
            order_by: [asc: row.correlation_id]
          )
        )

      provider = Enum.find(operations, &String.ends_with?(&1.correlation_id, ":provider"))
      credential = Enum.find(operations, &String.ends_with?(&1.correlation_id, ":credential"))

      mutate_terminal_operation!(mutant, connection, provider, credential)

      assert {:error, _reason} = Store.execute(:revoke, args, ctx)

      assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
               "revoking"
    end)
  end

  test "terminal request closes immediately while a callback reservation remains an obligation",
       %{
         state: state
       } do
    connection = Task8Fixtures.connection(%{connection_version: 3})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "consuming",
        claim_token: "callback-winner",
        attempt_version: 1
      })

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 3},
               %{self_uri: Task8Fixtures.owner()}
             )

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
             "revoking"

    assert %{provider_revoke: 1, credential_revoke: 1} = Agent.get(state, & &1.counts)

    attempt
    |> Ecto.Changeset.change(status: "consumed", claim_token: nil, claim_until: nil)
    |> Repo.update!()

    assert {:ok, %{status: "revoked", version: 5}} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 3},
               %{self_uri: Task8Fixtures.owner()}
             )
  end

  test "terminal release rejects a fenced label without a shredded handoff proof" do
    connection = Task8Fixtures.connection(%{connection_version: 3})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "cancelled",
        attempt_version: 1
      })

    callback_operation = fenced_callback_operation!(connection, attempt)
    _backend_record = consumed_backend_record!(connection, attempt)

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 3},
               %{self_uri: Task8Fixtures.owner()}
             )

    assert Repo.get!(Operation, callback_operation.id).status == "fenced"

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
             "revoking"
  end

  test "terminal release rejects a forged cancelled backend row without durable absence proof" do
    connection = Task8Fixtures.connection(%{connection_version: 3})

    attempt =
      Task8Fixtures.attempt(connection, %{
        status: "cancelled",
        attempt_version: 1
      })

    callback_operation = fenced_callback_operation!(connection, attempt)
    _backend_record = cancelled_backend_record!(connection, attempt)

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 3},
               %{self_uri: Task8Fixtures.owner()}
             )

    assert Repo.get!(Operation, callback_operation.id).status == "fenced"

    assert Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id).status ==
             "revoking"
  end

  defp scope(connection),
    do: %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      execution_identity: connection.execution_identity
    }

  defp mutate_terminal_operation!(:wrong_suffix, _connection, provider, _credential) do
    provider
    |> Ecto.Changeset.change(correlation_id: provider.correlation_id <> "-x")
    |> Repo.update!()
  end

  defp mutate_terminal_operation!(:extra_suffix, connection, _provider, _credential) do
    %{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      backend_pair_id: connection.backend_pair_id,
      operation_class: "revoke",
      correlation_id: "termination:revoke:#{connection.connection_id}:30:extra",
      bound_input_digest: "extra-terminal-operation",
      expected_connection_version: 30,
      expected_credential_version: connection.credential_version,
      next_recovery_at: DateTime.utc_now(),
      status: "prepared"
    }
    |> Operation.create_changeset()
    |> Repo.insert!()
  end

  defp mutate_terminal_operation!(:backend_pair, _connection, provider, _credential) do
    replace_terminal_operation!(provider, backend_pair_id: "pair-drift")
  end

  defp mutate_terminal_operation!(
         :expected_connection_version,
         _connection,
         provider,
         _credential
       ) do
    replace_terminal_operation!(provider,
      expected_connection_version: provider.expected_connection_version + 1
    )
  end

  defp mutate_terminal_operation!(
         :expected_credential_version,
         _connection,
         provider,
         _credential
       ) do
    replace_terminal_operation!(provider,
      expected_credential_version: provider.expected_credential_version + 1
    )
  end

  defp mutate_terminal_operation!(:bound_input_digest, _connection, provider, _credential) do
    provider
    |> Ecto.Changeset.change(bound_input_digest: "terminal-digest-drift")
    |> Repo.update!()
  end

  defp mutate_terminal_operation!(:provider_handoff, connection, provider, _credential) do
    provider
    |> Ecto.Changeset.change(handoff_ref: connection.credential_backend_ref)
    |> Repo.update!()
  end

  defp mutate_terminal_operation!(:credential_handoff, _connection, _provider, credential) do
    credential
    |> Ecto.Changeset.change(handoff_ref: "credential-ref-drift")
    |> Repo.update!()
  end

  # The database correctly makes these coordinates update-immutable. Replacing the
  # row models a malformed/legacy durable row so the application proof is still
  # exercised instead of merely re-testing the update trigger.
  defp replace_terminal_operation!(operation, changes) do
    fields = Operation.__schema__(:fields)

    attrs =
      operation
      |> Map.take(fields)
      |> Map.merge(Map.new(changes))
      |> Map.put(:id, Ecto.UUID.generate())

    Repo.delete!(operation)
    Repo.insert!(struct(Operation, attrs))
  end

  defp fenced_callback_operation!(connection, attempt) do
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
      attempt_claim_token: nil,
      prior_credential_ref: connection.credential_backend_ref,
      prior_credential_version: connection.credential_version,
      next_recovery_at: now,
      status: "fenced",
      safe_error_code: "connection_terminal"
    })
    |> Repo.insert!()
  end

  defp consumed_backend_record!(connection, attempt) do
    now = DateTime.utc_now()

    %AuthorizationBackendRecord{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      execution_identity: connection.execution_identity,
      key_id: "test-v1",
      key_fingerprint: <<1>>,
      nonce: <<2>>,
      ciphertext: <<3>>,
      bound_input_digest: "digest",
      begin_correlation_id: attempt.correlation_id,
      owner_uri: connection.owner_uri,
      connection_id: connection.connection_id,
      connection_version: attempt.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      handoff_ref: "issued-handoff",
      handoff_ciphertext: "sealed-handoff",
      lifecycle_status: "consumed",
      expires_at: DateTime.add(now, 3_600, :second),
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp cancelled_backend_record!(connection, attempt) do
    now = DateTime.utc_now()

    %AuthorizationBackendRecord{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      execution_identity: connection.execution_identity,
      key_id: "test-v1",
      key_fingerprint: <<1>>,
      nonce: <<2>>,
      ciphertext: <<3>>,
      bound_input_digest: "digest",
      begin_correlation_id: attempt.correlation_id,
      owner_uri: connection.owner_uri,
      connection_id: connection.connection_id,
      connection_version: attempt.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      consume_correlation_id: attempt.correlation_id,
      consume_input_digest: "consume-digest",
      lifecycle_status: "cancelled",
      expires_at: DateTime.add(now, 3_600, :second),
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end
end
