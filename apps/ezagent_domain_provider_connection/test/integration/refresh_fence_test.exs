Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/fake_backend_pairs.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RefreshFenceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    BackendPairRegistry,
    DriverRegistry,
    Operation,
    Refresh,
    RuntimeBindings,
    Store
  }

  alias Ezagent.ProviderConnection.Test.Task8CredentialBackend
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
    Application.delete_env(:ezagent_domain_provider_connection, :refresh_crash_barrier)
    Application.delete_env(:ezagent_domain_provider_connection, :refresh_exchange_fence_barrier)
    Application.delete_env(:ezagent_domain_provider_connection, :refresh_use_observer)
    Application.delete_env(:ezagent_domain_provider_connection, :task8_refresh_replay_probe)
    Application.delete_env(:ezagent_domain_provider_connection, :task8_remote_refresh)

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)
      Application.delete_env(:ezagent_domain_provider_connection, :task8_effect_state)
      Application.delete_env(:ezagent_domain_provider_connection, :refresh_crash_barrier)

      Application.delete_env(
        :ezagent_domain_provider_connection,
        :refresh_exchange_fence_barrier
      )

      Application.delete_env(:ezagent_domain_provider_connection, :refresh_use_observer)
      Application.delete_env(:ezagent_domain_provider_connection, :task8_refresh_replay_probe)
      Application.delete_env(:ezagent_domain_provider_connection, :task8_remote_refresh)

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

  test "refresh scope is invalidated when backend begin rejects before Driver invocation", %{
    state: state
  } do
    test_pid = self()

    Agent.update(
      state,
      &put_in(&1, [:replies, :begin_refresh_exchange], {:capture_and_error, test_pid})
    )

    connection =
      Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    assert {:error, :correlation_conflict} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "refresh-begin-rejected"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    assert_receive {:task8_refresh_scope, authority}
    monitor = Process.monitor(authority)
    assert_receive {:DOWN, ^monitor, :process, ^authority, _reason}
    refute Map.has_key?(Agent.get(state, & &1.counts), :refresh)
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

  test "foreign concurrent facade replay loses while the invocation owner effects exactly once",
       %{
         state: state
       } do
    Application.put_env(
      :ezagent_domain_provider_connection,
      :task8_refresh_replay_probe,
      self()
    )

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    assert {:ok, %{status: "active"}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "concurrent-facade-replay"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    assert_receive {:task8_refresh_replay_result, {:error, :correlation_conflict}}
    assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) == 1
  end

  test "remote endpoint exits after a successful consume", %{state: state} do
    owner = self()
    Application.put_env(:ezagent_domain_provider_connection, :task8_remote_refresh, true)

    Application.put_env(
      :ezagent_domain_provider_connection,
      :refresh_use_observer,
      fn shape, use -> send(owner, {:observed_refresh_use, shape, use}) end
    )

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    assert {:ok, %{status: "active"}} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "remote-successful-consume"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    assert_receive {:observed_refresh_use, :remote_proxy, proxy_use}

    endpoint =
      proxy_use
      |> Ezagent.ProviderConnection.CredentialBackend.RefreshUse.private()
      |> Map.fetch!(:endpoint)

    refute Process.alive?(endpoint)
    assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) == 1
  end

  test "both backend shapes reject a reclaimed exact lease at every private exchange phase", %{
    state: state
  } do
    Enum.each(
      [
        {Task8CredentialBackend, :before_credential_injection, 0},
        {Task8CredentialBackend, :before_provider_use, 0},
        {Task8CredentialBackend, :after_provider_use, 1},
        {Ezagent.ProviderConnection.Test.FakeCredentialBeta, :before_credential_injection, 0},
        {Ezagent.ProviderConnection.Test.FakeCredentialBeta, :before_provider_use, 0},
        {Ezagent.ProviderConnection.Test.FakeCredentialBeta, :after_provider_use, 1}
      ],
      fn {backend, phase, expected_effects} ->
        effect_count_before = Map.get(Agent.get(state, & &1.counts), :refresh, 0)

        connection =
          Task8Fixtures.connection(%{
            status: "refresh_required",
            connection_version: 2,
            credential_version: 4
          })

        Application.put_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations,
          %{"credential-task8-v1" => backend}
        )

        assert {:ok, _pair, _driver, ^backend} = RuntimeBindings.resolve(connection)

        install_exchange_fence_barrier(phase, self())
        correlation_id = "lease-fence-#{inspect(backend)}-#{phase}"

        task =
          Task.async(fn ->
            Store.execute(
              :refresh,
              %{
                connection_id: connection.connection_id,
                expected_version: 2,
                correlation_id: correlation_id
              },
              %{self_uri: Task8Fixtures.owner()}
            )
          end)

        assert_receive {:refresh_exchange_fence_barrier, ^phase, worker, binding}
        operation = Repo.get!(Operation, binding.operation_id)
        replacement_token = "reclaimed-#{Ecto.UUID.generate()}"
        replacement_version = operation.attempt_version + 1
        replacement_deadline = DateTime.add(operation.lease_until, 30, :second)

        operation
        |> Ecto.Changeset.change(
          lease_token: replacement_token,
          attempt_version: replacement_version,
          lease_until: replacement_deadline
        )
        |> Repo.update!()

        connection
        |> Repo.reload!()
        |> Ecto.Changeset.change(
          refresh_lease_token: replacement_token,
          refresh_lease_version: replacement_version,
          refresh_lease_until: replacement_deadline
        )
        |> Repo.update!()

        send(worker, {:release_refresh_exchange_fence_barrier, phase})
        assert {:error, :correlation_conflict} = Task.await(task)

        assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) ==
                 effect_count_before + expected_effects

        persisted = Repo.reload!(operation)
        assert persisted.status == "prepared"
        assert is_nil(persisted.provider_result_ref)

        Application.delete_env(
          :ezagent_domain_provider_connection,
          :refresh_exchange_fence_barrier
        )
      end
    )
  end

  test "both backend shapes reject lease reclaim before private capture", %{state: state} do
    Enum.each(
      [Task8CredentialBackend, Ezagent.ProviderConnection.Test.FakeCredentialBeta],
      fn backend ->
        effect_count_before = Map.get(Agent.get(state, & &1.counts), :refresh, 0)

        connection =
          Task8Fixtures.connection(%{
            status: "refresh_required",
            connection_version: 2,
            credential_version: 4
          })

        Application.put_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations,
          %{"credential-task8-v1" => backend}
        )

        install_exchange_fence_barrier(:before_capture, self())
        correlation_id = "pre-capture-reclaim-#{inspect(backend)}"

        task =
          Task.async(fn ->
            Store.execute(
              :refresh,
              %{
                connection_id: connection.connection_id,
                expected_version: 2,
                correlation_id: correlation_id
              },
              %{self_uri: Task8Fixtures.owner()}
            )
          end)

        assert_receive {:refresh_exchange_fence_barrier, :before_capture, worker, binding}
        operation = Repo.get!(Operation, binding.operation_id)
        assert binding.expected_refresh_lease_token == operation.lease_token
        assert binding.expected_refresh_lease_version == operation.attempt_version
        assert binding.expected_refresh_lease_deadline == operation.lease_until
        refute Map.has_key?(Map.from_struct(operation), :expected_refresh_lease_token)
        refute inspect(operation) =~ operation.lease_token
        replacement_token = "pre-capture-#{Ecto.UUID.generate()}"
        replacement_version = operation.attempt_version + 1
        replacement_deadline = DateTime.add(operation.lease_until, 30, :second)

        operation
        |> Ecto.Changeset.change(
          lease_token: replacement_token,
          attempt_version: replacement_version,
          lease_until: replacement_deadline
        )
        |> Repo.update!()

        connection
        |> Repo.reload!()
        |> Ecto.Changeset.change(
          refresh_lease_token: replacement_token,
          refresh_lease_version: replacement_version,
          refresh_lease_until: replacement_deadline
        )
        |> Repo.update!()

        send(worker, {:release_refresh_exchange_fence_barrier, :before_capture})
        assert {:error, :correlation_conflict} = Task.await(task)
        assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) == effect_count_before

        Application.delete_env(
          :ezagent_domain_provider_connection,
          :refresh_exchange_fence_barrier
        )
      end
    )
  end

  test "authority death invalidates both backend shapes before provider effect", %{state: state} do
    Enum.each(
      [Task8CredentialBackend, Ezagent.ProviderConnection.Test.FakeCredentialBeta],
      fn backend ->
        effect_count_before = Map.get(Agent.get(state, & &1.counts), :refresh, 0)

        connection =
          Task8Fixtures.connection(%{
            status: "refresh_required",
            connection_version: 2,
            credential_version: 4
          })

        Application.put_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations,
          %{"credential-task8-v1" => backend}
        )

        owner = self()

        Application.put_env(
          :ezagent_domain_provider_connection,
          :refresh_use_observer,
          fn shape, use -> send(owner, {:observed_refresh_use, shape, use}) end
        )

        install_exchange_fence_barrier(:before_credential_injection, self())

        task =
          Task.async(fn ->
            Store.execute(
              :refresh,
              %{
                connection_id: connection.connection_id,
                expected_version: 2,
                correlation_id: "authority-death-#{inspect(backend)}"
              },
              %{self_uri: Task8Fixtures.owner()}
            )
          end)

        use = receive_observed_use(backend)
        authority = Ezagent.ProviderConnection.CredentialBackend.RefreshUse.authority(use)
        authority_monitor = Process.monitor(authority)

        assert_receive {:refresh_exchange_fence_barrier, :before_credential_injection, worker,
                        _binding}

        Process.exit(authority, :kill)
        assert_receive {:DOWN, ^authority_monitor, :process, ^authority, :killed}
        send(worker, {:release_refresh_exchange_fence_barrier, :before_credential_injection})

        assert {:error, :correlation_conflict} = Task.await(task)

        assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) == effect_count_before

        if backend == Ezagent.ProviderConnection.Test.FakeCredentialBeta do
          endpoint =
            use
            |> Ezagent.ProviderConnection.CredentialBackend.RefreshUse.private()
            |> Map.fetch!(:endpoint)

          eventually(fn -> refute Process.alive?(endpoint) end)
        end

        Application.delete_env(:ezagent_domain_provider_connection, :refresh_use_observer)

        Application.delete_env(
          :ezagent_domain_provider_connection,
          :refresh_exchange_fence_barrier
        )
      end
    )
  end

  test "claimed owner death cannot reuse a remote scope and recovery mints a fresh scope", %{
    state: state
  } do
    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      %{"credential-task8-v1" => Ezagent.ProviderConnection.Test.FakeCredentialBeta}
    )

    owner = self()

    Application.put_env(
      :ezagent_domain_provider_connection,
      :refresh_use_observer,
      fn shape, use -> send(owner, {:observed_refresh_use, shape, use}) end
    )

    install_exchange_fence_barrier(:before_credential_injection, self())

    task =
      Task.async(fn ->
        Store.execute(
          :refresh,
          %{
            connection_id: connection.connection_id,
            expected_version: 2,
            correlation_id: "claimed-owner-death"
          },
          %{self_uri: Task8Fixtures.owner()}
        )
      end)

    proxy_use = receive_observed_use(Ezagent.ProviderConnection.Test.FakeCredentialBeta)
    authority = Ezagent.ProviderConnection.CredentialBackend.RefreshUse.authority(proxy_use)

    endpoint =
      proxy_use
      |> Ezagent.ProviderConnection.CredentialBackend.RefreshUse.private()
      |> Map.fetch!(:endpoint)

    authority_monitor = Process.monitor(authority)
    endpoint_monitor = Process.monitor(endpoint)

    assert_receive {:refresh_exchange_fence_barrier, :before_credential_injection, ^endpoint,
                    _binding}

    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^authority_monitor, :process, ^authority, _reason}
    send(endpoint, {:release_refresh_exchange_fence_barrier, :before_credential_injection})
    assert_receive {:DOWN, ^endpoint_monitor, :process, ^endpoint, _reason}

    assert {:error, :correlation_conflict} =
             Ezagent.ProviderConnection.Test.RemoteRefreshExchangeEndpoint.consume(
               Ezagent.ProviderConnection.Test.FakeCredentialBeta,
               %{
                 refresh_use: proxy_use,
                 provider_exchange: fn _ -> flunk("old scope effected") end
               }
             )

    assert Map.get(Agent.get(state, & &1.counts), :refresh, 0) == 0

    operation =
      Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "claimed-owner-death")

    now = DateTime.utc_now()
    expired = DateTime.add(now, -1, :second)
    operation |> Ecto.Changeset.change(lease_until: expired) |> Repo.update!()

    connection
    |> Repo.reload!()
    |> Ecto.Changeset.change(refresh_lease_until: expired)
    |> Repo.update!()

    Application.delete_env(:ezagent_domain_provider_connection, :refresh_use_observer)

    Application.delete_env(
      :ezagent_domain_provider_connection,
      :refresh_exchange_fence_barrier
    )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      Task8Fixtures.credential_implementations()
    )

    recovery_result = Refresh.recover(operation, now)
    assert {:ok, %{status: "active"}} = recovery_result
    assert Map.get(Agent.get(state, & &1.counts), :reconcile_refresh, 0) >= 1
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

    assert %{
             refresh: 1,
             replace: 1,
             discard_refresh_result: 1,
             credential_revoke: 1
           } = Agent.get(state, & &1.counts)

    assert %Operation{
             status: "finalized",
             provider_cleanup_status: "confirmed",
             credential_cleanup_status: "confirmed"
           } =
             Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "refresh-stale")
  end

  test "refresh loser preserves each cleanup confirmation while retrying its failed sibling", %{
    state: state
  } do
    Enum.each(
      [
        {:discard_refresh_result, :provider_cleanup_status, :credential_cleanup_status},
        {:credential_revoke, :credential_cleanup_status, :provider_cleanup_status}
      ],
      fn {failed_effect, failed_field, confirmed_field} ->
        connection =
          Task8Fixtures.connection(%{
            status: "refresh_required",
            connection_version: 2,
            credential_version: 4
          })

        correlation_id = "asymmetric-#{failed_effect}"
        test_pid = self()

        Agent.update(state, fn current ->
          current
          |> put_in([:barriers, :replace], test_pid)
          |> put_in([:replies, failed_effect], {:error, :backend_unavailable})
        end)

        task =
          Task.async(fn ->
            Store.execute(
              :refresh,
              %{
                connection_id: connection.connection_id,
                expected_version: 2,
                correlation_id: correlation_id
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

        operation =
          Repo.get_by!(Operation, operation_class: "refresh", correlation_id: correlation_id)

        assert operation.status == "cleanup_pending"
        assert Map.fetch!(operation, failed_field) == "pending"
        assert Map.fetch!(operation, confirmed_field) == "confirmed"

        confirmed_count =
          Agent.get(state, fn current ->
            Map.get(current.counts, confirmed_effect(failed_effect), 0)
          end)

        Agent.update(state, fn current ->
          current
          |> update_in([:replies], &Map.delete(&1, failed_effect))
          |> update_in([:barriers], &Map.delete(&1, :replace))
        end)

        assert {:error, :refresh_lease_lost} =
                 Store.execute(
                   :refresh,
                   %{
                     connection_id: connection.connection_id,
                     expected_version: 2,
                     correlation_id: correlation_id
                   },
                   %{self_uri: Task8Fixtures.owner()}
                 )

        finalized = Repo.get!(Operation, operation.id)
        assert finalized.status == "finalized"
        assert finalized.provider_cleanup_status == "confirmed"
        assert finalized.credential_cleanup_status == "confirmed"

        assert Agent.get(state, fn current ->
                 Map.get(current.counts, confirmed_effect(failed_effect), 0)
               end) == confirmed_count
      end
    )
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

    assert {:error, :refresh_in_progress} =
             Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner()})

    prepared =
      Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "response-loss")

    assert {:ok, %{status: "active"}} =
             Store.execute(:refresh, args, %{
               self_uri: Task8Fixtures.owner(),
               now: prepared.lease_until
             })

    operation =
      Repo.get_by!(Operation, operation_class: "refresh", correlation_id: "response-loss")

    assert operation.result_ref == "credential-ref-1"
    assert %{replace: 2} = Agent.get(state, & &1.counts)
    assert map_size(Agent.get(state, & &1.results)) == 1
  end

  test "provider response loss reconciles in a fresh scope without repeating the provider effect",
       %{
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

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "provider-response-loss"
    }

    task =
      Task.async(fn ->
        Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner(), now: now})
      end)

    assert_receive {:task8_barrier, :refresh, _worker, first_context}
    Task.shutdown(task, :brutal_kill)

    refute Map.has_key?(first_context, :lease_token)
    refute Map.has_key?(first_context, :attempt_version)
    refute Map.has_key?(first_context, :expected_refresh_lease_token)
    refute Map.has_key?(first_context, :expected_refresh_lease_version)
    refute Map.has_key?(first_context, :expected_refresh_lease_deadline)
    refute inspect(first_context.refresh_use) =~ "credential-ref-old"

    Agent.update(
      state,
      &update_in(&1.barriers, fn barriers -> Map.delete(barriers, :refresh) end)
    )

    operation =
      Repo.get_by!(Operation,
        operation_class: "refresh",
        correlation_id: "provider-response-loss"
      )

    assert {:ok, %{status: "active"}} =
             Store.execute(:refresh, args, %{
               self_uri: Task8Fixtures.owner(),
               now: operation.lease_until
             })

    assert %{refresh: 1, reconcile_refresh: 2, replace: 1} = Agent.get(state, & &1.counts)
  end

  test "sealed provider result survives a coordinator crash before its ownership journal",
       %{state: state} do
    now = DateTime.utc_now()

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "sealed-result-before-provider-journal"
    }

    install_refresh_crash_barrier(:sealed_provider_result, self())

    task =
      Task.async(fn ->
        Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner(), now: now})
      end)

    assert_receive {:refresh_crash_barrier, :sealed_provider_result, worker, barrier_context}
    assert barrier_context.operation_id
    assert barrier_context.provider_result_ref == "task8-refresh-result:" <> args.correlation_id

    unjournaled =
      Repo.get_by!(Operation,
        operation_class: "refresh",
        correlation_id: args.correlation_id
      )

    assert unjournaled.status == "prepared"
    assert is_nil(unjournaled.provider_result_ref)
    assert is_nil(unjournaled.handoff_ref)
    assert %{refresh: 1} = Agent.get(state, & &1.counts)
    assert Map.get(Agent.get(state, & &1.counts), :reconcile_refresh, 0) == 1

    Task.shutdown(task, :brutal_kill)
    refute Process.alive?(worker)
    Application.delete_env(:ezagent_domain_provider_connection, :refresh_crash_barrier)

    assert {:ok, %{status: "active"}} = Refresh.recover(unjournaled, unjournaled.lease_until)

    finalized = Repo.reload!(unjournaled)
    assert finalized.status == "finalized"
    assert finalized.provider_result_ref == barrier_context.provider_result_ref
    assert finalized.result_ref == "credential-ref-1"

    assert %{refresh: 1, reconcile_refresh: 2, replace: 1, credential_revoke: 1} =
             Agent.get(state, & &1.counts)
  end

  test "credential ownership journal survives a coordinator crash before pointer CAS", %{
    state: state
  } do
    now = DateTime.utc_now()

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "credential-journal-before-pointer-cas"
    }

    install_refresh_crash_barrier(:credential_ownership_journaled, self())

    task =
      Task.async(fn ->
        Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner(), now: now})
      end)

    assert_receive {:refresh_crash_barrier, :credential_ownership_journaled, worker,
                    barrier_context}

    journaled = Repo.get!(Operation, barrier_context.operation_id)
    assert journaled.status == "backend_committed"
    assert journaled.provider_result_ref == "task8-refresh-result:" <> args.correlation_id
    assert journaled.result_ref == "credential-ref-1"
    assert journaled.result_credential_version == 5
    assert %{refresh: 1, replace: 1} = Agent.get(state, & &1.counts)

    Task.shutdown(task, :brutal_kill)
    refute Process.alive?(worker)
    Application.delete_env(:ezagent_domain_provider_connection, :refresh_crash_barrier)

    assert {:ok, %{status: "active"}} = Refresh.recover(journaled, now)

    finalized = Repo.reload!(journaled)
    assert finalized.status == "finalized"
    assert %{refresh: 1, replace: 1, credential_revoke: 1} = Agent.get(state, & &1.counts)
  end

  test "provider result is journaled before a competing lease expires then continued under a fresh claim",
       %{state: state} do
    now = DateTime.utc_now()

    connection =
      Task8Fixtures.connection(%{
        status: "refresh_required",
        connection_version: 2,
        credential_version: 4
      })

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :refresh], test_pid))

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "provider-response-loss-competing-lease"
    }

    task =
      Task.async(fn ->
        Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner(), now: now})
      end)

    assert_receive {:task8_barrier, :refresh, _worker, _context}
    Task.shutdown(task, :brutal_kill)

    operation =
      Repo.get_by!(Operation,
        operation_class: "refresh",
        correlation_id: args.correlation_id
      )

    winner_until = DateTime.add(operation.lease_until, 30, :second)

    connection
    |> Repo.reload!()
    |> Ecto.Changeset.change(
      refresh_lease_token: "winner",
      refresh_lease_version: 99,
      refresh_lease_until: winner_until
    )
    |> Repo.update!()

    Agent.update(
      state,
      &update_in(&1.barriers, fn barriers -> Map.delete(barriers, :refresh) end)
    )

    assert {:error, :refresh_in_progress} = Refresh.recover(operation, operation.lease_until)

    recovered = Repo.reload!(operation)
    assert recovered.status == "prepared"
    assert is_nil(recovered.safe_error_code)
    assert recovered.provider_cleanup_status == "not_required"
    assert recovered.credential_cleanup_status == "not_required"
    assert is_nil(recovered.handoff_ref)
    assert is_nil(recovered.provider_result_ref)
    assert is_nil(recovered.result_ref)
    assert is_nil(recovered.result_credential_version)
    assert is_struct(recovered.next_recovery_at, DateTime)

    assert %{refresh: 1} = Agent.get(state, & &1.counts)

    refute Map.has_key?(Agent.get(state, & &1.counts), :replace)
    refute Map.has_key?(Agent.get(state, & &1.counts), :discard_refresh_result)

    assert {:ok, %{status: "active"}} = Refresh.recover(recovered, winner_until)

    finalized = Repo.reload!(operation)
    assert finalized.status == "finalized"
    assert finalized.result_ref == "credential-ref-1"
    assert finalized.result_credential_version == 5

    assert %{refresh: 1, reconcile_refresh: 2, replace: 1, credential_revoke: 1} =
             Agent.get(state, & &1.counts)

    refute Map.has_key?(Agent.get(state, & &1.counts), :discard_refresh_result)
  end

  test "recovery retries a proven not-completed provider effect under a fresh lease", %{
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
    Agent.update(state, &put_in(&1, [:barriers, :reconcile_refresh], test_pid))

    args = %{
      connection_id: connection.connection_id,
      expected_version: 2,
      correlation_id: "refresh-reconcile-not-completed"
    }

    task =
      Task.async(fn ->
        Store.execute(:refresh, args, %{self_uri: Task8Fixtures.owner(), now: now})
      end)

    assert_receive {:task8_barrier, :reconcile_refresh, _worker, _context}
    Task.shutdown(task, :brutal_kill)

    operation =
      Repo.get_by!(Operation,
        operation_class: "refresh",
        correlation_id: args.correlation_id
      )

    Agent.update(
      state,
      &update_in(&1.barriers, fn barriers -> Map.delete(barriers, :reconcile_refresh) end)
    )

    assert {:ok, %{status: "active"}} = Refresh.recover(operation, operation.lease_until)

    finalized = Repo.reload!(operation)
    assert finalized.status == "finalized"
    assert is_binary(finalized.provider_result_ref)
    assert finalized.result_ref == "credential-ref-1"

    assert %{reconcile_refresh: 2, refresh: 1, replace: 1, credential_revoke: 1} =
             Agent.get(state, & &1.counts)
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

    other_connection =
      Task8Fixtures.connection(%{
        backend_pair_id: "other-pair",
        authorization_backend_id: "other-authorization",
        credential_backend_id: "other-credential",
        connection_version: 4,
        credential_backend_ref: "other-credential-ref",
        credential_version: 1,
        permission_digest: "other-permission-digest"
      })

    %Operation{}
    |> Ecto.Changeset.change(
      workspace_uri: other_connection.workspace_uri,
      connection_id: other_connection.connection_id,
      backend_pair_id: "other-pair",
      operation_class: "refresh",
      correlation_id: "pair-scoped-correlation",
      bound_input_digest: "other-digest",
      expected_connection_version: 2,
      expected_authorization_ref: other_connection.authorization_backend_ref,
      expected_authorization_version: other_connection.authorization_version,
      expected_credential_version: 0,
      handoff_ref: "other-handoff-ref",
      result_ref: "other-credential-ref",
      result_credential_version: other_connection.credential_version,
      provider_result_ref: "other-provider-result-ref",
      result_permission_digest: "other-permission-digest",
      status: "finalized"
    )
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

  test "non-refresh runtime resolution still enforces the full backend contract" do
    connection = Task8Fixtures.connection(%{status: "active"})

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      %{"credential-task8-v1" => Task8Fixtures}
    )

    assert {:error, :authorization_backend_unavailable} = RuntimeBindings.resolve(connection)
  end

  test "refresh runtime resolution rejects every same-pair cross-binding axis" do
    connection =
      Task8Fixtures.connection(%{
        status: "refreshing",
        connection_version: 3,
        credential_version: 4
      })

    exact = %Operation{
      id: Ecto.UUID.generate(),
      operation_class: "refresh",
      status: "prepared",
      connection_id: connection.connection_id,
      workspace_uri: connection.workspace_uri,
      backend_pair_id: connection.backend_pair_id,
      expected_connection_version: 2,
      expected_authorization_ref: connection.authorization_backend_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version
    }

    assert {:ok, _pair, _driver, Task8CredentialBackend} =
             RuntimeBindings.resolve(connection, exact)

    mutations = [
      %{connection_id: Ecto.UUID.generate()},
      %{workspace_uri: URI.to_string(Ezagent.URI.workspace("other"))},
      %{expected_authorization_ref: "other-authorization-ref"},
      %{expected_authorization_version: connection.authorization_version + 1},
      %{expected_credential_version: connection.credential_version + 1},
      %{status: "connection_committed"}
    ]

    Enum.each(mutations, fn mutation ->
      operation = struct!(exact, mutation)

      assert {:error, :authorization_backend_unavailable} =
               RuntimeBindings.resolve(connection, operation)
    end)
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
      expected_authorization_ref: connection.authorization_backend_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: 2,
      attempt_version: 1,
      lease_token: "lease-1",
      lease_until: DateTime.add(now, 30, :second),
      prior_credential_ref: "credential-ref-old",
      prior_credential_version: 2,
      handoff_ref: "handoff-ref-new",
      result_ref: "credential-ref-new",
      result_credential_version: 3,
      provider_result_ref: "provider-result-new",
      result_permission_digest: "durable-permissions",
      result_expires_at: DateTime.add(now, 7_200, :second),
      next_recovery_at: now,
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

  test "different-pointer losers classify by advanced generation in every legal current status",
       %{
         state: state
       } do
    Enum.each(
      ["active", "refresh_required", "degraded", "expired", "revoking", "disconnecting"],
      fn current_status ->
        now = DateTime.utc_now()

        connection =
          Task8Fixtures.connection(%{
            status: "active",
            connection_version: 7,
            credential_backend_ref: "winner-credential-#{current_status}",
            credential_version: 9
          })
          |> Ecto.Changeset.change(status: current_status)
          |> Repo.update!()

        operation =
          %Operation{}
          |> Ecto.Changeset.change(%{
            workspace_uri: connection.workspace_uri,
            connection_id: connection.connection_id,
            backend_pair_id: connection.backend_pair_id,
            operation_class: "refresh",
            correlation_id: "different-pointer-#{current_status}",
            bound_input_digest:
              refresh_digest(
                connection,
                connection.backend_pair_id,
                5,
                "different-pointer-#{current_status}"
              ),
            expected_connection_version: 5,
            expected_authorization_ref: connection.authorization_backend_ref,
            expected_authorization_version: connection.authorization_version,
            expected_credential_version: 4,
            attempt_version: 1,
            lease_token: "old-lease-#{current_status}",
            lease_until: DateTime.add(now, -1, :second),
            prior_credential_ref: "prior-credential-#{current_status}",
            prior_credential_version: 4,
            handoff_ref: "loser-handoff-#{current_status}",
            result_ref: "loser-credential-#{current_status}",
            result_credential_version: 5,
            provider_result_ref: "loser-provider-result-#{current_status}",
            result_permission_digest: "loser-permission-#{current_status}",
            next_recovery_at: now,
            status: "backend_committed"
          })
          |> Repo.insert!()

        assert {:error, :refresh_lease_lost} = Refresh.recover(operation, now)

        cleanup = Repo.reload!(operation)
        assert cleanup.status == "cleanup_pending"
        assert cleanup.provider_cleanup_status == "pending"
        assert cleanup.provider_cleanup_error_code == "correlation_conflict"
        assert cleanup.credential_cleanup_status == "confirmed"

        unchanged = Repo.reload!(connection)
        assert unchanged.status == current_status
        assert unchanged.credential_backend_ref == "winner-credential-#{current_status}"
        assert unchanged.credential_version == 9
      end
    )

    assert Agent.get(state, &Map.get(&1.counts, :credential_revoke, 0)) == 6
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

  defp confirmed_effect(:discard_refresh_result), do: :credential_revoke
  defp confirmed_effect(:credential_revoke), do: :discard_refresh_result

  defp receive_observed_use(Ezagent.ProviderConnection.Test.FakeCredentialBeta) do
    assert_receive {:observed_refresh_use, :remote_proxy, use}
    use
  end

  defp receive_observed_use(_backend) do
    assert_receive {:observed_refresh_use, :protected, use}
    use
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end

  defp install_refresh_crash_barrier(expected_stage, owner) do
    Application.put_env(
      :ezagent_domain_provider_connection,
      :refresh_crash_barrier,
      fn stage, context ->
        if stage == expected_stage do
          send(owner, {:refresh_crash_barrier, stage, self(), context})

          receive do
            {:release_refresh_crash_barrier, ^stage} -> :ok
          end
        end

        :ok
      end
    )
  end

  defp install_exchange_fence_barrier(expected_phase, owner) do
    Application.put_env(
      :ezagent_domain_provider_connection,
      :refresh_exchange_fence_barrier,
      fn phase, binding ->
        if phase == expected_phase do
          send(owner, {:refresh_exchange_fence_barrier, phase, self(), binding})

          receive do
            {:release_refresh_exchange_fence_barrier, ^phase} -> :ok
          end
        end

        :ok
      end
    )
  end
end
