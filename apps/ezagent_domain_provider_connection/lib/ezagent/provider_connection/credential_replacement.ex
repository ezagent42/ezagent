defmodule Ezagent.ProviderConnection.CredentialReplacement do
  @moduledoc "Fenced pointer CAS and durable handoff finalization."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    LocalAuthorizationBackend,
    Operation,
    RuntimeBindings,
    Transition
  }

  alias EzagentCore.Repo

  @doc "CAS the credential pointer for a backend-committed operation."
  def commit(operation_id) when is_binary(operation_id) do
    case Repo.get(Operation, operation_id) do
      %Operation{status: "finalized"} = operation -> {:ok, operation}
      %Operation{status: "connection_committed"} = operation -> finalize(operation)
      %Operation{status: "backend_committed"} = operation -> cas(operation)
      %Operation{} -> {:error, :stale_version}
      nil -> {:error, :stale_version}
    end
  end

  @doc false
  def cleanup(operation_id) when is_binary(operation_id) do
    with %Operation{} = operation <- Repo.get(Operation, operation_id),
         {:ok, operation} <- mark_cleanup_pending_if_terminal(operation),
         true <- operation.status == "cleanup_pending",
         %AuthorizationAttempt{} = attempt <-
           Repo.get(AuthorizationAttempt, operation.attempt_ref),
         connection <- Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id),
         {:ok, _pair, _driver, backend} <- RuntimeBindings.resolve(connection, operation),
         :ok <- revoke_result(operation, backend),
         :ok <- LocalAuthorizationBackend.prepare_handoff_finalization(attempt.authorization_ref),
         :ok <- LocalAuthorizationBackend.finalize_handoff(attempt.authorization_ref),
         :ok <- mark_cleanup_finalized(operation.id, attempt.attempt_ref) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :credential_conflict}
    end
  end

  @doc false
  def fence(operation_id) when is_binary(operation_id) do
    with %Operation{status: "prepared"} = operation <- Repo.get(Operation, operation_id),
         %AuthorizationAttempt{} = attempt <-
           Repo.get(AuthorizationAttempt, operation.attempt_ref),
         connection <- Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id),
         true <- connection.status in ["revoking", "disconnecting"],
         :ok <- LocalAuthorizationBackend.prepare_handoff_finalization(attempt.authorization_ref),
         :ok <- LocalAuthorizationBackend.finalize_handoff(attempt.authorization_ref),
         :ok <- mark_fenced(operation.id, attempt.attempt_ref, operation.connection_id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :stale_version}
    end
  end

  @doc false
  def reconcile(operation_id) when is_binary(operation_id) do
    with %Operation{status: "prepared"} = operation <- Repo.get(Operation, operation_id),
         %AuthorizationAttempt{} = attempt <-
           Repo.get(AuthorizationAttempt, operation.attempt_ref) do
      case operation.handoff_ref do
        handoff_ref when is_binary(handoff_ref) ->
          reconcile_handoff(operation, attempt, handoff_ref)

        nil ->
          case LocalAuthorizationBackend.reconcile_callback(operation.id, attempt.attempt_ref) do
            {:ok, :not_completed} ->
              fence(operation.id)

            {:ok, %{credential_material: {:write_only_handoff, handoff_ref}}} ->
              reconcile_handoff(operation, attempt, handoff_ref)

            {:error, _reason} ->
              {:error, :authorization_backend_unavailable}

            _other ->
              {:error, :authorization_backend_unavailable}
          end
      end
    else
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp cas(operation) do
    Transition.mutate(
      operation.connection_id,
      operation.expected_connection_version,
      :active,
      fn connection ->
        attempt = lock_attempt(operation.attempt_ref)
        operation = lock_operation(operation.id)

        with %Operation{status: "backend_committed"} <- operation,
             %AuthorizationAttempt{} <- attempt,
             true <- operation.expected_credential_version == connection.credential_version,
             true <- is_binary(operation.result_ref),
             true <- is_integer(operation.result_credential_version),
             true <- operation.attempt_version == attempt.attempt_version,
             true <- operation.attempt_claim_token == attempt.claim_token do
          operation
          |> Ecto.Changeset.change(status: "connection_committed")
          |> Repo.update!()

          {:ok,
           %{
             credential_backend_ref: operation.result_ref,
             credential_version: operation.result_credential_version,
             backend_pair_id: operation.backend_pair_id,
             authorization_backend_id: binding(operation, :authorization),
             credential_backend_id: binding(operation, :credential),
             status: "active"
           }}
        else
          _ -> {:error, :stale_version}
        end
      end
    )
    |> case do
      {:ok, _connection} ->
        finalize(Repo.get!(Operation, operation.id))

      {:error, reason} ->
        case cleanup(operation.id) do
          :ok -> {:error, :connection_terminal}
          {:error, _cleanup_reason} -> {:error, reason}
        end
    end
  end

  defp mark_cleanup_pending_if_terminal(%Operation{status: "cleanup_pending"} = operation) do
    connection = Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id)

    if connection.status in ["revoking", "disconnecting"],
      do: {:ok, operation},
      else: {:error, :stale_version}
  end

  defp mark_cleanup_pending_if_terminal(%Operation{status: "backend_committed"} = operation) do
    connection = Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id)

    if connection.status in ["revoking", "disconnecting"] do
      operation
      |> Ecto.Changeset.change(status: "cleanup_pending", safe_error_code: "cleanup_pending")
      |> Repo.update()
    else
      {:error, :stale_version}
    end
  end

  defp mark_cleanup_pending_if_terminal(_operation), do: {:error, :credential_conflict}

  defp reconcile_handoff(operation, attempt, handoff_ref) do
    with {:ok, operation} <- ensure_reconciled_handoff(operation, handoff_ref),
         {:ok, result} <-
           LocalAuthorizationBackend.handoff_reconciled_to_registered_credential(
             operation.id,
             attempt.attempt_ref
           ),
         {:ok, operation} <- journal_reconciled_result(operation.id, result),
         :ok <- cleanup(operation.id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp ensure_reconciled_handoff(operation, handoff_ref) do
    case Repo.get(Operation, operation.id) do
      %Operation{handoff_ref: ^handoff_ref} = current ->
        {:ok, current}

      %Operation{handoff_ref: nil} ->
        bind_reconciled_handoff(operation.id, handoff_ref)

      _other ->
        {:error, :stale_version}
    end
  end

  defp bind_reconciled_handoff(operation_id, handoff_ref) do
    connection_id = Repo.get!(Operation, operation_id).connection_id

    Repo.transaction(fn ->
      connection = lock_connection(connection_id)
      operation = lock_operation(operation_id)

      if operation.status == "prepared" and is_nil(operation.handoff_ref) and
           connection.status in ["revoking", "disconnecting"] and
           connection.connection_version == operation.expected_connection_version + 1 do
        operation
        |> Ecto.Changeset.change(handoff_ref: handoff_ref)
        |> Repo.update!()
      else
        Repo.rollback(:stale_version)
      end
    end)
  end

  defp journal_reconciled_result(operation_id, result) do
    connection_id = Repo.get!(Operation, operation_id).connection_id

    Repo.transaction(fn ->
      connection = lock_connection(connection_id)
      operation = lock_operation(operation_id)

      if operation.status == "prepared" and
           connection.status in ["revoking", "disconnecting"] and
           connection.connection_version == operation.expected_connection_version + 1 and
           connection.credential_version == operation.expected_credential_version do
        operation
        |> Operation.cleanup_pending_changeset(%{
          result_ref: result.credential_ref,
          result_credential_version: result.credential_version,
          safe_error_code: "cleanup_pending"
        })
        |> Repo.update!()
      else
        Repo.rollback(:stale_version)
      end
    end)
  end

  defp revoke_result(operation, backend) do
    case backend.revoke(%{
           credential_ref: operation.result_ref,
           expected_credential_version: operation.result_credential_version,
           correlation_id: operation.correlation_id <> ":terminal-cleanup"
         }) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp mark_cleanup_finalized(operation_id, attempt_ref) do
    Repo.transaction(fn ->
      operation = lock_operation(operation_id)
      attempt = lock_attempt(attempt_ref)

      with %Operation{status: "cleanup_pending"} <- operation,
           %AuthorizationAttempt{} <- attempt do
        attempt
        |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
        |> Repo.update!()

        operation
        |> Ecto.Changeset.change(
          status: "finalized",
          safe_error_code: nil,
          next_recovery_at: nil
        )
        |> Repo.update!()

        :ok
      else
        _ -> Repo.rollback(:credential_conflict)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_fenced(operation_id, attempt_ref, connection_id) do
    Repo.transaction(fn ->
      connection = lock_connection(connection_id)
      attempt = lock_attempt(attempt_ref)
      operation = lock_operation(operation_id)

      with %Operation{status: "prepared"} <- operation,
           %AuthorizationAttempt{} <- attempt,
           true <- connection.status in ["revoking", "disconnecting"] do
        attempt
        |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
        |> Repo.update!()

        operation
        |> Ecto.Changeset.change(status: "fenced", safe_error_code: "connection_terminal")
        |> Repo.update!()

        :ok
      else
        _ -> Repo.rollback(:stale_version)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize(%Operation{} = operation) do
    attempt = Repo.get(AuthorizationAttempt, operation.attempt_ref)
    connection = Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id)

    with %AuthorizationAttempt{} <- attempt,
         {:ok, _pair, _driver, backend} <- RuntimeBindings.resolve(connection, operation),
         :ok <- revoke_prior(operation, backend),
         :ok <- LocalAuthorizationBackend.prepare_handoff_finalization(attempt.authorization_ref),
         :ok <- LocalAuthorizationBackend.finalize_handoff(attempt.authorization_ref),
         {:ok, finalized} <- mark_finalized(operation.id, attempt.attempt_ref) do
      {:ok, finalized}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :credential_conflict}
    end
  end

  defp revoke_prior(
         %Operation{prior_credential_ref: nil, prior_credential_version: nil},
         _backend
       ),
       do: :ok

  defp revoke_prior(
         %Operation{
           prior_credential_ref: prior_ref,
           prior_credential_version: prior_version
         } = operation,
         backend
       )
       when is_binary(prior_ref) and is_integer(prior_version) do
    case backend.revoke(%{
           credential_ref: prior_ref,
           expected_credential_version: prior_version,
           correlation_id: operation.correlation_id <> ":old"
         }) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      {:error, _reason} -> {:error, :authorization_backend_unavailable}
    end
  end

  defp revoke_prior(%Operation{}, _backend), do: {:error, :credential_conflict}

  defp binding(operation, kind) do
    connection = Repo.get!(Ezagent.ProviderConnection.Connection, operation.connection_id)

    case RuntimeBindings.resolve(connection, operation) do
      {:ok, pair, _driver, _backend} ->
        if kind == :authorization,
          do: pair.authorization_backend.id,
          else: pair.credential_backend.id

      _ ->
        nil
    end
  end

  defp mark_finalized(operation_id, attempt_ref) do
    Repo.transaction(fn ->
      attempt = lock_attempt(attempt_ref)
      operation = lock_operation(operation_id)

      case operation do
        %Operation{status: "finalized"} ->
          operation

        %Operation{status: "connection_committed"} ->
          attempt
          |> Ecto.Changeset.change(
            status: "consumed",
            claim_token: nil,
            claim_until: nil,
            consumed_at: attempt.consumed_at || DateTime.utc_now()
          )
          |> Repo.update!()

          operation
          |> Ecto.Changeset.change(status: "finalized", next_recovery_at: nil)
          |> Repo.update!()

        _ ->
          Repo.rollback(:credential_conflict)
      end
    end)
  end

  defp lock_operation(id),
    do: Operation |> where([row], row.id == ^id) |> lock("FOR UPDATE") |> Repo.one()

  defp lock_connection(id),
    do:
      Ezagent.ProviderConnection.Connection
      |> where([row], row.connection_id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_attempt(id),
    do:
      AuthorizationAttempt
      |> where([row], row.attempt_ref == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()
end
