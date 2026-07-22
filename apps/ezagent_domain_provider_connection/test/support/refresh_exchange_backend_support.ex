defmodule Ezagent.ProviderConnection.Test.RefreshExchangeBackendSupport do
  @moduledoc false

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority
  alias Ezagent.ProviderConnection.{Connection, Operation}
  alias EzagentCore.Repo

  @begin_keys MapSet.new(
                ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id authorization_ref expected_connection_version expected_authorization_version expected_credential_version current_credential_ref correlation_id command_digest function driver_implementation driver_fingerprint credential_backend_fingerprint scope_authority scope_token scope_binding_digest credential_backend expected_refresh_lease_token expected_refresh_lease_version expected_refresh_lease_deadline)a
              )
  @provider_result_keys MapSet.new(
                          ~w(provider_result_ref replacement_credential granted_permissions_digest expires_at provider_metadata)a
                        )

  def begin(backend, command) when is_atom(backend) and is_map(command) do
    with true <- MapSet.new(Map.keys(command)) == @begin_keys,
         true <- command.credential_backend == backend,
         true <- command.function in [:refresh, :reconcile_refresh],
         true <- is_pid(command.scope_authority),
         true <- is_reference(command.scope_token),
         true <- is_binary(command.scope_binding_digest),
         :ok <- fence_barrier(:before_capture, command),
         {:ok, lease} <- capture_fence(command) do
      private = %{
        current_credential: {:protected_credential, command.current_credential_ref},
        binding:
          Map.drop(command, [
            :scope_authority,
            :scope_token,
            :scope_binding_digest,
            :expected_refresh_lease_token,
            :expected_refresh_lease_version,
            :expected_refresh_lease_deadline
          ]),
        lease: lease
      }

      use =
        RefreshUse.new(
          command.scope_authority,
          command.scope_token,
          command.scope_binding_digest,
          backend,
          private
        )

      observe_use(:protected, use)
      {:ok, use}
    else
      _error -> {:error, :correlation_conflict}
    end
  end

  def begin(_backend, _command), do: {:error, :correlation_conflict}

  def consume(backend, %{refresh_use: %RefreshUse{} = use, provider_exchange: exchange} = request)
      when map_size(request) == 2 and is_atom(backend) and is_function(exchange, 1) do
    with ^backend <- RefreshUse.backend(use),
         proof when is_reference(proof) <- RefreshUse.claim_proof(use),
         :ok <-
           ScopeAuthority.consume_claim(
             RefreshUse.authority(use),
             RefreshUse.token(use),
             RefreshUse.binding_digest(use),
             proof
           ),
         %{current_credential: current_credential, binding: binding, lease: lease} <-
           RefreshUse.private(use),
         :ok <- fence_barrier(:before_credential_injection, binding),
         :ok <- validate_authority(use, proof),
         :ok <- validate_fence(binding, lease),
         provider_frame <- %{current_credential: current_credential},
         :ok <- fence_barrier(:before_provider_use, binding),
         :ok <- validate_authority(use, proof),
         :ok <- validate_fence(binding, lease) do
      case exchange.(provider_frame) do
        {:ok, :not_completed} ->
          {:ok, :not_completed}

        {:ok, result} when is_map(result) ->
          with :ok <- fence_barrier(:after_provider_use, binding),
               :ok <- validate_authority(use, proof),
               :ok <- validate_fence(binding, lease),
               do: seal_result(backend, result)

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :provider_protocol_failed}
      end
    else
      _error -> {:error, :correlation_conflict}
    end
  end

  def consume(_backend, _request), do: {:error, :correlation_conflict}

  defp capture_fence(binding) do
    connection = Repo.get(Connection, binding.connection_id)
    operation = Repo.get(Operation, binding.operation_id)

    lease = %{
      token: binding.expected_refresh_lease_token,
      version: binding.expected_refresh_lease_version,
      deadline: binding.expected_refresh_lease_deadline
    }

    if valid_fence?(connection, operation, binding, lease),
      do: {:ok, lease},
      else: {:error, :correlation_conflict}
  end

  defp validate_fence(binding, lease) do
    connection = Repo.get(Connection, binding.connection_id)
    operation = Repo.get(Operation, binding.operation_id)

    if valid_fence?(connection, operation, binding, lease),
      do: :ok,
      else: {:error, :correlation_conflict}
  end

  defp valid_fence?(
         connection,
         operation,
         binding,
         %{token: token, version: version, deadline: %DateTime{} = deadline}
       ) do
    is_binary(token) and is_integer(version) and
      DateTime.compare(deadline, DateTime.utc_now()) == :gt and
      match?(%Connection{}, connection) and match?(%Operation{}, operation) and
      operation.lease_token == token and operation.attempt_version == version and
      operation.lease_until == deadline and connection.refresh_lease_token == token and
      connection.refresh_lease_version == version and connection.refresh_lease_until == deadline and
      operation.connection_id == connection.connection_id and
      operation.workspace_uri == connection.workspace_uri and
      operation.id == binding.operation_id and
      operation.operation_class == "refresh" and operation.status == "prepared" and
      operation.correlation_id == binding.correlation_id and
      operation.bound_input_digest == binding.command_digest and
      operation.backend_pair_id == binding.backend_pair_id and
      operation.expected_connection_version == binding.expected_connection_version and
      operation.expected_authorization_ref == binding.authorization_ref and
      operation.expected_authorization_version == binding.expected_authorization_version and
      operation.expected_credential_version == binding.expected_credential_version and
      operation.prior_credential_ref == binding.current_credential_ref and
      connection.workspace_uri == binding.workspace_uri and
      connection.owner_uri == binding.owner_uri and
      connection.provider_id == binding.provider_id and
      connection.acquisition_method == binding.acquisition_method and
      connection.governed_host == binding.governed_host and
      connection.backend_pair_id == binding.backend_pair_id and
      connection.authorization_backend_ref == binding.authorization_ref and
      connection.authorization_version == binding.expected_authorization_version and
      connection.credential_backend_ref == binding.current_credential_ref and
      connection.credential_version == binding.expected_credential_version and
      connection.connection_version == binding.expected_connection_version + 1 and
      connection.status == "refreshing"
  end

  defp valid_fence?(_connection, _operation, _binding, _lease), do: false

  defp validate_authority(use, proof) do
    ScopeAuthority.validate_claim(
      RefreshUse.authority(use),
      RefreshUse.token(use),
      RefreshUse.binding_digest(use),
      proof
    )
  end

  if Mix.env() == :test do
    defp observe_use(shape, use) do
      case Application.get_env(:ezagent_domain_provider_connection, :refresh_use_observer) do
        observer when is_function(observer, 2) -> observer.(shape, use)
        _ -> :ok
      end
    end

    defp fence_barrier(phase, binding) do
      case Application.get_env(
             :ezagent_domain_provider_connection,
             :refresh_exchange_fence_barrier
           ) do
        barrier when is_function(barrier, 2) -> barrier.(phase, binding)
        _ -> :ok
      end
    end
  else
    defp observe_use(_shape, _use), do: :ok
    defp fence_barrier(_phase, _binding), do: :ok
  end

  defp seal_result(backend, result) do
    with true <- MapSet.new(Map.keys(result)) == @provider_result_keys,
         true <- nonempty?(result.provider_result_ref),
         true <- nonempty?(result.granted_permissions_digest),
         true <- is_nil(result.expires_at) or is_struct(result.expires_at, DateTime),
         true <- is_map(result.provider_metadata) do
      handoff_ref =
        {backend, result.provider_result_ref, result.replacement_credential}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      {:ok,
       result
       |> Map.delete(:replacement_credential)
       |> Map.put(:credential_material, {:write_only_handoff, handoff_ref})}
    else
      _error -> {:error, :provider_protocol_failed}
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
end
