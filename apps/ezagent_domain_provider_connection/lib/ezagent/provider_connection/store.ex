defmodule Ezagent.ProviderConnection.Store do
  @moduledoc "Durable provider-connection callback and credential handoff boundary."

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    CredentialReplacement,
    LocalAuthorizationBackend,
    Operation,
    OwnerLifecycle,
    Refresh,
    Termination
  }

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support, as: BackendSupport
  alias EzagentCore.Repo

  @claim_seconds 30

  @doc "Executes the implemented owner command boundary."
  def execute(:begin_authorization, args, %{self_uri: %URI{}} = ctx),
    do: OwnerLifecycle.begin_authorization(args, ctx)

  def execute(:reauthorize, args, %{self_uri: %URI{}} = ctx),
    do: OwnerLifecycle.reauthorize(args, ctx)

  def execute(:consume_callback, args, %{self_uri: %URI{} = owner} = ctx) do
    case Ecto.UUID.cast(args.attempt_ref) do
      {:ok, _attempt_ref} -> execute_callback(args, owner, ctx)
      :error -> {:error, :callback_invalid}
    end
  end

  def execute(:refresh, args, %{self_uri: %URI{} = owner} = ctx) do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner),
         true <- is_integer(args.expected_version),
         true <- is_binary(args.correlation_id) and args.correlation_id != "" do
      Refresh.execute(connection, args, Map.get(ctx, :now, DateTime.utc_now()))
    else
      :error -> {:error, :invalid_authorization_subject}
      nil -> {:error, :invalid_authorization_subject}
      false -> {:error, :credential_conflict}
      {:error, _reason} = error -> error
    end
  end

  def execute(action, args, %{self_uri: %URI{} = owner}) when action in [:revoke, :disconnect] do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner),
         true <- is_integer(args.expected_version) do
      Termination.execute(connection, action, args.expected_version)
    else
      :error -> {:error, :invalid_authorization_subject}
      nil -> {:error, :invalid_authorization_subject}
      false -> {:error, :credential_conflict}
      {:error, _reason} = error -> error
    end
  end

  def execute(:read_connection, args, %{self_uri: %URI{} = owner}) do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner) do
      {:ok, %{connection: safe_connection_view(connection)}}
    else
      _reason -> {:error, :invalid_authorization_subject}
    end
  end

  def execute(_action, _args, _ctx),
    do: {:error, :unsupported_provider_connection_action}

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
        if Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref) do
          if final_operation_scope?(operation, attempt, connection),
            do: finish_callback(operation),
            else: {:error, :stale_attempt_claim}
        else
          {:error, :credential_conflict}
        end

      %Operation{status: status} = operation
      when status in ["connection_committed", "finalized"] ->
        if final_operation_scope?(operation, attempt, connection),
          do: finish_callback(operation),
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
         :ok <- validate_fence_locked(operation, claim, connection),
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
           journal_credential_result(operation, claim, connection, credential_result),
         {:ok, operation} <- CredentialReplacement.commit(operation.id) do
      {:ok, logical_result(Repo.get!(Connection, connection.connection_id), operation)}
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

  defp safe_connection_view(connection) do
    %{
      connection_id: connection.connection_id,
      workspace_uri: connection.workspace_uri,
      owner_uri: connection.owner_uri,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      external_account_id: connection.external_account_id,
      display_login: connection.display_login,
      execution_identity: connection.execution_identity,
      requested_execution_identity_class: connection.requested_execution_identity_class,
      acquisition_method: connection.acquisition_method,
      status: connection.status,
      permission_digest: connection.permission_digest,
      expires_at: encode_datetime(connection.expires_at),
      last_error_code: connection.last_error_code,
      version: connection.connection_version
    }
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil

  defp consume_authorization(attempt, connection, owner) do
    LocalAuthorizationBackend.consume_callback(%{
      authorization_ref: attempt.authorization_ref,
      expected_subject: subject(connection, owner),
      correlation_id: attempt.correlation_id
    })
  end

  defp prepare_operation(attempt, connection) do
    correlation_id = "store:#{attempt.correlation_id}"
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)

      backend_record =
        Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

      with %Connection{} <- locked_connection,
           %AuthorizationAttempt{} <- locked_attempt,
           %AuthorizationBackendRecord{} <- backend_record,
           true <- locked_attempt.claim_token == attempt.claim_token,
           true <- locked_attempt.attempt_version == attempt.attempt_version,
           :ok <- stable_scope(backend_record, locked_attempt, locked_connection) do
        digest = Operation.callback_digest(backend_record, locked_attempt, locked_connection)

        attrs = %{
          operation_class: "store",
          correlation_id: correlation_id,
          bound_input_digest: digest,
          next_recovery_at: now,
          status: "prepared"
        }

        case Repo.insert(
               Operation.store_create_changeset(locked_attempt, locked_connection, attrs)
             ) do
          {:ok, operation} -> operation
          {:error, changeset} -> Repo.rollback({:insert_failed, changeset, digest})
        end
      else
        _reason -> Repo.rollback(:credential_conflict)
      end
    end)
    |> case do
      {:ok, operation} ->
        {:ok, operation}

      {:error, {:insert_failed, _changeset, digest}} ->
        reconcile_operation(attempt.backend_pair_id, correlation_id, digest)

      {:error, _reason} ->
        {:error, :credential_conflict}
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
      fence_if_terminal(operation)
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
      else: fence_if_terminal(operation)
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
        result_credential_version: result.credential_version
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
               journaled.result_credential_version == result.credential_version do
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
      {:ok, {:backend_committed, committed}} ->
        {:ok, committed}

      {:ok, {:cleanup_pending, operation}} ->
        case CredentialReplacement.cleanup(operation.id) do
          :ok -> {:error, :connection_terminal}
          {:error, :stale_version} -> {:error, :credential_conflict}
          {:error, _reason} -> {:error, :authorization_backend_unavailable}
        end

      {:error, _reason} ->
        {:error, :credential_conflict}
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
         :ok <- validate_fence_locked(operation, attempt, connection),
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
           journal_credential_result(operation, attempt, connection, credential_result),
         {:ok, committed} <- CredentialReplacement.commit(committed.id) do
      {:ok, logical_result(Repo.get!(Connection, connection.connection_id), committed)}
    else
      false -> {:error, :stale_attempt_claim}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp finish_callback(operation) do
    with {:ok, finalized} <- CredentialReplacement.commit(operation.id) do
      connection = Repo.get!(Connection, operation.connection_id)
      {:ok, logical_result(connection, finalized)}
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

      cond do
        operation_fence_matches?(locked_operation, locked_attempt, locked_connection) ->
          :ok

        locked_connection.status in ["revoking", "disconnecting"] ->
          Repo.rollback(:connection_terminal)

        true ->
          Repo.rollback(:stale_attempt_claim)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :connection_terminal} -> fence_if_terminal(operation)
      {:error, _reason} -> {:error, :stale_attempt_claim}
    end
  end

  defp fence_if_terminal(operation) do
    case CredentialReplacement.fence(operation.id) do
      :ok -> {:error, :connection_terminal}
      {:error, :stale_version} -> {:error, :stale_attempt_claim}
      {:error, _reason} -> {:error, :authorization_backend_unavailable}
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

  defp final_operation_scope?(operation, attempt, connection) do
    base_connection = %{connection | connection_version: operation.expected_connection_version}

    case Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref) do
      %AuthorizationBackendRecord{} = backend_record ->
        operation.attempt_version == attempt.attempt_version and
          stable_scope(backend_record, attempt, base_connection) == :ok and
          operation.bound_input_digest ==
            Operation.callback_digest(backend_record, attempt, base_connection)

      nil ->
        false
    end
  end

  defp stable_scope(backend_record, attempt, connection) do
    with :ok <- BackendSupport.validate_backend_connection_scope(backend_record, connection),
         true <- backend_record.authorization_ref == attempt.authorization_ref,
         true <- backend_record.backend_pair_id == attempt.backend_pair_id,
         true <- backend_record.bound_input_digest == attempt.bound_subject_digest,
         true <- backend_record.workspace_uri == attempt.workspace_uri,
         true <- attempt.connection_id == connection.connection_id,
         true <- backend_record.connection_version == attempt.connection_version do
      :ok
    else
      _mismatch -> {:error, :credential_conflict}
    end
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

  defp subject(connection, owner),
    do: subject(connection, owner, connection_execution_identity(connection))

  defp subject(connection, owner, execution_identity) do
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

  defp connection_execution_identity(%Connection{status: "pending_authorization"} = connection),
    do: connection.requested_execution_identity_class

  defp connection_execution_identity(connection), do: connection.execution_identity
end
