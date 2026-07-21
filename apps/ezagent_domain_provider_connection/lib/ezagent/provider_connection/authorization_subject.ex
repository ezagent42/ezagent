defmodule Ezagent.ProviderConnection.AuthorizationSubject do
  @moduledoc false

  alias Ezagent.ProviderConnection.Connection

  @doc false
  @spec from_connection(Connection.t(), URI.t(), String.t() | nil) :: map()
  def from_connection(%Connection{} = connection, %URI{} = owner, execution_identity) do
    %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      execution_identity: execution_identity
    }
  end
end
