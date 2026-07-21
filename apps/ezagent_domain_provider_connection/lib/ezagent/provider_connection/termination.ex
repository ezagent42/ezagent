defmodule Ezagent.ProviderConnection.Termination do
  @moduledoc "Durable, fenced revoke/disconnect operations."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    CallbackTerminalProof,
    Connection,
    CredentialReplacement,
    Operation,
    ProviderAuthorizationCommand,
    RowLock,
    RuntimeBindings,
    Transition
  }

  alias EzagentCore.Repo

  @doc false
  def execute(%Connection{} = connection, action, expected_version, now \\ DateTime.utc_now())
      when action in [:revoke, :disconnect] do
    with {:ok, pair, driver, backend} <- RuntimeBindings.resolve(connection),
         {:ok, operations} <- prepare_or_resume(connection, pair, action, expected_version, now),
         operations <- run_obligations(operations, connection, driver.implementation, backend),
         result <- finish_or_report(operations, connection, action, expected_version) do
      result
    end
  end

  defp prepare_or_resume(connection, pair, action, expected_version, now) do
    operations = operations(connection.connection_id, action, expected_version)

    case operations do
      [] ->
        prepare(connection, pair, action, expected_version, now)

      [_provider, _credential] ->
        validate_retry(operations, connection, pair, expected_version)

      _ ->
        {:error, :correlation_conflict}
    end
  end

  defp prepare(connection, pair, action, expected_version, now) do
    target = if action == :revoke, do: :revoking, else: :disconnecting

    Transition.mutate(connection.connection_id, expected_version, target, fn locked ->
      _callback_observation = lock_callback_reservation(locked.connection_id)

      Enum.each(["provider", "credential"], fn obligation ->
        attrs = %{
          workspace_uri: locked.workspace_uri,
          connection_id: locked.connection_id,
          backend_pair_id: pair.pair_id,
          operation_class: Atom.to_string(action),
          correlation_id: correlation(action, locked.connection_id, expected_version, obligation),
          bound_input_digest: digest(locked, pair.pair_id, action, expected_version),
          expected_connection_version: expected_version,
          expected_credential_version: locked.credential_version,
          next_recovery_at: now,
          status: "prepared"
        }

        changeset = Operation.create_changeset(attrs)

        changeset =
          if obligation == "credential",
            do: Ecto.Changeset.change(changeset, handoff_ref: locked.credential_backend_ref),
            else: changeset

        Repo.insert!(changeset)
      end)

      {:ok, %{status: Atom.to_string(target)}}
    end)
    |> case do
      {:ok, _} -> {:ok, operations(connection.connection_id, action, expected_version)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_retry(operations, connection, pair, expected_version) do
    if exact_terminal_operation_set?(
         operations,
         connection,
         pair.pair_id,
         operation_action(operations),
         expected_version,
         ["prepared", "backend_committed", "finalized"]
       ) do
      {:ok, operations}
    else
      {:error, :correlation_conflict}
    end
  end

  defp run_obligations(operations, connection, driver, backend) do
    Enum.map(operations, fn operation ->
      case {obligation(operation), operation.status} do
        {_kind, status} when status in ["backend_committed", "finalized"] -> operation
        {:provider, "prepared"} -> run_provider(operation, connection, driver)
        {:credential, "prepared"} -> run_credential(operation, connection, backend)
        _ -> operation
      end
    end)
  end

  defp run_provider(operation, connection, driver) do
    result =
      with :ok <- pre_effect_fence(operation, connection) do
        driver.revoke(%{
          connection_id: connection.connection_id,
          provider_id: connection.provider_id,
          governed_host: connection.governed_host,
          execution_identity: connection.execution_identity,
          correlation_id: operation.correlation_id
        })
      end

    journal_obligation(operation, result)
  end

  defp run_credential(operation, connection, backend) do
    result =
      with :ok <- pre_effect_fence(operation, connection) do
        backend.revoke(%{
          credential_ref: operation.handoff_ref,
          expected_credential_version: operation.expected_credential_version,
          correlation_id: operation.correlation_id,
          idempotency_key: operation.correlation_id
        })
      end

    journal_obligation(operation, result)
  end

  defp journal_obligation(operation, result) do
    successful? = result == :ok or match?({:ok, _}, result)

    operation
    |> Ecto.Changeset.change(
      status: if(successful?, do: "backend_committed", else: "prepared"),
      safe_error_code: if(successful?, do: nil, else: "backend_unavailable")
    )
    |> Repo.update!()
  end

  defp finish_or_report(operations, connection, action, expected_version) do
    resume_callback_cleanup(connection.connection_id)

    cond do
      Enum.all?(operations, &(&1.status == "finalized")) ->
        current = Repo.get!(Connection, connection.connection_id)

        {:ok,
         %{
           connection_id: current.connection_id,
           status: current.status,
           version: current.connection_version
         }}

      Enum.all?(operations, &(&1.status == "backend_committed")) ->
        terminal = if action == :revoke, do: :revoked, else: :disconnected

        Transition.mutate(connection.connection_id, expected_version + 1, terminal, fn locked ->
          with {:ok, locked_operations} <- callback_obligations_complete_locked(locked),
               {:ok, terminal_operations} <-
                 terminal_operations_locked(
                   locked_operations,
                   locked,
                   action,
                   expected_version
                 ) do
            Enum.each(terminal_operations, fn operation ->
              operation
              |> Ecto.Changeset.change(
                status: "finalized",
                safe_error_code: nil,
                next_recovery_at: nil
              )
              |> Repo.update!()
            end)

            {:ok, %{status: Atom.to_string(terminal)}}
          end
        end)
        |> case do
          {:ok, updated} ->
            {:ok,
             %{
               connection_id: updated.connection_id,
               status: updated.status,
               version: updated.connection_version
             }}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :authorization_backend_unavailable}
    end
  end

  defp resume_callback_cleanup(connection_id) do
    operations =
      Operation
      |> where(
        [row],
        row.connection_id == ^connection_id and row.operation_class in ["store", "replace"] and
          row.status in ["prepared", "backend_committed", "cleanup_pending"]
      )
      |> Repo.all()

    Enum.each(operations, fn
      %Operation{status: "prepared"} = operation ->
        attempt = Repo.get(AuthorizationAttempt, operation.attempt_ref)

        if claim_expired?(attempt), do: CredentialReplacement.reconcile(operation.id)

      operation ->
        _ = CredentialReplacement.cleanup(operation.id)
    end)
  end

  defp claim_expired?(%AuthorizationAttempt{status: "consuming", claim_until: claim_until})
       when is_struct(claim_until, DateTime),
       do: DateTime.compare(claim_until, DateTime.utc_now()) != :gt

  defp claim_expired?(%AuthorizationAttempt{status: status})
       when status in ["cancelled", "expired"],
       do: true

  defp claim_expired?(_attempt), do: false

  defp callback_obligations_complete_locked(%Connection{} = connection) do
    attempts =
      AuthorizationAttempt
      |> where([row], row.connection_id == ^connection.connection_id)
      |> order_by([row], asc: row.attempt_ref)
      |> lock("FOR UPDATE")
      |> Repo.all()

    operations =
      Operation
      |> where([row], row.connection_id == ^connection.connection_id)
      |> order_by([row], asc: row.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    callback_operations =
      Enum.filter(operations, &(&1.operation_class in ["store", "replace"]))

    attempts_by_ref = Map.new(attempts, &{&1.attempt_ref, &1})

    commands =
      Map.new(callback_operations, fn operation ->
        attempt = Map.get(attempts_by_ref, operation.attempt_ref)
        {operation.id, lock_callback_command(operation, attempt)}
      end)

    records =
      Map.new(callback_operations, fn operation ->
        {operation.id, RowLock.authorization_backend_record(operation.expected_authorization_ref)}
      end)

    complete? =
      Enum.all?(attempts, &(&1.status != "consuming")) and
        Enum.all?(callback_operations, fn operation ->
          callback_operation_proven?(
            connection,
            operation,
            Map.get(attempts_by_ref, operation.attempt_ref),
            Map.get(commands, operation.id),
            Map.get(records, operation.id)
          )
        end)

    if complete?,
      do: {:ok, operations},
      else: {:error, :authorization_backend_unavailable}
  end

  defp callback_operation_proven?(
         connection,
         %Operation{status: "fenced"} = operation,
         %AuthorizationAttempt{status: "cancelled"} = attempt,
         %ProviderAuthorizationCommand{} = command,
         %AuthorizationBackendRecord{} = record
       ) do
    exact_closing_lineage?(connection, operation) and
      Operation.provider_result_unowned?(operation) and
      cleanup_not_required?(operation) and is_nil(attempt.claim_token) and
      is_nil(attempt.claim_until) and
      CallbackTerminalProof.classify(connection, operation, attempt, command, record) ==
        :confirmed_absence
  end

  defp callback_operation_proven?(
         connection,
         %Operation{status: "finalized"} = operation,
         %AuthorizationAttempt{status: "cancelled"} = attempt,
         %ProviderAuthorizationCommand{} = command,
         %AuthorizationBackendRecord{} = record
       ) do
    exact_closing_lineage?(connection, operation) and
      operation.provider_cleanup_status == "confirmed" and
      operation.credential_cleanup_status == "confirmed" and
      is_nil(operation.provider_cleanup_error_code) and
      is_nil(operation.credential_cleanup_error_code) and
      is_nil(attempt.claim_token) and is_nil(attempt.claim_until) and
      CallbackTerminalProof.classify(connection, operation, attempt, command, record) ==
        {:handoff, :shredded}
  end

  defp callback_operation_proven?(
         connection,
         %Operation{status: "finalized"} = operation,
         %AuthorizationAttempt{status: "consumed", consumed_at: %DateTime{}} = attempt,
         %ProviderAuthorizationCommand{} = command,
         %AuthorizationBackendRecord{} = record
       ) do
    monotonic_success_lineage?(connection, operation) and
      is_nil(attempt.claim_token) and is_nil(attempt.claim_until) and
      CallbackTerminalProof.classify(connection, operation, attempt, command, record) ==
        {:handoff, :shredded}
  end

  defp callback_operation_proven?(_connection, _operation, _attempt, _command, _record),
    do: false

  defp terminal_operations_locked(operations, connection, action, expected_version) do
    action_operations =
      Enum.filter(operations, fn operation ->
        operation.connection_id == connection.connection_id and
          operation.operation_class == Atom.to_string(action)
      end)

    if exact_terminal_operation_set?(
         action_operations,
         connection,
         connection.backend_pair_id,
         action,
         expected_version,
         ["backend_committed"]
       ),
       do: {:ok, action_operations},
       else: {:error, :authorization_backend_unavailable}
  end

  defp exact_closing_lineage?(connection, operation) do
    connection.connection_version == operation.expected_connection_version + 1 and
      connection.authorization_version == operation.expected_authorization_version and
      connection.credential_version == operation.expected_credential_version
  end

  defp monotonic_success_lineage?(connection, operation) do
    is_integer(operation.result_authorization_version) and
      is_integer(operation.result_credential_version) and
      connection.connection_version >= operation.expected_connection_version + 2 and
      connection.authorization_version >= operation.result_authorization_version and
      connection.credential_version >= operation.result_credential_version and
      connection.external_account_id == operation.result_external_account_id and
      connection.execution_identity == operation.result_execution_identity
  end

  defp exact_terminal_operation_set?(
         operations,
         connection,
         pair_id,
         action,
         expected_version,
         allowed_statuses
       )
       when action in [:revoke, :disconnect] do
    by_correlation = Map.new(operations, &{&1.correlation_id, &1})
    expected = correlations(action, connection.connection_id, expected_version)

    length(operations) == 2 and MapSet.new(Map.keys(by_correlation)) == MapSet.new(expected) and
      Enum.all?(["provider", "credential"], fn obligation ->
        operation =
          Map.fetch!(
            by_correlation,
            correlation(action, connection.connection_id, expected_version, obligation)
          )

        terminal_operation_coordinates?(
          operation,
          connection,
          pair_id,
          action,
          expected_version,
          obligation,
          allowed_statuses
        )
      end)
  end

  defp exact_terminal_operation_set?(
         _operations,
         _connection,
         _pair_id,
         _action,
         _expected_version,
         _allowed_statuses
       ),
       do: false

  defp terminal_operation_coordinates?(
         operation,
         connection,
         pair_id,
         action,
         expected_version,
         obligation,
         allowed_statuses
       ) do
    operation.workspace_uri == connection.workspace_uri and
      operation.connection_id == connection.connection_id and
      operation.backend_pair_id == pair_id and
      operation.operation_class == Atom.to_string(action) and
      operation.correlation_id ==
        correlation(action, connection.connection_id, expected_version, obligation) and
      operation.bound_input_digest == digest(connection, pair_id, action, expected_version) and
      operation.expected_connection_version == expected_version and
      operation.expected_credential_version == connection.credential_version and
      operation.status in allowed_statuses and
      terminal_handoff_matches?(operation, connection, obligation)
  end

  defp terminal_handoff_matches?(operation, _connection, "provider"),
    do: is_nil(operation.handoff_ref)

  defp terminal_handoff_matches?(operation, connection, "credential"),
    do: operation.handoff_ref == connection.credential_backend_ref

  defp operation_action([%Operation{operation_class: "revoke"} | _operations]), do: :revoke

  defp operation_action([%Operation{operation_class: "disconnect"} | _operations]),
    do: :disconnect

  defp operation_action(_operations), do: :invalid

  defp lock_callback_command(_operation, nil), do: nil

  defp lock_callback_command(operation, attempt) do
    ProviderAuthorizationCommand
    |> where(
      [row],
      row.backend_pair_id == ^operation.backend_pair_id and row.operation_class == "consume" and
        row.correlation_id == ^attempt.correlation_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp cleanup_not_required?(operation) do
    operation.provider_cleanup_status == "not_required" and
      operation.credential_cleanup_status == "not_required" and
      is_nil(operation.provider_cleanup_error_code) and
      is_nil(operation.credential_cleanup_error_code)
  end

  defp operations(connection_id, action, expected_version) do
    correlations = correlations(action, connection_id, expected_version)

    Operation
    |> where(
      [o],
      o.connection_id == ^connection_id and o.operation_class == ^Atom.to_string(action) and
        o.correlation_id in ^correlations
    )
    |> order_by([o], asc: o.correlation_id)
    |> Repo.all()
  end

  defp obligation(operation) do
    action = operation_action([operation])

    cond do
      operation.correlation_id ==
          correlation(
            action,
            operation.connection_id,
            operation.expected_connection_version,
            "provider"
          ) ->
        :provider

      operation.correlation_id ==
          correlation(
            action,
            operation.connection_id,
            operation.expected_connection_version,
            "credential"
          ) ->
        :credential

      true ->
        :invalid
    end
  end

  defp correlations(action, connection_id, version),
    do:
      Enum.map(["provider", "credential"], fn obligation ->
        correlation(action, connection_id, version, obligation)
      end)

  defp correlation(action, connection_id, version, obligation),
    do: "termination:#{action}:#{connection_id}:#{version}:#{obligation}"

  defp pre_effect_fence(operation, connection) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_operation = lock_operation(operation.id)

      expected_status =
        if operation.operation_class == "revoke", do: "revoking", else: "disconnecting"

      if locked_connection.status == expected_status and
           locked_connection.connection_version == operation.expected_connection_version + 1 and
           locked_connection.credential_version == operation.expected_credential_version and
           locked_operation.status == "prepared",
         do: :ok,
         else: Repo.rollback(:connection_terminal)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_callback_reservation(connection_id) do
    attempt =
      AuthorizationAttempt
      |> where([row], row.connection_id == ^connection_id)
      |> order_by([row], desc: row.inserted_at, desc: row.attempt_ref)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> Repo.one()

    operation =
      if attempt do
        Operation
        |> where(
          [row],
          row.attempt_ref == ^attempt.attempt_ref and row.operation_class in ["store", "replace"]
        )
        |> lock("FOR UPDATE")
        |> Repo.one()
      end

    {attempt, operation}
  end

  defp lock_connection(connection_id),
    do:
      Connection
      |> where([row], row.connection_id == ^connection_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_operation(id),
    do: Operation |> where([row], row.id == ^id) |> lock("FOR UPDATE") |> Repo.one()

  defp digest(connection, pair_id, action, expected_version) do
    {:termination_v1, action, connection.connection_id, connection.workspace_uri,
     connection.owner_uri, connection.provider_id, connection.governed_host,
     connection.execution_identity, expected_version, connection.credential_version, pair_id}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
