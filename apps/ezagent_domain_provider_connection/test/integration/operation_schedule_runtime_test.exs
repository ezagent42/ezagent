Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/d1_operation_fixtures.ex", __DIR__))

defmodule Ezagent.ProviderConnection.OperationScheduleRuntimeTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    BackendPairRegistry,
    DriverRegistry,
    Operation,
    Refresh,
    Termination
  }

  alias Ezagent.ProviderConnection.Test.{D1OperationFixtures, Task8Fixtures}
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

  test "refresh schedule exists when the real refresh writer is prepared", %{state: state} do
    now = DateTime.utc_now()

    connection =
      D1OperationFixtures.connection(%{
        status: "refresh_required",
        connection_version: 5,
        credential_version: 2
      })

    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :refresh], test_pid))

    task =
      Task.async(fn ->
        Refresh.execute(
          connection,
          %{
            connection_id: connection.connection_id,
            expected_version: 5,
            correlation_id: "schedule-refresh"
          },
          now
        )
      end)

    assert_receive {:task8_barrier, :refresh, _worker, _context}

    prepared =
      Repo.get_by!(Operation,
        operation_class: "refresh",
        correlation_id: "schedule-refresh"
      )

    assert prepared.status == "prepared"
    assert prepared.next_recovery_at == now
    assert is_nil(Task.shutdown(task, :brutal_kill))
  end

  test "termination schedules both obligations and clears them after real finalization", %{
    state: state
  } do
    now = DateTime.utc_now()
    connection = D1OperationFixtures.connection(%{connection_version: 8, credential_version: 3})
    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :provider_revoke], test_pid))

    task = Task.async(fn -> Termination.execute(connection, :revoke, 8, now) end)
    assert_receive {:task8_barrier, :provider_revoke, worker, _context}

    prepared =
      Repo.all(
        from(operation in Operation,
          where:
            operation.connection_id == ^connection.connection_id and
              operation.operation_class == "revoke"
        )
      )

    assert length(prepared) == 2
    assert Enum.sort(Enum.map(prepared, & &1.status)) == ["backend_committed", "prepared"]
    assert Enum.all?(prepared, &(&1.next_recovery_at == now))

    send(worker, {:release_task8, :provider_revoke})
    assert {:ok, %{status: "revoked"}} = Task.await(task)

    finalized =
      Repo.all(from(operation in Operation, where: operation.id in ^Enum.map(prepared, & &1.id)))

    assert Enum.all?(finalized, &(&1.status == "finalized"))
    assert Enum.all?(finalized, &is_nil(&1.next_recovery_at))
  end
end
