defmodule Ezagent.ProviderConnection.Termination do
  @moduledoc "Durable, fenced revoke/disconnect operations."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    Connection,
    CredentialReplacement,
    Operation,
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

        attrs
        |> Operation.create_changeset()
        |> Ecto.Changeset.change(handoff_ref: locked.credential_backend_ref)
        |> Repo.insert!()
      end)

      {:ok, %{status: Atom.to_string(target)}}
    end)
    |> case do
      {:ok, _} -> {:ok, operations(connection.connection_id, action, expected_version)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_retry(operations, connection, pair, expected_version) do
    if Enum.all?(operations, fn operation ->
         operation.connection_id == connection.connection_id and
           operation.workspace_uri == connection.workspace_uri and
           operation.backend_pair_id == pair.pair_id and
           operation.expected_connection_version == expected_version
       end) do
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
          correlation_id: operation.correlation_id
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

      Enum.all?(operations, &(&1.status == "backend_committed")) and
          callback_obligations_complete?(connection.connection_id) ->
        terminal = if action == :revoke, do: :revoked, else: :disconnected

        Transition.mutate(connection.connection_id, expected_version + 1, terminal, fn _locked ->
          Enum.each(operations, fn operation ->
            operation
            |> Ecto.Changeset.change(
              status: "finalized",
              safe_error_code: nil,
              next_recovery_at: nil
            )
            |> Repo.update!()
          end)

          {:ok, %{status: Atom.to_string(terminal)}}
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
        row.connection_id == ^connection_id and row.operation_class == "store" and
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

  defp callback_obligations_complete?(connection_id) do
    incomplete_operation? =
      Repo.exists?(
        from(row in Operation,
          where:
            row.connection_id == ^connection_id and row.operation_class == "store" and
              row.status not in ["finalized", "fenced"]
        )
      )

    consuming_attempt? =
      Repo.exists?(
        from(row in AuthorizationAttempt,
          where: row.connection_id == ^connection_id and row.status == "consuming"
        )
      )

    not incomplete_operation? and not consuming_attempt?
  end

  defp operations(connection_id, action, expected_version) do
    prefix = "termination:#{action}:#{connection_id}:#{expected_version}:"

    Operation
    |> where(
      [o],
      o.connection_id == ^connection_id and o.operation_class == ^Atom.to_string(action) and
        like(o.correlation_id, ^"#{prefix}%")
    )
    |> order_by([o], asc: o.correlation_id)
    |> Repo.all()
  end

  defp obligation(operation) do
    if String.ends_with?(operation.correlation_id, ":provider"), do: :provider, else: :credential
  end

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
          row.attempt_ref == ^attempt.attempt_ref and row.operation_class == "store"
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
