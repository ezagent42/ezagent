Code.require_file(Path.expand("../../support/task8_backends.ex", __DIR__))

defmodule Ezagent.ProviderConnection.SelectorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.Selector
  alias Ezagent.ProviderConnection.Test.Task8Fixtures

  test "selects only by the exact authoritative scope" do
    connection = Task8Fixtures.connection()

    scope = %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      execution_identity: connection.execution_identity
    }

    assert {:ok, ^connection} = Selector.select(scope)

    assert {:error, :invalid_subject} =
             Selector.select(Map.put(scope, :connection_id, connection.connection_id))

    assert {:error, :invalid_subject} = Selector.select(Map.delete(scope, :owner_uri))
  end

  test "fails closed when the authoritative scope has more than one active connection" do
    first = Task8Fixtures.connection()
    _second = Task8Fixtures.connection(%{external_account_id: "second-account"})

    assert {:error, :connection_ambiguous} =
             Selector.select(%{
               owner_uri: first.owner_uri,
               workspace_uri: first.workspace_uri,
               provider_id: first.provider_id,
               governed_host: first.governed_host,
               execution_identity: first.execution_identity
             })
  end
end
