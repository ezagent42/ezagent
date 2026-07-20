defmodule Ezagent.ProviderConnection.CredentialRefreshExchange do
  @moduledoc """
  Function-fixed refresh exchange facade.

  This is the sole production caller of the credential backend's two private
  refresh exchange primitives. Driver and backend effects execute in the
  invocation owner process; the short-lived authority only claims a scope.
  """

  alias Ezagent.ProviderConnection.{CredentialBackend.RefreshUse, Driver, RuntimeBindings}
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority

  @scope_key {__MODULE__, :scope}
  @context_keys MapSet.new(
                  ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id authorization_ref expected_connection_version expected_authorization_version expected_credential_version correlation_id command_digest refresh_use)a
                )
  @sealed_result_keys MapSet.new(
                        ~w(provider_result_ref credential_material granted_permissions_digest expires_at provider_metadata)a
                      )

  @doc false
  def invoke(selection, connection, operation) when selection in [:refresh, :reconcile_refresh] do
    with {:ok, pair, driver, backend} <- RuntimeBindings.resolve(connection, operation),
         command <- begin_command(connection, operation, pair, driver, selection),
         binding_digest <- digest(command),
         {:ok, authority} <- ScopeAuthority.start(self(), binding_digest) do
      try do
        invoke_in_scope(
          authority,
          binding_digest,
          command,
          invocation_claim(operation),
          driver,
          backend,
          selection
        )
      after
        Process.delete(@scope_key)
        ScopeAuthority.invalidate(authority)
      end
    else
      _error -> {:error, :correlation_conflict}
    end
  end

  defp invoke_in_scope(
         authority,
         binding_digest,
         command,
         invocation_claim,
         driver,
         backend,
         selection
       ) do
    with {:ok, token} <- ScopeAuthority.open(authority),
         begin_request <-
           Map.merge(command, %{
             scope_authority: authority,
             scope_token: token,
             scope_binding_digest: binding_digest,
             credential_backend: backend,
             expected_refresh_lease_token: invocation_claim.token,
             expected_refresh_lease_version: invocation_claim.version,
             expected_refresh_lease_deadline: invocation_claim.deadline
           }),
         {:ok, %RefreshUse{} = refresh_use} <- backend.begin_refresh_exchange(begin_request),
         :ok <- validate_use(refresh_use, authority, token, binding_digest, backend) do
      context = driver_context(command, refresh_use)

      Process.put(@scope_key, %{
        use: refresh_use,
        backend: backend,
        binding_digest: binding_digest,
        sealed_result: :not_consumed
      })

      driver_result = apply(driver.implementation, selection, [context])

      with :ok <- validate_backend_sealed_result(driver_result) do
        validate_result(driver_result, driver)
      end
    else
      _error -> {:error, :correlation_conflict}
    end
  end

  @doc false
  def consume_refresh_exchange(
        %{refresh_use: %RefreshUse{} = use, provider_exchange: exchange} = request
      )
      when map_size(request) == 2 and is_function(exchange, 1) do
    with %{use: ^use, backend: backend, binding_digest: digest} <- Process.get(@scope_key),
         ^backend <- RefreshUse.backend(use),
         ^digest <- RefreshUse.binding_digest(use),
         {:ok, proof} <-
           ScopeAuthority.claim(RefreshUse.authority(use), RefreshUse.token(use), digest),
         claimed_use <- RefreshUse.claimed(use, proof),
         result <- backend.consume_refresh_exchange(%{request | refresh_use: claimed_use}) do
      Process.put(@scope_key, %{
        use: use,
        backend: backend,
        binding_digest: digest,
        sealed_result: result
      })

      result
    else
      _error -> {:error, :correlation_conflict}
    end
  end

  def consume_refresh_exchange(_request), do: {:error, :correlation_conflict}

  defp begin_command(connection, operation, pair, driver, selection) do
    %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      acquisition_method: connection.acquisition_method,
      governed_host: connection.governed_host,
      backend_pair_id: pair.pair_id,
      operation_id: operation.id,
      connection_id: operation.connection_id,
      authorization_ref: operation.expected_authorization_ref,
      expected_connection_version: operation.expected_connection_version,
      expected_authorization_version: operation.expected_authorization_version,
      expected_credential_version: operation.expected_credential_version,
      current_credential_ref: operation.prior_credential_ref,
      correlation_id: operation.correlation_id,
      command_digest: operation.bound_input_digest,
      function: selection,
      driver_implementation: driver.implementation,
      driver_fingerprint: driver.fingerprint,
      credential_backend_fingerprint: pair.credential_backend.fingerprint
    }
  end

  defp invocation_claim(operation) do
    %{
      token: operation.lease_token,
      version: operation.attempt_version,
      deadline: operation.lease_until
    }
  end

  defp driver_context(command, refresh_use) do
    command
    |> Map.take(MapSet.to_list(MapSet.delete(@context_keys, :refresh_use)))
    |> Map.put(:refresh_use, refresh_use)
  end

  defp validate_use(use, authority, token, digest, backend) do
    if RefreshUse.authority(use) == authority and RefreshUse.token(use) == token and
         RefreshUse.binding_digest(use) == digest and RefreshUse.backend(use) == backend,
       do: :ok,
       else: {:error, :correlation_conflict}
  end

  defp validate_backend_sealed_result(driver_result) do
    case Process.get(@scope_key) do
      %{sealed_result: ^driver_result} -> :ok
      _ -> {:error, :provider_protocol_failed}
    end
  end

  defp validate_result({:ok, :not_completed}, _driver), do: {:ok, :not_completed}

  defp validate_result({:ok, result}, driver) when is_map(result) do
    with true <- MapSet.new(Map.keys(result)) == @sealed_result_keys,
         true <- nonempty?(result.provider_result_ref),
         {:write_only_handoff, handoff_ref} <- result.credential_material,
         true <- nonempty?(handoff_ref),
         true <- nonempty?(result.granted_permissions_digest),
         true <- is_nil(result.expires_at) or is_struct(result.expires_at, DateTime),
         schema <- driver.metadata.provider_metadata_schema,
         true <- Driver.matches_schema?(result.provider_metadata, schema) do
      {:ok, Map.delete(result, :provider_metadata)}
    else
      _error -> {:error, :provider_protocol_failed}
    end
  end

  defp validate_result({:error, reason}, _driver)
       when reason in [
              :backend_unavailable,
              :provider_denied,
              :provider_protocol_failed,
              :correlation_conflict
            ],
       do: {:error, reason}

  defp validate_result(_result, _driver), do: {:error, :provider_protocol_failed}

  defp digest(command) do
    command
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
end
