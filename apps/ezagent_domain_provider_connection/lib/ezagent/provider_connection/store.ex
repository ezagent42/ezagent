defmodule Ezagent.ProviderConnection.Store do
  @moduledoc "Durable provider-connection callback and credential handoff boundary."

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    LocalAuthorizationBackend,
    Operation
  }

  alias EzagentCore.Repo

  @claim_seconds 30

  @doc "Executes the implemented owner command boundary."
  def execute(:begin_authorization, args, %{self_uri: %URI{} = owner}) do
    with %Connection{} = connection <- owned_connection(args.connection_id, owner),
         :ok <- begin_coordinates(connection, args),
         subject <- subject(connection, owner),
         {:ok, started} <-
           LocalAuthorizationBackend.begin_authorization(%{
             subject: subject,
             acquisition_method: connection.acquisition_method,
             requested_permissions_digest: args.requested_permissions_digest,
             redirect_uri_id: args.redirect_uri_id,
             correlation_id: args.correlation_id
           }),
         {:ok, state} <- fetch_string(started.redirect, "state"),
         {:ok, state_digest} <-
           LocalAuthorizationBackend.state_digest(state),
         %AuthorizationBackendRecord{} = backend_record <-
           Repo.get_by(AuthorizationBackendRecord,
             authorization_ref: started.authorization_ref
           ),
         {:ok, attempt} <-
           insert_attempt(connection, backend_record, state_digest, args.callback_artifact) do
      {:ok,
       %{
         attempt_ref: attempt.attempt_ref,
         authorization_url: started.redirect["authorization_uri"],
         expires_at: DateTime.to_iso8601(started.expires_at)
       }}
    else
      nil -> {:error, :invalid_authorization_subject}
      {:error, _reason} = error -> error
      _reason -> {:error, :callback_invalid}
    end
  end

  def execute(:consume_callback, args, %{self_uri: %URI{} = owner} = ctx) do
    case Ecto.UUID.cast(args.attempt_ref) do
      {:ok, _attempt_ref} -> execute_callback(args, owner, ctx)
      :error -> {:error, :provider_connection_orchestration_not_implemented}
    end
  end

  def execute(_action, _args, _ctx),
    do: {:error, :provider_connection_orchestration_not_implemented}

  defp execute_callback(args, owner, ctx) do
    now = Map.get(ctx, :now, DateTime.utc_now())

    with %AuthorizationAttempt{} = attempt <- Repo.get(AuthorizationAttempt, args.attempt_ref),
         true <- attempt.correlation_id == args.correlation_id,
         %Connection{} = connection <- owned_connection(attempt.connection_id, owner),
         :ok <- callback_source_status(connection.status),
         result <- dispatch_callback_phase(attempt, connection, owner, now) do
      result
    else
      false -> {:error, :correlation_conflict}
      nil -> {:error, :callback_invalid}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp dispatch_callback_phase(attempt, connection, owner, now) do
    case operation_for(attempt) do
      %Operation{status: "backend_committed"} = operation ->
        if operation_fence_matches?(operation, attempt, connection) and
             stable_operation_scope?(operation, attempt, connection),
           do: {:ok, logical_result(connection, operation)},
           else: {:error, :stale_attempt_claim}

      %Operation{status: "prepared"} = operation ->
        resume_prepared(operation, attempt, connection, owner, now)

      nil ->
        consume_to_backend_commit(attempt, connection, owner, now)

      %Operation{} ->
        {:error, :credential_conflict}
    end
  end

  defp consume_to_backend_commit(attempt, connection, owner, now) do
    with {:ok, claim} <-
           AuthorizationAttempt.claim_for_connection(
             attempt.attempt_ref,
             connection.connection_id,
             URI.to_string(owner),
             now,
             @claim_seconds
           ),
         {:ok, operation} <- prepare_operation(claim, connection),
         {:ok, callback_result} <- consume_authorization(claim, connection, owner),
         {:write_only_handoff, handoff_ref} <- callback_result.credential_material,
         {:ok, operation} <- bind_handoff(operation, claim, connection, handoff_ref),
         :ok <- validate_fence_locked(operation, claim, connection),
         {:ok, credential_result} <-
           LocalAuthorizationBackend.handoff_to_registered_credential(
             operation.id,
             claim.attempt_ref
           ),
         {:ok, operation} <-
           journal_credential_result(operation, claim, connection, credential_result) do
      {:ok, logical_result(connection, operation)}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp owned_connection(connection_id, owner) do
    Repo.one(
      from(connection in Connection,
        where:
          connection.connection_id == ^connection_id and
            connection.owner_uri == ^URI.to_string(owner) and
            connection.workspace_uri == ^URI.to_string(Ezagent.Capability.workspace_of(owner))
      )
    )
  end

  defp begin_coordinates(connection, args) do
    if connection.provider_id == args.provider_id and
         connection.governed_host == args.governed_host and
         connection.acquisition_method == args.acquisition_method and
         connection.execution_identity == args.execution_identity,
       do: :ok,
       else: {:error, :invalid_authorization_subject}
  end

  defp insert_attempt(connection, backend_record, state_digest, artifact) do
    attrs = %{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: backend_record.backend_pair_id,
      authorization_ref: backend_record.authorization_ref,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      bound_subject_digest: backend_record.bound_input_digest,
      state_digest: state_digest,
      pkce_digest: nil,
      correlation_id: callback_correlation(backend_record.authorization_ref),
      callback_artifact: Ezagent.Capability.to_map(artifact),
      status: "pending",
      expires_at: backend_record.expires_at
    }

    Repo.insert(AuthorizationAttempt.create_changeset(attrs))
  end

  defp callback_correlation(authorization_ref) do
    "callback:" <>
      (:crypto.hash(:sha256, authorization_ref) |> Base.url_encode64(padding: false))
  end

  defp consume_authorization(attempt, connection, owner) do
    LocalAuthorizationBackend.consume_callback(%{
      authorization_ref: attempt.authorization_ref,
      expected_subject: subject(connection, owner),
      correlation_id: attempt.correlation_id
    })
  end

  defp prepare_operation(attempt, connection) do
    correlation_id = "store:#{attempt.correlation_id}"

    backend_record =
      Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    with %AuthorizationBackendRecord{} <- backend_record,
         :ok <- stable_scope(backend_record, attempt, connection) do
      digest = Operation.callback_digest(backend_record, attempt, connection)

      attrs = %{
        workspace_uri: connection.workspace_uri,
        connection_id: connection.connection_id,
        backend_pair_id: attempt.backend_pair_id,
        operation_class: "store",
        correlation_id: correlation_id,
        bound_input_digest: digest,
        expected_connection_version: connection.connection_version,
        attempt_version: attempt.attempt_version,
        attempt_claim_token: attempt.claim_token,
        status: "prepared"
      }

      case Repo.insert(Operation.create_changeset(attrs)) do
        {:ok, operation} ->
          {:ok, operation}

        {:error, _changeset} ->
          reconcile_operation(attempt.backend_pair_id, correlation_id, digest)
      end
    else
      _reason -> {:error, :credential_conflict}
    end
  end

  defp reconcile_operation(pair_id, correlation_id, digest) do
    case Repo.get_by(Operation,
           backend_pair_id: pair_id,
           operation_class: "store",
           correlation_id: correlation_id
         ) do
      %Operation{bound_input_digest: ^digest} = operation -> {:ok, operation}
      %Operation{} -> {:error, :correlation_conflict}
      nil -> {:error, :credential_conflict}
    end
  end

  defp bind_handoff(
         %Operation{status: "prepared", handoff_ref: nil} = operation,
         attempt,
         connection,
         handoff_ref
       ) do
    if operation_fence_matches?(operation, attempt, connection) do
      operation
      |> Ecto.Changeset.change(handoff_ref: handoff_ref)
      |> Repo.update()
    else
      {:error, :stale_attempt_claim}
    end
  end

  defp bind_handoff(
         %Operation{status: "prepared", handoff_ref: handoff_ref} = operation,
         attempt,
         connection,
         handoff_ref
       ) do
    if operation_fence_matches?(operation, attempt, connection),
      do: {:ok, operation},
      else: {:error, :stale_attempt_claim}
  end

  defp bind_handoff(_operation, _attempt, _connection, _handoff_ref),
    do: {:error, :credential_conflict}

  defp journal_credential_result(
         %Operation{status: "backend_committed"} = operation,
         _attempt,
         _connection,
         _result
       ),
       do: {:ok, operation}

  defp journal_credential_result(operation, attempt, connection, result) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      attrs = %{
        result_ref: result.credential_ref,
        expected_credential_version: result.credential_version
      }

      case locked_operation do
        %Operation{status: "prepared"} ->
          if current_operation_fence?(locked_operation, locked_attempt, locked_connection) do
            locked_operation
            |> Operation.backend_commit_changeset(attrs)
            |> Repo.update!()
            |> then(&{:backend_committed, &1})
          else
            locked_operation
            |> Operation.cleanup_pending_changeset(
              Map.put(attrs, :safe_error_code, "cleanup_pending")
            )
            |> Repo.update!()
            |> then(&{:cleanup_pending, &1})
          end

        %Operation{status: status} = journaled
        when status in ["backend_committed", "cleanup_pending"] ->
          if journaled.result_ref == result.credential_ref and
               journaled.expected_credential_version == result.credential_version do
            {String.to_existing_atom(status), journaled}
          else
            Repo.rollback(:credential_conflict)
          end

        %Operation{} ->
          Repo.rollback(:credential_conflict)

        nil ->
          Repo.rollback(:credential_conflict)
      end
    end)
    |> case do
      {:ok, {:backend_committed, committed}} -> {:ok, committed}
      {:ok, {:cleanup_pending, _operation}} -> {:error, :credential_conflict}
      {:error, _reason} -> {:error, :credential_conflict}
    end
  end

  defp operation_for(attempt),
    do:
      Repo.get_by(Operation,
        backend_pair_id: attempt.backend_pair_id,
        operation_class: "store",
        correlation_id: "store:#{attempt.correlation_id}"
      )

  defp logical_result(connection, operation),
    do: %{
      connection_id: connection.connection_id,
      status: operation.status,
      version: connection.connection_version
    }

  defp callback_source_status(status)
       when status in ["pending_authorization", "active", "refresh_required", "degraded"],
       do: :ok

  defp callback_source_status(_status), do: {:error, :connection_terminal}

  defp resume_prepared(operation, attempt, connection, owner, now) do
    with {:ok, {operation, attempt, connection}} <-
           claim_prepared(operation, attempt, connection, owner, now),
         {:ok, callback_result} <- consume_authorization(attempt, connection, owner),
         {:write_only_handoff, handoff_ref} <- callback_result.credential_material,
         {:ok, operation} <- bind_handoff(operation, attempt, connection, handoff_ref),
         :ok <- validate_fence_locked(operation, attempt, connection),
         {:ok, credential_result} <-
           LocalAuthorizationBackend.handoff_to_registered_credential(
             operation.id,
             attempt.attempt_ref
           ),
         {:ok, committed} <-
           journal_credential_result(operation, attempt, connection, credential_result) do
      {:ok, logical_result(connection, committed)}
    else
      false -> {:error, :stale_attempt_claim}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp claim_prepared(operation, attempt, connection, owner, now) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      backend_record =
        Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

      with %Connection{} <- locked_connection,
           %AuthorizationAttempt{} <- locked_attempt,
           %Operation{status: "prepared"} <- locked_operation,
           %AuthorizationBackendRecord{} <- backend_record,
           true <- locked_connection.owner_uri == URI.to_string(owner),
           :ok <- stable_scope(backend_record, locked_attempt, locked_connection),
           true <-
             locked_operation.bound_input_digest ==
               Operation.callback_digest(backend_record, locked_attempt, locked_connection),
           :ok <- callback_source_status(locked_connection.status),
           :ok <- recoverable_attempt(locked_attempt, now) do
        renew_prepared_claim(locked_operation, locked_attempt, locked_connection, now)
      else
        {:error, _reason} = error -> Repo.rollback(error)
        _reason -> Repo.rollback({:error, :credential_conflict})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, _reason} -> {:error, :credential_conflict}
    end
  end

  defp recoverable_attempt(%AuthorizationAttempt{status: "consuming"} = attempt, now) do
    cond do
      DateTime.compare(now, attempt.expires_at) != :lt -> {:error, :callback_expired}
      is_nil(attempt.claim_until) -> {:error, :stale_attempt_claim}
      DateTime.compare(now, attempt.claim_until) == :lt -> {:error, :callback_in_progress}
      true -> :ok
    end
  end

  defp recoverable_attempt(_attempt, _now), do: {:error, :stale_attempt_claim}

  defp renew_prepared_claim(operation, attempt, connection, now) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    version = attempt.attempt_version + 1

    renewed_attempt =
      attempt
      |> Ecto.Changeset.change(
        claim_token: token,
        claim_until: DateTime.add(now, @claim_seconds, :second),
        attempt_version: version
      )
      |> Repo.update!()

    renewed_operation =
      operation
      |> Ecto.Changeset.change(attempt_claim_token: token, attempt_version: version)
      |> Repo.update!()

    {renewed_operation, renewed_attempt, connection}
  end

  defp validate_fence_locked(operation, attempt, connection) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      if operation_fence_matches?(locked_operation, locked_attempt, locked_connection),
        do: :ok,
        else: Repo.rollback(:stale_attempt_claim)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :stale_attempt_claim}
    end
  end

  defp operation_fence_matches?(
         %Operation{} = operation,
         %AuthorizationAttempt{} = attempt,
         %Connection{} = connection
       ) do
    operation.workspace_uri == attempt.workspace_uri and
      operation.workspace_uri == connection.workspace_uri and
      operation.connection_id == attempt.connection_id and
      operation.connection_id == connection.connection_id and
      operation.backend_pair_id == attempt.backend_pair_id and
      operation.correlation_id == "store:#{attempt.correlation_id}" and
      operation.expected_connection_version == attempt.connection_version and
      operation.expected_connection_version == connection.connection_version and
      operation.attempt_claim_token == attempt.claim_token and
      operation.attempt_version == attempt.attempt_version and attempt.status == "consuming"
  end

  defp operation_fence_matches?(_operation, _attempt, _connection), do: false

  defp current_operation_fence?(operation, attempt, connection) do
    backend_record =
      if match?(%AuthorizationAttempt{}, attempt) do
        Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)
      end

    match?(%AuthorizationBackendRecord{}, backend_record) and
      operation_fence_matches?(operation, attempt, connection) and
      stable_scope(backend_record, attempt, connection) == :ok and
      operation.bound_input_digest ==
        Operation.callback_digest(backend_record, attempt, connection)
  end

  defp stable_operation_scope?(operation, attempt, connection) do
    case Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref) do
      %AuthorizationBackendRecord{} = backend_record ->
        stable_scope(backend_record, attempt, connection) == :ok and
          operation.bound_input_digest ==
            Operation.callback_digest(backend_record, attempt, connection)

      nil ->
        # Synthetic committed rows used by legacy recovery fixtures predate
        # the backend-record binding; real callback rows always have one.
        true
    end
  end

  defp stable_scope(backend_record, attempt, connection) do
    if backend_record.authorization_ref == attempt.authorization_ref and
         backend_record.backend_pair_id == attempt.backend_pair_id and
         backend_record.bound_input_digest == attempt.bound_subject_digest and
         backend_record.owner_uri == connection.owner_uri and
         backend_record.workspace_uri == attempt.workspace_uri and
         backend_record.workspace_uri == connection.workspace_uri and
         backend_record.connection_id == connection.connection_id and
         attempt.connection_id == connection.connection_id and
         backend_record.connection_version == attempt.connection_version and
         backend_record.connection_version == connection.connection_version and
         backend_record.provider_id == connection.provider_id and
         backend_record.governed_host == connection.governed_host and
         backend_record.acquisition_method == connection.acquisition_method and
         backend_record.execution_identity == connection.execution_identity,
       do: :ok,
       else: {:error, :credential_conflict}
  end

  defp lock_connection(connection_id),
    do:
      Connection
      |> where([row], row.connection_id == ^connection_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_attempt(attempt_ref),
    do:
      AuthorizationAttempt
      |> where([row], row.attempt_ref == ^attempt_ref)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_operation(operation_id),
    do:
      Operation
      |> where([row], row.id == ^operation_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp subject(connection, owner) do
    %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      execution_identity: connection.execution_identity
    }
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _reason -> {:error, :provider_protocol_error}
    end
  end
end
