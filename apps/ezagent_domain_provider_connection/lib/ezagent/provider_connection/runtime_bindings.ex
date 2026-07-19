defmodule Ezagent.ProviderConnection.RuntimeBindings do
  @moduledoc false

  alias Ezagent.ProviderConnection.{BackendPairRegistry, DriverRegistry, Operation}

  @doc false
  def resolve(connection, operation \\ nil) do
    pair_id = connection.backend_pair_id || operation_pair(operation)

    with :ok <- validate_operation_pair(connection, operation),
         pair_id when is_binary(pair_id) <- pair_id,
         {:ok, pair} <- BackendPairRegistry.lookup(pair_id),
         :ok <- validate_connection_binding(connection, pair),
         {:ok, driver} <-
           DriverRegistry.lookup(connection.provider_id, connection.acquisition_method),
         true <- pair_id in driver.backend_pair_ids,
         implementations <-
           Application.get_env(
             :ezagent_domain_provider_connection,
             :credential_backend_implementations,
             %{}
           ),
         backend when is_atom(backend) <- Map.get(implementations, pair.credential_backend.id) do
      {:ok, pair, driver, backend}
    else
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp operation_pair(%Operation{backend_pair_id: pair_id}), do: pair_id
  defp operation_pair(_operation), do: nil

  defp validate_operation_pair(
         %{backend_pair_id: connection_pair},
         %Operation{backend_pair_id: operation_pair}
       )
       when is_binary(connection_pair) and is_binary(operation_pair) do
    if connection_pair == operation_pair,
      do: :ok,
      else: {:error, :provider_declaration_drift}
  end

  defp validate_operation_pair(_connection, _operation), do: :ok

  defp validate_connection_binding(%{backend_pair_id: nil}, _pair), do: :ok

  defp validate_connection_binding(connection, pair) do
    if connection.backend_pair_id == pair.pair_id and
         connection.authorization_backend_id == pair.authorization_backend.id and
         connection.credential_backend_id == pair.credential_backend.id,
       do: :ok,
       else: {:error, :provider_declaration_drift}
  end
end
