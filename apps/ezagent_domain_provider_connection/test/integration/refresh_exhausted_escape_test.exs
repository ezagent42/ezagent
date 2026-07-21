Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/remote_refresh_exchange_endpoint.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RefreshExhaustedEscapeTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    BackendPairRegistry,
    Connection,
    DriverRegistry,
    Operation,
    Refresh,
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

  test "a prepared refresh that exhausts max attempts escapes to expired", %{
    state: state
  } do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    # R1 fails immediately — provider effect raises.
    Task8Fixtures.raise_next(state, :refresh, "provider-unreachable")

    assert {:error, _closed} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "exhausted-refresh"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    Task8Fixtures.clear_reply(state, :refresh)

    r1 = Repo.get_by!(Operation, correlation_id: "exhausted-refresh")
    assert r1.status == "prepared"
    connection = Repo.get!(Connection, connection.connection_id)
    assert connection.status == "refreshing"

    # Simulate the recovery GenServer counting 12 failures.
    r1
    |> Ecto.Changeset.change(recovery_attempts: 12)
    |> Repo.update!()

    # Recovery invokes Refresh.recover — should now expire instead of
    # retrying the lost generation forever.
    assert :ok = Refresh.recover(Repo.get!(Operation, r1.id), DateTime.utc_now())

    fenced = Repo.get!(Operation, r1.id)
    assert fenced.status == "fenced"
    assert fenced.safe_error_code == "backend_unavailable"
    refute is_nil(fenced.next_recovery_at)

    expired = Repo.get!(Connection, connection.connection_id)
    assert expired.status == "expired"
  end

  test "a prepared refresh below the max attempt threshold still retries normally", %{
    state: state
  } do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    Task8Fixtures.raise_next(state, :refresh, "provider-temporary-error")

    assert {:error, _closed} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "not-exhausted-yet"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    Task8Fixtures.clear_reply(state, :refresh)

    r1 = Repo.get_by!(Operation, correlation_id: "not-exhausted-yet")

    r1
    |> Ecto.Changeset.change(recovery_attempts: 5)
    |> Repo.update!()

    # Below threshold — recovery should still drive a retry (the result
    # will be a lost-lease error because R2 hasn't advanced the generation,
    # but the code path is the normal one, not the escape).
    result = Refresh.recover(Repo.get!(Operation, r1.id), DateTime.utc_now())

    refute result == :ok
    assert result in [{:error, :refresh_lease_lost}, {:error, :refresh_in_progress}]

    still = Repo.get!(Operation, r1.id)
    assert still.status == "prepared"
    refute still.safe_error_code == "backend_unavailable"
  end
end
