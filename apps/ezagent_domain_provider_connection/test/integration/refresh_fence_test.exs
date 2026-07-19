Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RefreshFenceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    BackendPairRegistry,
    DriverRegistry,
    Operation,
    RuntimeBindings,
    Store
  }

  alias Ezagent.ProviderConnection.Test.Task8CredentialBackend
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

  test "refresh exposes no claim or release mutation bypass" do
    refute function_exported?(Ezagent.ProviderConnection.Refresh, :claim, 1)
    refute function_exported?(Ezagent.ProviderConnection.Refresh, :claim, 3)
    refute function_exported?(Ezagent.ProviderConnection.Refresh, :release, 3)
    refute function_exported?(Ezagent.ProviderConnection.Refresh, :release, 4)
  end

  test "refresh persists, fences, replaces, CASes, and revokes the prior pointer exactly once", %{
    state: state
  } do
    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 5,
        credential_version: 2
      })

    _attempt = Task8Fixtures.attempt(connection)

    args = %{
      connection_id: connection.connection_id,
      expected_version: 5,
      correlation_id: "refresh-1"
    }

    ctx = %{self_uri: Task8Fixtures.owner()}

    assert {:ok, first} = Store.execute(:refresh, args, ctx)
    assert {:ok, ^first} = Store.execute(:refresh, args, ctx)
    assert first.status == "active"
    assert first.version == 7

    updated = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert updated.credential_backend_ref == "credential-ref-1"
    assert updated.credential_version == 3
    assert %{refresh: 1, replace: 1, credential_revoke: 1} = Agent.get(state, & &1.counts)

    assert %Operation{status: "finalized"} =
             Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "refresh-1")
  end

  test "a result returned after lease loss is compensated and cannot overwrite the pointer", %{
    state: state
  } do
    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    _attempt = Task8Fixtures.attempt(connection)
    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :replace], test_pid))

    task =
      Task.async(fn ->
        Store.execute(
          :refresh,
          %{
            connection_id: connection.connection_id,
            expected_version: 2,
            correlation_id: "refresh-stale"
          },
          %{self_uri: Task8Fixtures.owner()}
        )
      end)

    assert_receive {:task8_barrier, :replace, worker, _context}

    connection
    |> Repo.reload!()
    |> Ecto.Changeset.change(refresh_lease_token: "winner", refresh_lease_version: 99)
    |> Repo.update!()

    send(worker, {:release_task8, :replace})
    assert {:error, :refresh_lease_lost} = Task.await(task)

    updated = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert updated.credential_backend_ref == "credential-ref-old"
    assert %{refresh: 1, replace: 1, credential_revoke: 1} = Agent.get(state, & &1.counts)

    assert %Operation{status: "cleanup_pending"} =
             Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "refresh-stale")
  end

  test "at the exact lease deadline a new claim wins and the old worker cannot call replace", %{
    state: state
  } do
    now = DateTime.utc_now()

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :refresh], test_pid))

    old =
      Task.async(fn ->
        Store.execute(
          :refresh,
          %{
            connection_id: connection.connection_id,
            expected_version: 2,
            correlation_id: "old-boundary"
          },
          %{self_uri: Task8Fixtures.owner(), now: now}
        )
      end)

    assert_receive {:task8_barrier, :refresh, old_worker, _context}

    operation =
      Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "old-boundary")

    operation |> Ecto.Changeset.change(lease_until: now) |> Repo.update!()
    current = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    current |> Ecto.Changeset.change(refresh_lease_until: now) |> Repo.update!()

    Agent.update(
      state,
      &update_in(&1.barriers, fn barriers -> Map.delete(barriers, :refresh) end)
    )

    assert {:ok, %{status: "active", version: 5}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 3,
                 correlation_id: "new-boundary"
               },
               %{self_uri: Task8Fixtures.owner(), now: now}
             )

    send(old_worker, {:release_task8, :refresh})
    assert {:error, :refresh_lease_lost} = Task.await(old)
    assert %{refresh: 2, replace: 1} = Agent.get(state, & &1.counts)
  end

  test "backend response loss retries the same correlation and logical credential", %{
    state: state
  } do
    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :replace], test_pid))

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "response-loss"
    }

    task = Task.async(fn -> Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner()}) end)
    assert_receive {:task8_barrier, :replace, _worker, _context}
    Task.shutdown(task, :brutal_kill)

    Agent.update(
      state,
      &update_in(&1.barriers, fn barriers -> Map.delete(barriers, :replace) end)
    )

    assert {:ok, %{status: "active"}} =
             Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner()})

    operation =
      Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "response-loss")

    assert operation.result_ref == "credential-ref-1"
    assert %{replace: 2} = Agent.get(state, & &1.counts)
    assert map_size(Agent.get(state, & &1.results)) == 1
  end

  test "refresh retry resolves the full D0 key and rejects a changed durable digest", %{
    state: state
  } do
    connection =
      Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :refresh], test_pid))

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "d0-digest-retry"
    }

    first =
      Task.async(fn -> Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner()}) end)

    assert_receive {:task8_barrier, :refresh, _worker, _context}
    Task.shutdown(first, :brutal_kill)

    operation =
      Repo.get_by!(Operation,
        backend_pair_id: "pair-task8-v1",
        operation_class: "refresh",
        correlation_id: args.correlation_id
      )

    operation |> Ecto.Changeset.change(bound_input_digest: "changed") |> Repo.update!()
    Agent.update(state, &put_in(&1, [:barriers, :refresh], nil))

    assert {:error, :correlation_conflict} =
             Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner()})

    assert %{refresh: 1} = Agent.get(state, & &1.counts)
  end

  test "refresh lookup ignores the same class and correlation under another backend pair" do
    connection =
      Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    %{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      backend_pair_id: "other-pair",
      operation_class: "refresh",
      correlation_id: "pair-scoped-correlation",
      bound_input_digest: "other-digest",
      expected_connection_version: 2,
      status: "finalized"
    }
    |> Operation.create_changeset()
    |> Repo.insert!()

    assert {:ok, %{status: "active"}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "pair-scoped-correlation"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    assert Repo.get_by!(Operation,
             backend_pair_id: "pair-task8-v1",
             operation_class: "refresh",
             correlation_id: "pair-scoped-correlation"
           )
  end

  test "runtime binding rejects an operation pair that disagrees with the connection" do
    connection = Task8Fixtures.connection()
    operation = %Operation{backend_pair_id: "different-pair"}

    assert {:error, :authorization_backend_unavailable} =
             RuntimeBindings.resolve(connection, operation)
  end

  test "task8 credential fake reconciles correlation plus canonical digest", %{state: state} do
    command = %{
      backend_pair_id: "pair-task8-v1",
      operation_class: "refresh",
      correlation_id: "fake-d0",
      bound_input_digest: "digest-a",
      expected_credential_version: 2,
      credential_material: "secret"
    }

    assert {:ok, first} = Task8CredentialBackend.replace(command)
    assert {:ok, ^first} = Task8CredentialBackend.replace(command)

    assert {:error, :correlation_conflict} =
             Task8CredentialBackend.replace(%{command | bound_input_digest: "digest-b"})

    assert {:error, :correlation_conflict} =
             Task8CredentialBackend.replace(%{command | credential_material: "changed-secret"})

    assert map_size(Agent.get(state, & &1.results)) == 1
  end

  test "backend-committed recovery applies its durable normalized metadata" do
    now = DateTime.utc_now()

    connection =
      Task8Fixtures.connection(%{
        status: "refreshing",
        connection_version: 6,
        credential_version: 2
      })
      |> Ecto.Changeset.change(
        refresh_lease_token: "lease-1",
        refresh_lease_until: DateTime.add(now, 30, :second),
        refresh_lease_version: 1
      )
      |> Repo.update!()

    %Operation{}
    |> Ecto.Changeset.change(%{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      backend_pair_id: connection.backend_pair_id,
      operation_class: "refresh",
      correlation_id: "metadata-recovery",
      bound_input_digest: refresh_digest(connection, "pair-task8-v1", 5, "metadata-recovery"),
      expected_connection_version: 5,
      expected_credential_version: 2,
      attempt_version: 1,
      lease_token: "lease-1",
      lease_until: DateTime.add(now, 30, :second),
      prior_credential_ref: "credential-ref-old",
      prior_credential_version: 2,
      result_ref: "credential-ref-new",
      result_credential_version: 3,
      result_permission_digest: "durable-permissions",
      result_expires_at: DateTime.add(now, 7_200, :second),
      status: "backend_committed"
    })
    |> Repo.insert!()

    assert {:ok, %{status: "active", version: 7}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 5,
                 correlation_id: "metadata-recovery"
               },
               %{self_uri: Task8Fixtures.owner(), now: now}
             )

    updated = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert updated.permission_digest == "durable-permissions"
    assert updated.expires_at == DateTime.add(now, 7_200, :second)
  end

  test "runtime binding comes from the active pointer, never the latest attempt" do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 1})

    _unrelated_latest_attempt =
      Task8Fixtures.attempt(connection, %{backend_pair_id: "unregistered-latest-pair"})

    assert {:ok, %{status: "active", version: 3}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 1,
                 correlation_id: "connection-pair-sot"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    updated = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert updated.backend_pair_id == "pair-task8-v1"
    assert updated.authorization_backend_id == "local-authorization-v1"
    assert updated.credential_backend_id == "credential-task8-v1"
  end

  defp refresh_digest(connection, pair_id, expected_version, correlation_id) do
    {:refresh_v1, connection.connection_id, connection.workspace_uri, connection.owner_uri,
     connection.provider_id, connection.governed_host, connection.execution_identity,
     connection.acquisition_method, expected_version, pair_id, "refresh", correlation_id}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
