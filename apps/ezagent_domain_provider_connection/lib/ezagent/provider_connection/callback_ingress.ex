defmodule Ezagent.ProviderConnection.CallbackIngress do
  @moduledoc "Secret-minimizing callback transport boundary for provider authorization."

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    CallbackBinding,
    Connection,
    LocalAuthorizationBackend,
    Operation,
    RowLock
  }

  alias EzagentCore.Repo

  @doc "Stages a raw callback privately, then dispatches only durable coordinates."
  @spec consume(String.t(), String.t(), map()) :: term()
  def consume(redirect_id, raw_state, provider_envelope)
      when is_binary(redirect_id) and is_binary(raw_state) and is_map(provider_envelope) do
    with {:ok, pair_id} <- registered_pair(redirect_id),
         {:ok, digest} <- LocalAuthorizationBackend.state_digest(raw_state),
         %AuthorizationAttempt{} = candidate <- resolve_attempt(pair_id, digest),
         {:ok, {owner, artifact, attempt}} <-
           lock_validate_and_stage(candidate, pair_id, digest, raw_state, provider_envelope) do
      owner
      |> callback_command(artifact, attempt)
      |> Ezagent.Router.dispatch()
    else
      reason -> reject(redirect_id, reason)
    end
  rescue
    _error -> reject(redirect_id, :exception)
  end

  def consume(_redirect_id, _raw_state, _provider_envelope), do: {:error, :callback_invalid}

  defp callback_command(owner, artifact, attempt) do
    owner
    |> Ezagent.Cmd.new(
      :consume_callback,
      %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
      %{
        caller: owner,
        # #195 authz: thread the authenticated holder explicitly from this
        # external (OAuth callback) boundary — the owner whose connection this
        # callback completes is the authenticated principal, not ambient caller.
        authenticated_principal: owner,
        caps: MapSet.new([artifact]),
        mode: :call,
        reply: :ignore
      }
    )
  end

  defp registered_pair(redirect_id) do
    :ezagent_domain_provider_connection
    |> Application.get_env(:callback_redirect_pairs, %{})
    |> Map.fetch(redirect_id)
    |> case do
      {:ok, pair_id} when is_binary(pair_id) -> {:ok, pair_id}
      _reason -> {:error, :callback_invalid}
    end
  end

  defp resolve_attempt(pair_id, digest) do
    Repo.one(
      from(attempt in AuthorizationAttempt,
        where: attempt.backend_pair_id == ^pair_id and attempt.state_digest == ^digest
      )
    )
  end

  defp lock_validate_and_stage(candidate, pair_id, digest, raw_state, provider_envelope) do
    Repo.transaction(fn ->
      connection = lock_connection(candidate.connection_id)
      attempt = RowLock.authorization_attempt(candidate.attempt_ref)
      operation = lock_operation(attempt)
      backend_record = lock_backend_record(attempt)

      with %Connection{} <- connection,
           %AuthorizationAttempt{} <- attempt,
           %AuthorizationBackendRecord{} <- backend_record,
           true <- attempt.backend_pair_id == pair_id and attempt.state_digest == digest,
           :ok <- callback_source_status(attempt.purpose, connection.status, operation),
           :ok <- connection_generation(attempt, connection, operation),
           {:ok, owner} <- parse_owner(connection.owner_uri),
           %Ezagent.Capability{} = artifact <-
             Ezagent.Capability.from_map(attempt.callback_artifact),
           :ok <- validate_artifact(artifact, owner),
           true <-
             CallbackBinding.valid?(
               binding_connection(connection, attempt),
               attempt,
               backend_record,
               artifact
             ),
           :ok <- stage_if_required(attempt, operation, pair_id, raw_state, provider_envelope) do
        {owner, artifact, attempt}
      else
        _reason -> Repo.rollback(:callback_invalid)
      end
    end)
  end

  defp parse_owner(owner_uri) do
    owner = Ezagent.URI.new!(owner_uri)

    if Ezagent.URI.scheme?(owner, :entity) and Ezagent.URI.type?(owner, :user),
      do: {:ok, owner},
      else: {:error, :callback_invalid}
  end

  defp validate_artifact(artifact, owner) do
    workspace = Ezagent.Capability.workspace_of(owner)

    with :ok <- Ezagent.Cap.validate_for_current_target(artifact, owner),
         true <- artifact.kind == :user,
         true <- artifact.behavior == Ezagent.ActionSet.ProviderConnection,
         true <- artifact.action == :consume_callback,
         true <- artifact.instance == Ezagent.URI.instance(owner),
         true <- artifact.workspace_uri == workspace,
         true <- artifact.grantee_uri == owner do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_artifact_coordinates}
    end
  end

  defp callback_source_status("initial_bind", "pending_authorization", _operation), do: :ok

  defp callback_source_status("initial_bind", status, %Operation{status: operation_status})
       when status in ["active", "degraded", "expired"] and
              operation_status in ["connection_committed", "finalized"],
       do: :ok

  defp callback_source_status("reauthorize", status, _operation)
       when status in ["active", "degraded", "expired"],
       do: :ok

  defp callback_source_status(_purpose, _status, _operation),
    do: {:error, :connection_terminal}

  defp stage_if_required(attempt, operation, pair_id, raw_state, provider_envelope) do
    case operation do
      %Operation{status: status}
      when status in [
             "prepared",
             "backend_committed",
             "connection_committed",
             "finalized",
             "cleanup_pending"
           ] ->
        :ok

      nil ->
        LocalAuthorizationBackend.stage_callback(
          pair_id,
          attempt.authorization_ref,
          attempt.correlation_id,
          raw_state,
          provider_envelope
        )

      %Operation{} ->
        {:error, :callback_invalid}
    end
  end

  defp connection_generation(attempt, connection, nil) do
    if attempt.connection_version == connection.connection_version,
      do: :ok,
      else: {:error, :callback_invalid}
  end

  defp connection_generation(attempt, connection, operation) do
    if operation.workspace_uri == attempt.workspace_uri and
         operation.connection_id == attempt.connection_id and
         operation.attempt_ref == attempt.attempt_ref and
         operation.backend_pair_id == attempt.backend_pair_id and
         operation.operation_class == callback_operation_class(attempt.purpose) and
         operation.correlation_id == "#{operation.operation_class}:#{attempt.correlation_id}" and
         operation.expected_connection_version == attempt.connection_version and
         connection.workspace_uri == operation.workspace_uri and
         connection.connection_id == operation.connection_id and
         completed_generation?(operation, connection),
       do: :ok,
       else: {:error, :callback_invalid}
  end

  defp completed_generation?(%Operation{status: status} = operation, connection)
       when status in ["connection_committed", "finalized"],
       do: connection.connection_version == operation.expected_connection_version + 1

  defp completed_generation?(operation, connection),
    do: connection.connection_version == operation.expected_connection_version

  defp binding_connection(connection, attempt),
    do: %{connection | connection_version: attempt.connection_version}

  defp lock_connection(connection_id),
    do:
      Connection
      |> where([row], row.connection_id == ^connection_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_operation(attempt) do
    operation_class = callback_operation_class(attempt.purpose)

    Operation
    |> where(
      [row],
      row.backend_pair_id == ^attempt.backend_pair_id and
        row.operation_class == ^operation_class and
        row.correlation_id == ^"#{operation_class}:#{attempt.correlation_id}"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp callback_operation_class("initial_bind"), do: "store"
  defp callback_operation_class("reauthorize"), do: "replace"
  defp callback_operation_class(_purpose), do: nil

  defp lock_backend_record(attempt),
    do:
      AuthorizationBackendRecord
      |> where([row], row.authorization_ref == ^attempt.authorization_ref)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp reject(redirect_id, reason) do
    :telemetry.execute(
      [:ezagent, :provider_connection, :callback_ingress, :rejected],
      %{count: 1},
      %{redirect_id: telemetry_redirect_id(redirect_id), reason: reason_class(reason)}
    )

    {:error, :callback_invalid}
  end

  defp telemetry_redirect_id(redirect_id) do
    redirects =
      Application.get_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{})

    if Map.has_key?(redirects, redirect_id), do: redirect_id, else: :unknown
  end

  defp reason_class({:error, reason}) when is_atom(reason), do: reason_class(reason)

  defp reason_class(reason)
       when reason in [
              :callback_invalid,
              :connection_terminal,
              :invalid_artifact_coordinates,
              :invalid_cap_signature,
              :wrong_grantee,
              :exception
            ],
       do: reason

  defp reason_class(nil), do: :coordinate_not_found
  defp reason_class(false), do: :coordinate_mismatch
  defp reason_class(_reason), do: :rejected
end
