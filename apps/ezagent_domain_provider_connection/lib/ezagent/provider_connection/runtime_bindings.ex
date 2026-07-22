defmodule Ezagent.ProviderConnection.RuntimeBindings do
  @moduledoc false

  alias Ezagent.ProviderConnection.{BackendPairRegistry, Driver, DriverRegistry, Operation}

  @credential_callbacks [
    store: 1,
    replace: 1,
    status: 1,
    lease_for_operation: 1,
    consume_lease: 1,
    begin_refresh_exchange: 1,
    consume_refresh_exchange: 1,
    revoke: 1
  ]

  @doc false
  def resolve(connection, operation \\ nil) do
    pair_id = connection.backend_pair_id || operation_pair(operation)

    with :ok <- validate_operation_binding(connection, operation),
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
         backend when is_atom(backend) <- Map.get(implementations, pair.credential_backend.id),
         :ok <- validate_runtime_contract(connection, operation, driver, backend) do
      {:ok, pair, driver, backend}
    else
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp validate_runtime_contract(connection, operation, driver, backend) do
    with :ok <- Driver.verify_fingerprint(driver),
         true <- valid_backend?(backend) do
      validate_refresh_runtime_binding(connection, operation)
    else
      _ -> {:error, :provider_declaration_drift}
    end
  end

  defp validate_refresh_runtime_binding(_connection, %Operation{operation_class: "refresh"}),
    do: :ok

  defp validate_refresh_runtime_binding(_connection, _operation), do: :ok

  @doc false
  def resolve_provider_cleanup(connection, operation) do
    with {:ok, pair} <- resolve_pair(connection, operation),
         {:ok, driver} <-
           DriverRegistry.lookup(connection.provider_id, connection.acquisition_method),
         :ok <- Driver.verify_fingerprint(driver),
         true <- pair.pair_id in driver.backend_pair_ids do
      {:ok, pair, driver}
    else
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  @doc false
  def resolve_credential_cleanup(connection, operation) do
    with {:ok, pair} <- resolve_pair(connection, operation),
         implementations <-
           Application.get_env(
             :ezagent_domain_provider_connection,
             :credential_backend_implementations,
             %{}
           ),
         backend when is_atom(backend) <- Map.get(implementations, pair.credential_backend.id),
         true <- valid_backend?(backend) do
      {:ok, pair, backend}
    else
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp resolve_pair(connection, operation) do
    pair_id = connection.backend_pair_id || operation_pair(operation)

    with :ok <- validate_cleanup_binding(connection, operation),
         pair_id when is_binary(pair_id) <- pair_id,
         {:ok, pair} <- BackendPairRegistry.lookup(pair_id),
         :ok <- validate_connection_binding(connection, pair) do
      {:ok, pair}
    end
  end

  defp operation_pair(%Operation{backend_pair_id: pair_id}), do: pair_id
  defp operation_pair(_operation), do: nil

  defp validate_operation_binding(
         %{backend_pair_id: connection_pair} = connection,
         %Operation{operation_class: "refresh"} = operation
       )
       when is_binary(connection_pair) do
    valid? =
      connection_pair == operation.backend_pair_id and
        operation.operation_class == "refresh" and
        exact_connection_binding?(connection, operation)

    if valid?,
      do: :ok,
      else: {:error, :provider_declaration_drift}
  end

  defp validate_operation_binding(
         %{backend_pair_id: connection_pair},
         %Operation{backend_pair_id: operation_pair}
       )
       when is_binary(connection_pair) and is_binary(operation_pair) do
    if connection_pair == operation_pair,
      do: :ok,
      else: {:error, :provider_declaration_drift}
  end

  defp validate_operation_binding(_connection, nil), do: :ok

  defp validate_operation_binding(_connection, %Operation{operation_class: "refresh"}),
    do: {:error, :provider_declaration_drift}

  defp validate_operation_binding(_connection, _operation), do: :ok

  defp exact_connection_binding?(connection, %Operation{} = operation) do
    operation.connection_id == connection.connection_id and
      operation.workspace_uri == connection.workspace_uri and
      operation.expected_authorization_ref == connection.authorization_backend_ref and
      operation.expected_authorization_version == connection.authorization_version and
      valid_stage_generation?(connection, operation)
  end

  defp valid_stage_generation?(connection, %Operation{status: "prepared"} = operation) do
    connection.status == "refreshing" and
      connection.connection_version == operation.expected_connection_version + 1 and
      connection.credential_version == operation.expected_credential_version
  end

  defp valid_stage_generation?(connection, %Operation{status: "backend_committed"} = operation),
    do: valid_stage_generation?(connection, %{operation | status: "prepared"})

  defp valid_stage_generation?(connection, %Operation{status: status} = operation)
       when status in ["connection_committed", "finalized"] do
    connection.connection_version == operation.expected_connection_version + 2 and
      connection.credential_backend_ref == operation.result_ref and
      connection.credential_version == operation.result_credential_version
  end

  defp valid_stage_generation?(_connection, %Operation{status: "cleanup_pending"}), do: true
  defp valid_stage_generation?(_connection, _operation), do: false

  defp validate_cleanup_binding(connection, %Operation{} = operation) do
    if operation.connection_id == connection.connection_id and
         operation.workspace_uri == connection.workspace_uri and
         operation.backend_pair_id == connection.backend_pair_id and
         operation.operation_class == "refresh",
       do: :ok,
       else: {:error, :provider_declaration_drift}
  end

  defp validate_connection_binding(%{backend_pair_id: nil}, _pair), do: :ok

  defp validate_connection_binding(connection, pair) do
    if connection.backend_pair_id == pair.pair_id and
         connection.authorization_backend_id == pair.authorization_backend.id and
         connection.credential_backend_id == pair.credential_backend.id,
       do: :ok,
       else: {:error, :provider_declaration_drift}
  end

  defp valid_backend?(backend) do
    match?({:module, _module}, Code.ensure_loaded(backend)) and
      Enum.all?(@credential_callbacks, fn {name, arity} ->
        function_exported?(backend, name, arity)
      end)
  end
end
