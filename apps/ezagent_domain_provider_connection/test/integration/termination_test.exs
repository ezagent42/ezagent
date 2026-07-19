Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.TerminationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
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

  defp scope(connection),
    do: %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      execution_identity: connection.execution_identity
    }
end
