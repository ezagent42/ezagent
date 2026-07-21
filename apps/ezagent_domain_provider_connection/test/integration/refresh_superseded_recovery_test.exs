Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/remote_refresh_exchange_endpoint.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RefreshSupersededRecoveryTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    BackendPairRegistry,
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

  test "a provider-owned prepared refresh superseded by a successor is compensated to finalized",
       %{state: state} do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    # Crash window 3: R1 blocks after its provider result is durably
    # journaled but before the credential replace effect, and never resumes.
    test_pid = self()
    Agent.update(state, &put_in(&1, [:barriers, :replace], test_pid))

    _r1_task =
      Task.start(fn ->
        Store.execute(
          :refresh,
          %{
            connection_id: connection.connection_id,
            expected_version: 2,
            correlation_id: "r1-superseded"
          },
          %{self_uri: Task8Fixtures.owner()}
        )
      end)

    assert_receive {:task8_barrier, :replace, _worker, _command}, 5_000

    # R1's worker stays blocked inside the armed barrier receive (the abandoned
    # crash window); clear the armed barrier so R2's own replace is not fenced
    # by it.
    Agent.update(state, fn current ->
      update_in(current, [:barriers], fn barriers -> Map.delete(barriers, :replace) end)
    end)

    r1 = Repo.get_by!(Operation, correlation_id: "r1-superseded")
    assert r1.status == "prepared"
    assert is_binary(r1.provider_result_ref)

    expire_refresh_leases(connection.connection_id, r1.id)

    assert {:ok, _receipt} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 3,
                 correlation_id: "r2-successor"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    # R1's crash window: the provider result is journaled, but no credential
    # result ever reached the domain (the worker never returned).
    assert is_nil(Repo.get!(Operation, r1.id).result_ref)

    # Recovering R1 must compensate the journaled provider result exactly
    # once and converge instead of spinning on the lost generation forever.
    assert :ok = Refresh.recover(Repo.get!(Operation, r1.id), DateTime.utc_now())

    converged = Repo.get!(Operation, r1.id)
    assert converged.status == "finalized"
    assert is_nil(converged.next_recovery_at)
    assert converged.provider_cleanup_status == "confirmed"

    assert Agent.get(state, &Map.get(&1.counts, :discard_refresh_result, 0)) == 1

    assert [%{provider_result_ref: discarded_ref}] =
             Agent.get(state, &Map.get(&1.calls, :discard_refresh_result))

    assert discarded_ref == r1.provider_result_ref

    current = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    r2 = Repo.get_by!(Operation, correlation_id: "r2-successor")
    assert current.status == "active"
    assert current.credential_backend_ref == r2.result_ref
  end

  test "an all-NULL prepared refresh superseded by a successor is fenced out of the retry loop",
       %{state: state} do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})

    # R1's provider effect fails before any journal: all-NULL prepared row.
    Task8Fixtures.raise_next(state, :refresh, "provider boom SECRET")

    assert {:error, _closed} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 2,
                 correlation_id: "r1-null-superseded"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    Task8Fixtures.clear_reply(state, :refresh)

    r1 = Repo.get_by!(Operation, correlation_id: "r1-null-superseded")
    assert r1.status == "prepared"
    refute is_binary(r1.provider_result_ref)
    refute is_binary(r1.handoff_ref)

    expire_refresh_leases(connection.connection_id, r1.id)

    assert {:ok, _receipt} =
             Store.execute(
               :refresh,
               %{
                 connection_id: connection.connection_id,
                 expected_version: 3,
                 correlation_id: "r2-null-successor"
               },
               %{self_uri: Task8Fixtures.owner()}
             )

    assert :ok = Refresh.recover(Repo.get!(Operation, r1.id), DateTime.utc_now())

    fenced = Repo.get!(Operation, r1.id)
    assert fenced.status == "fenced"
    # The durable CHECK requires fenced rows to keep next_recovery_at; the row
    # leaves the retry loop by STATUS (recovery never selects fenced rows).
    refute is_nil(fenced.next_recovery_at)

    # No provider result ever existed, so nothing is discarded.
    assert Agent.get(state, &Map.get(&1.counts, :discard_refresh_result, 0)) == 0

    current = Repo.get!(Ezagent.ProviderConnection.Connection, connection.connection_id)
    assert current.status == "active"
  end

  defp expire_refresh_leases(connection_id, operation_id) do
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    Repo.query!(
      "UPDATE provider_connections SET refresh_lease_until = $2 WHERE connection_id::text = $1",
      [connection_id, past]
    )

    Repo.query!(
      "UPDATE provider_connection_operations SET lease_until = $2 WHERE id::text = $1",
      [operation_id, past]
    )
  end
end
