Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/remote_refresh_exchange_endpoint.ex", __DIR__))

defmodule Ezagent.ProviderConnection.EffectBoundaryProbeTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
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

  test "a raising driver on the refresh exchange is normalized without its payload", %{
    state: state
  } do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})
    payload = "HTTP 401 body: Authorization: Bearer SECRET-REFRESH-TOKEN"

    Task8Fixtures.raise_next(state, :refresh, payload)

    result =
      Store.execute(
        :refresh,
        %{
          connection_id: connection.connection_id,
          expected_version: 2,
          correlation_id: "refresh-driver-raises"
        },
        %{self_uri: Task8Fixtures.owner()}
      )

    assert {:error, reason} = result
    assert is_atom(reason)
    refute inspect(result) =~ "SECRET-REFRESH-TOKEN"
  end

  test "a raising credential backend on refresh replace is normalized without its payload", %{
    state: state
  } do
    connection = Task8Fixtures.connection(%{status: "refresh_required", connection_version: 2})
    payload = "Finch response body: SECRET-CREDENTIAL-MATERIAL"

    Task8Fixtures.raise_next(state, :replace, payload)

    result =
      Store.execute(
        :refresh,
        %{
          connection_id: connection.connection_id,
          expected_version: 2,
          correlation_id: "refresh-backend-replace-raises"
        },
        %{self_uri: Task8Fixtures.owner()}
      )

    assert {:error, reason} = result
    assert is_atom(reason)
    refute inspect(result) =~ "SECRET-CREDENTIAL-MATERIAL"
  end

  test "a raising driver on termination revoke journals a closed failure without its payload", %{
    state: state
  } do
    connection = Task8Fixtures.connection(%{status: "active", connection_version: 0})
    payload = "provider revoke response body: SECRET-REVOKE-TOKEN"

    Task8Fixtures.raise_next(state, :provider_revoke, payload)

    result =
      Store.execute(
        :revoke,
        %{connection_id: connection.connection_id, expected_version: 0},
        %{self_uri: Task8Fixtures.owner()}
      )

    refute inspect(result) =~ "SECRET-REVOKE-TOKEN"

    provider_obligations =
      Repo.all(
        from(operation in Operation,
          where:
            operation.connection_id == ^connection.connection_id and
              operation.operation_class == "revoke"
        )
      )

    assert provider_obligations != []

    assert Enum.any?(provider_obligations, fn operation ->
             operation.status == "prepared" and operation.safe_error_code == "backend_unavailable"
           end)

    for operation <- provider_obligations do
      refute inspect(operation) =~ "SECRET-REVOKE-TOKEN"
    end
  end

  test "a raising credential backend on termination revoke journals a closed failure without its payload",
       %{state: state} do
    connection = Task8Fixtures.connection(%{status: "active", connection_version: 0})
    payload = "credential backend error body: SECRET-BACKEND-KEY"

    Task8Fixtures.raise_next(state, :credential_revoke, payload)

    result =
      Store.execute(
        :revoke,
        %{connection_id: connection.connection_id, expected_version: 0},
        %{self_uri: Task8Fixtures.owner()}
      )

    refute inspect(result) =~ "SECRET-BACKEND-KEY"

    obligations =
      Repo.all(
        from(operation in Operation,
          where:
            operation.connection_id == ^connection.connection_id and
              operation.operation_class == "revoke"
        )
      )

    assert obligations != []

    assert Enum.any?(obligations, fn operation ->
             operation.status == "prepared" and operation.safe_error_code == "backend_unavailable"
           end)
  end
end
