defmodule Ezagent.ProviderConnection.Refresh do
  @moduledoc "Durable, fenced refresh orchestration."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{Connection, Operation, RuntimeBindings, Transition}
  alias EzagentCore.Repo

  @lease_seconds 30

  @doc false
  def execute(%Connection{} = connection, args, now \\ DateTime.utc_now()) do
    with {:ok, pair, driver, backend} <- RuntimeBindings.resolve(connection),
         {:ok, operation} <- prepare_or_resume(connection, pair, args, now) do
      resume(operation, driver.implementation, backend, now)
    end
  end

  defp prepare_or_resume(connection, pair, args, now) do
    command_digest = digest(connection, pair.pair_id, args)

    case Repo.get_by(Operation,
           backend_pair_id: pair.pair_id,
           operation_class: "refresh",
           correlation_id: args.correlation_id
         ) do
      %Operation{} = operation ->
        if operation.connection_id == connection.connection_id and
             operation.workspace_uri == connection.workspace_uri and
             operation.backend_pair_id == pair.pair_id and
             operation.expected_connection_version == args.expected_version and
             operation.bound_input_digest == command_digest do
          reclaim_expired(operation, connection, now)
        else
          {:error, :correlation_conflict}
        end

      nil ->
        prepare(connection, pair, args, command_digest, now)
    end
  end

  defp reclaim_expired(%Operation{status: "prepared"} = operation, connection, now) do
    if expired_lease?(operation.lease_until, now) and
         expired_lease?(connection.refresh_lease_until, now) do
      Repo.transaction(fn ->
        locked_connection = lock_connection(connection.connection_id)
        locked_operation = lock_operation(operation.id)

        if locked_connection.status == "refreshing" and
             locked_connection.connection_version == operation.expected_connection_version + 1 and
             locked_operation.status == "prepared" and
             expired_lease?(locked_operation.lease_until, now) and
             expired_lease?(locked_connection.refresh_lease_until, now) do
          token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          lease_version =
            max(locked_connection.refresh_lease_version, operation.attempt_version) + 1

          lease_until = DateTime.add(now, @lease_seconds, :second)

          locked_connection
          |> Ecto.Changeset.change(
            refresh_lease_token: token,
            refresh_lease_until: lease_until,
            refresh_lease_version: lease_version
          )
          |> Repo.update!()

          locked_operation
          |> Ecto.Changeset.change(
            lease_token: token,
            lease_until: lease_until,
            attempt_version: lease_version
          )
          |> Repo.update!()
        else
          Repo.rollback(:refresh_lease_lost)
        end
      end)
    else
      {:error, :refresh_in_progress}
    end
  end

  defp reclaim_expired(operation, _connection, _now), do: {:ok, operation}

  defp expired_lease?(lease_until, now) when is_struct(lease_until, DateTime),
    do: DateTime.compare(lease_until, now) in [:lt, :eq]

  defp expired_lease?(_lease_until, _now), do: false

  defp prepare(connection, pair, args, command_digest, now) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    lease_version = connection.refresh_lease_version + 1

    Transition.mutate(connection.connection_id, args.expected_version, :refreshing, fn locked ->
      with :ok <- refresh_source_available(locked, now) do
        operation =
          %{
            correlation_id: args.correlation_id,
            bound_input_digest: command_digest,
            attempt_version: lease_version,
            next_recovery_at: now,
            status: "prepared"
          }
          |> then(&Operation.refresh_create_changeset(locked, &1))
          |> Ecto.Changeset.change(
            prior_credential_ref: locked.credential_backend_ref,
            prior_credential_version: locked.credential_version,
            lease_token: token,
            lease_until: DateTime.add(now, @lease_seconds, :second)
          )
          |> Repo.insert!()

        {:ok,
         %{
           status: "refreshing",
           refresh_lease_token: token,
           refresh_lease_until: operation.lease_until,
           refresh_lease_version: lease_version
         }}
      end
    end)
    |> case do
      {:ok, _} ->
        {:ok,
         Repo.get_by!(Operation,
           backend_pair_id: pair.pair_id,
           operation_class: "refresh",
           correlation_id: args.correlation_id
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_source_available(%Connection{status: "refresh_required"}, _now), do: :ok

  defp refresh_source_available(
         %Connection{status: "refreshing", refresh_lease_until: until},
         now
       )
       when is_struct(until, DateTime) do
    if DateTime.compare(now, until) in [:eq, :gt],
      do: :ok,
      else: {:error, :refresh_in_progress}
  end

  defp refresh_source_available(_connection, _now), do: {:error, :connection_terminal}

  defp resume(%Operation{status: "finalized"} = operation, _driver, _backend, _now),
    do: result(operation)

  defp resume(%Operation{status: "prepared"} = operation, driver, backend, now) do
    context = %{
      connection_id: operation.connection_id,
      correlation_id: operation.correlation_id,
      expected_connection_version: operation.expected_connection_version,
      expected_credential_version: operation.expected_credential_version
    }

    with :ok <- pre_effect_fence(operation, now),
         {:ok, provider_result} <- driver.refresh(context),
         {:ok, material} <- Map.fetch(provider_result, :credential_material),
         :ok <- pre_effect_fence(operation, now),
         {:ok, credential_result} <-
           backend.replace(%{
             credential_material: material,
             backend_pair_id: operation.backend_pair_id,
             operation_class: operation.operation_class,
             correlation_id: operation.correlation_id,
             bound_input_digest: operation.bound_input_digest,
             expected_credential_version: operation.expected_credential_version
           }),
         :ok <- validate_credential_result(credential_result) do
      journal_and_commit(operation, provider_result, credential_result, backend, now)
    else
      {:error, :refresh_lease_lost} = error -> error
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp resume(%Operation{status: "backend_committed"} = operation, _driver, backend, now),
    do: commit_pointer(operation, durable_metadata(operation), backend, now)

  defp resume(%Operation{status: "connection_committed"} = operation, _driver, backend, _now),
    do: revoke_prior_and_finalize(operation, backend)

  defp resume(%Operation{status: "cleanup_pending"}, _driver, _backend, _now),
    do: {:error, :refresh_lease_lost}

  defp journal_and_commit(operation, provider_result, credential_result, backend, now) do
    Repo.transaction(fn ->
      connection = lock_connection(operation.connection_id)
      operation = lock_operation(operation.id)

      attrs = %{
        result_ref: credential_result.credential_ref,
        result_credential_version: credential_result.credential_version,
        result_permission_digest: Map.get(provider_result, :permission_digest),
        result_expires_at: Map.get(provider_result, :expires_at)
      }

      if operation.status == "prepared" and valid_lease?(connection, operation, now) do
        operation
        |> Ecto.Changeset.change(Map.put(attrs, :status, "backend_committed"))
        |> Repo.update!()
      else
        operation
        |> Ecto.Changeset.change(
          Map.merge(attrs, %{status: "cleanup_pending", safe_error_code: "cleanup_pending"})
        )
        |> Repo.update!()
      end
    end)
    |> case do
      {:ok, %Operation{status: "backend_committed"} = committed} ->
        commit_pointer(committed, durable_metadata(committed), backend, now)

      {:ok, %Operation{status: "cleanup_pending"} = stale} ->
        idempotency_key = stale.correlation_id <> ":stale"

        _ =
          backend.revoke(%{
            credential_ref: stale.result_ref,
            correlation_id: idempotency_key,
            idempotency_key: idempotency_key
          })

        {:error, :refresh_lease_lost}

      {:error, _} ->
        {:error, :credential_conflict}
    end
  end

  defp commit_pointer(operation, metadata, backend, now) do
    Transition.mutate(
      operation.connection_id,
      operation.expected_connection_version + 1,
      :active,
      fn connection ->
        operation = lock_operation(operation.id)

        if operation.status == "backend_committed" and valid_lease?(connection, operation, now) do
          operation |> Ecto.Changeset.change(status: "connection_committed") |> Repo.update!()

          {:ok,
           %{
             status: "active",
             credential_backend_ref: operation.result_ref,
             credential_version: operation.result_credential_version,
             permission_digest: metadata.permission_digest,
             expires_at: metadata.expires_at,
             refresh_lease_token: nil,
             refresh_lease_until: nil
           }}
        else
          {:error, :refresh_lease_lost}
        end
      end
    )
    |> case do
      {:ok, _} -> revoke_prior_and_finalize(Repo.get!(Operation, operation.id), backend)
      {:error, _} -> compensate(operation, backend)
    end
  end

  defp revoke_prior_and_finalize(operation, backend) do
    idempotency_key = operation.correlation_id <> ":old"

    case backend.revoke(%{
           credential_ref: operation.prior_credential_ref,
           expected_credential_version: operation.prior_credential_version,
           correlation_id: idempotency_key,
           idempotency_key: idempotency_key
         }) do
      :ok -> finalize(operation)
      {:ok, _receipt} -> finalize(operation)
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp finalize(operation) do
    operation
    |> Ecto.Changeset.change(
      status: "finalized",
      safe_error_code: nil,
      next_recovery_at: nil
    )
    |> Repo.update!()

    result(operation)
  end

  defp compensate(operation, backend) do
    idempotency_key = operation.correlation_id <> ":stale"

    _ =
      backend.revoke(%{
        credential_ref: operation.result_ref,
        correlation_id: idempotency_key,
        idempotency_key: idempotency_key
      })

    operation
    |> Ecto.Changeset.change(status: "cleanup_pending", safe_error_code: "cleanup_pending")
    |> Repo.update!()

    {:error, :refresh_lease_lost}
  end

  defp pre_effect_fence(operation, now) do
    Repo.transaction(fn ->
      connection = lock_connection(operation.connection_id)
      operation = lock_operation(operation.id)

      if operation.status == "prepared" and valid_lease?(connection, operation, now),
        do: :ok,
        else: Repo.rollback(:refresh_lease_lost)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_lease?(connection, operation, now) do
    connection.connection_version == operation.expected_connection_version + 1 and
      connection.credential_version == operation.expected_credential_version and
      connection.refresh_lease_token == operation.lease_token and
      connection.refresh_lease_version == operation.attempt_version and
      is_struct(operation.lease_until, DateTime) and
      DateTime.compare(operation.lease_until, now) == :gt and
      is_struct(connection.refresh_lease_until, DateTime) and
      DateTime.compare(connection.refresh_lease_until, now) == :gt
  end

  defp validate_credential_result(%{credential_ref: ref, credential_version: version})
       when is_binary(ref) and ref != "" and is_integer(version) and version >= 0,
       do: :ok

  defp validate_credential_result(_result), do: {:error, :credential_conflict}

  defp durable_metadata(operation),
    do: %{
      permission_digest: operation.result_permission_digest,
      expires_at: operation.result_expires_at
    }

  defp result(operation) do
    connection = Repo.get!(Connection, operation.connection_id)

    {:ok,
     %{
       connection_id: connection.connection_id,
       status: connection.status,
       version: connection.connection_version
     }}
  end

  defp digest(connection, pair_id, args) do
    {:refresh_v1, connection.connection_id, connection.workspace_uri, connection.owner_uri,
     connection.provider_id, connection.governed_host, connection.execution_identity,
     connection.acquisition_method, args.expected_version, pair_id, "refresh",
     args.correlation_id}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp lock_connection(id),
    do: Connection |> where([row], row.connection_id == ^id) |> lock("FOR UPDATE") |> Repo.one()

  defp lock_operation(id),
    do: Operation |> where([row], row.id == ^id) |> lock("FOR UPDATE") |> Repo.one()
end
