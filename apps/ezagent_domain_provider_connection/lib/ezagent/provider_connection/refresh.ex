defmodule Ezagent.ProviderConnection.Refresh do
  @moduledoc "Durable, fenced refresh orchestration."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    Connection,
    CredentialRefreshExchange,
    Operation,
    RuntimeBindings,
    Transition
  }

  alias Ezagent.ProviderConnection.EffectBoundary

  alias EzagentCore.Repo

  @lease_seconds 30
  @test_build Mix.env() == :test

  @doc false
  def execute(%Connection{} = connection, args, now \\ DateTime.utc_now()) do
    with {:ok, pair, driver, backend} <- RuntimeBindings.resolve(connection),
         {:ok, operation} <- prepare_or_resume(connection, pair, args, now) do
      resume(operation, driver.implementation, backend, now)
    end
  end

  # A prepared refresh that has exhausted retries while the connection stays
  # in `refreshing` is a wedge: the provider effect never succeeded, the
  # connection's credential pointer may be stale or absent, recovery retries
  # forever at capped backoff, the active-binding unique index blocks
  # re-binding the same external account, and D1 revoke/disconnect is
  # Decision-B-fail-closed.  Escape: expire the connection (the pointer is
  # no longer trusted) and fence the operation out of the retry loop so the
  # owner can reauthorize.
  @max_refresh_attempts 12

  @doc false
  def recover(%Operation{} = operation, now \\ DateTime.utc_now()) do
    operation = Repo.get!(Operation, operation.id)
    connection = Repo.get!(Connection, operation.connection_id)

    cond do
      operation.status == "prepared" and connection.status == "refreshing" and
          operation.recovery_attempts >= @max_refresh_attempts ->
        expire_exhausted_refresh(connection, operation)

      operation.status == "prepared" and not provider_owned?(operation) ->
        connection
        |> execute(
          %{
            correlation_id: operation.correlation_id,
            expected_version: operation.expected_connection_version
          },
          now
        )
        |> compensate_superseded(operation.id, now)

      operation.status == "prepared" and
          operation.provider_cleanup_status in ["pending", "confirmed"] ->
        operation |> cleanup_operation() |> normalize_recovery_cleanup(operation.id)

      operation.status == "cleanup_pending" ->
        operation |> cleanup_operation() |> normalize_recovery_cleanup(operation.id)

      true ->
        connection
        |> execute(
          %{
            correlation_id: operation.correlation_id,
            expected_version: operation.expected_connection_version
          },
          now
        )
        |> compensate_superseded(operation.id, now)
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

  defp expire_exhausted_refresh(connection, operation) do
    Transition.mutate(
      connection.connection_id,
      connection.connection_version,
      :expired,
      fn _locked -> {:ok, %{status: "expired", last_error_code: "backend_unavailable"}} end
    )
    |> case do
      {:ok, _conn} ->
        # The durable ownership CHECK requires fenced rows to keep
        # next_recovery_at; recovery never re-selects fenced rows by
        # status (its phase queries only match prepared / backend_committed
        # / connection_committed / cleanup_pending), so the row leaves the
        # retry loop by status alone.
        operation
        |> Ecto.Changeset.change(
          status: "fenced",
          safe_error_code: "backend_unavailable"
        )
        |> Repo.update!()

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A prepared refresh whose fenced generation is provably behind the
  # connection can never win the pointer CAS again: a successor refresh has
  # already advanced the generation (`refreshing -> refreshing`). Reclaim
  # reports `:refresh_lease_lost` for a fully-expired contested lease and
  # `:refresh_in_progress` once the connection lease is gone (a committed
  # successor clears it), so BOTH codes are routed here. Without compensation
  # the row would retry the lost generation forever — worse, a provider-owned
  # row would keep a live provider-minted credential sealed behind
  # `handoff_ref` with no path to `discard_refresh_result/1`. Persist the
  # cleanup obligation first (no external effect inside the transaction),
  # then run the ordinary cleanup machinery; all-NULL rows need no effect and
  # are fenced out of the retry loop (the ownership-stage CHECK permits
  # fencing all-NULL rows).
  defp compensate_superseded({:error, reason} = error, operation_id, now)
       when reason in [:refresh_lease_lost, :refresh_in_progress] do
    operation = Repo.get!(Operation, operation_id)

    if superseded_preparation?(operation, now) do
      compensate_superseded_operation(operation)
    else
      error
    end
  end

  defp compensate_superseded(result, _operation_id, _now), do: result

  # The version fence is the only reliable supersession signal: a successor
  # refresh prepare CAS-advances the connection generation past the stale
  # operation's `expected_connection_version + 1`. A bare lease-token
  # mismatch is NOT proof — a fresh claim legitimately re-leases the SAME
  # operation (lease theft), and that operation must keep retrying until its
  # own reclaim succeeds.
  defp superseded_preparation?(%Operation{status: "prepared"} = operation, now) do
    connection = Repo.get!(Connection, operation.connection_id)

    expired_lease?(operation.lease_until, now) and
      connection.connection_version != operation.expected_connection_version + 1
  end

  defp superseded_preparation?(_operation, _now), do: false

  defp compensate_superseded_operation(operation) do
    if provider_owned?(operation) do
      case persist_superseded_cleanup(operation) do
        {:ok, updated} ->
          updated |> cleanup_operation() |> normalize_recovery_cleanup(updated.id)

        {:error, reason} ->
          {:error, reason}
      end
    else
      fence_superseded(operation)
    end
  end

  defp persist_superseded_cleanup(operation) do
    Repo.transaction(fn ->
      locked = lock_operation(operation.id)
      _connection = lock_connection(locked.connection_id)

      if locked.status == "prepared" and provider_owned?(locked) do
        locked
        |> Ecto.Changeset.change(
          status: "cleanup_pending",
          safe_error_code: "cleanup_pending",
          provider_cleanup_status: "pending",
          credential_cleanup_status:
            if(is_binary(locked.result_ref), do: "pending", else: "not_required")
        )
        |> Repo.update!()
      else
        Repo.rollback(:refresh_lease_lost)
      end
    end)
  end

  defp fence_superseded(operation) do
    Repo.transaction(fn ->
      locked = lock_operation(operation.id)
      _connection = lock_connection(locked.connection_id)

      # The durable ownership CHECK requires fenced rows to keep a non-NULL
      # next_recovery_at; recovery never re-selects fenced rows (its phase
      # queries only match prepared/backend_committed/connection_committed/
      # cleanup_pending), so the row is out of the retry loop by status.
      if locked.status == "prepared" and not provider_owned?(locked) do
        locked
        |> Ecto.Changeset.change(
          status: "fenced",
          safe_error_code: "refresh_lease_lost"
        )
        |> Repo.update!()
      else
        Repo.rollback(:refresh_lease_lost)
      end
    end)
    |> case do
      {:ok, _operation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp resume(
         %Operation{
           status: "finalized",
           provider_cleanup_status: "confirmed",
           credential_cleanup_status: "confirmed"
         },
         _driver,
         _backend,
         _now
       ),
       do: {:error, :refresh_lease_lost}

  defp resume(%Operation{status: "finalized"} = operation, _driver, _backend, _now),
    do: result(operation)

  defp resume(%Operation{status: "prepared"} = operation, _driver, backend, now) do
    cond do
      operation.provider_cleanup_status in ["pending", "confirmed"] ->
        cleanup_operation(operation)

      provider_owned?(operation) ->
        replace_and_journal(operation, backend, now)

      true ->
        connection = Repo.get!(Connection, operation.connection_id)

        with :ok <- pre_effect_fence(operation, now),
             {:ok, provider_result} <- reconcile_then_refresh(connection, operation),
             :ok <-
               test_crash_barrier(:sealed_provider_result, %{
                 operation_id: operation.id,
                 provider_result_ref: provider_result.provider_result_ref
               }),
             {:ok, {provider_owned, claim_current?}} <-
               journal_provider_ownership(operation, provider_result, now) do
          cond do
            provider_owned.provider_cleanup_status == "pending" ->
              cleanup_operation(provider_owned)

            claim_current? ->
              replace_and_journal(provider_owned, backend, now)

            true ->
              {:error, :refresh_in_progress}
          end
        else
          {:error, :refresh_lease_lost} = error ->
            error

          {:error, reason}
          when reason in [
                 :backend_unavailable,
                 :provider_denied,
                 :provider_protocol_failed,
                 :correlation_conflict
               ] ->
            normalize_exchange_error(operation, reason, now)

          _error ->
            {:error, :authorization_backend_unavailable}
        end
    end
  end

  defp resume(%Operation{status: "backend_committed"} = operation, _driver, backend, now),
    do: commit_pointer(operation, durable_metadata(operation), backend, now)

  defp resume(%Operation{status: "connection_committed"} = operation, _driver, backend, _now),
    do: revoke_prior_and_finalize(operation, backend)

  defp resume(%Operation{status: "cleanup_pending"} = operation, _driver, _backend, _now),
    do: cleanup_operation(operation)

  defp journal_provider_ownership(%Operation{} = invocation_operation, provider_result, _now) do
    Repo.transaction(fn ->
      operation = Repo.get!(Operation, invocation_operation.id)
      _connection = lock_connection(operation.connection_id)
      operation = lock_operation(invocation_operation.id)

      if operation.status == "prepared" and not provider_owned?(operation) do
        claim_current? =
          operation.lease_token == invocation_operation.lease_token and
            operation.attempt_version == invocation_operation.attempt_version

        updated =
          operation
          |> Operation.provider_ownership_changeset(%{
            handoff_ref: handoff_ref(provider_result.credential_material),
            provider_result_ref: provider_result.provider_result_ref,
            result_permission_digest: provider_result.granted_permissions_digest,
            result_expires_at: provider_result.expires_at
          })
          |> Repo.update!()

        {updated, claim_current?}
      else
        Repo.rollback(:refresh_lease_lost)
      end
    end)
  end

  defp replace_and_journal(operation, backend, now) do
    with :ok <- pre_effect_fence(operation, now),
         {:ok, credential_result} <-
           EffectBoundary.invoke(
             fn ->
               backend.replace(%{
                 credential_material: {:write_only_handoff, operation.handoff_ref},
                 backend_pair_id: operation.backend_pair_id,
                 operation_class: operation.operation_class,
                 correlation_id: operation.correlation_id,
                 bound_input_digest: operation.bound_input_digest,
                 expected_credential_version: operation.expected_credential_version
               })
             end,
             :authorization_backend_unavailable
           ),
         :ok <- validate_credential_result(credential_result),
         {:ok, committed} <- journal_credential_ownership(operation.id, credential_result, now),
         :ok <-
           test_crash_barrier(:credential_ownership_journaled, %{
             operation_id: committed.id,
             credential_ref: committed.result_ref,
             credential_version: committed.result_credential_version
           }) do
      case committed.status do
        "backend_committed" ->
          commit_pointer(committed, durable_metadata(committed), backend, now)

        "cleanup_pending" ->
          cleanup_operation(committed)
      end
    end
  end

  defp journal_credential_ownership(operation_id, credential_result, now) do
    Repo.transaction(fn ->
      operation = Repo.get!(Operation, operation_id)
      connection = lock_connection(operation.connection_id)
      operation = lock_operation(operation_id)

      cond do
        operation.status == "prepared" and provider_owned?(operation) and
            valid_lease?(connection, operation, now) ->
          operation
          |> Operation.credential_ownership_changeset("backend_committed", %{
            result_ref: credential_result.credential_ref,
            result_credential_version: credential_result.credential_version
          })
          |> Repo.update!()

        operation.status == "prepared" and provider_owned?(operation) ->
          operation
          |> Operation.credential_ownership_changeset("cleanup_pending", %{
            result_ref: credential_result.credential_ref,
            result_credential_version: credential_result.credential_version
          })
          |> Ecto.Changeset.change(
            safe_error_code: "cleanup_pending",
            provider_cleanup_status: "pending",
            credential_cleanup_status: "pending"
          )
          |> Repo.update!()

        true ->
          Repo.rollback(:refresh_lease_lost)
      end
    end)
  end

  defp reconcile_then_refresh(connection, operation) do
    case CredentialRefreshExchange.invoke(:reconcile_refresh, connection, operation) do
      {:ok, :not_completed} -> CredentialRefreshExchange.invoke(:refresh, connection, operation)
      result -> result
    end
  end

  defp normalize_recovery_cleanup({:error, :refresh_lease_lost}, operation_id) do
    operation = Repo.get!(Operation, operation_id)

    if operation.next_recovery_at == nil and
         operation.provider_cleanup_status in ["confirmed", "not_required"] and
         operation.credential_cleanup_status in ["confirmed", "not_required"],
       do: :ok,
       else: {:error, :refresh_lease_lost}
  end

  defp normalize_recovery_cleanup(result, _operation_id), do: result

  defp provider_owned?(operation) do
    is_binary(operation.handoff_ref) and is_binary(operation.provider_result_ref) and
      is_binary(operation.result_permission_digest)
  end

  defp handoff_ref({:write_only_handoff, handoff_ref}) when is_binary(handoff_ref),
    do: handoff_ref

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
      {:error, _} -> classify_pointer_failure(operation, backend)
    end
  end

  defp revoke_prior_and_finalize(operation, backend) do
    idempotency_key = operation.correlation_id <> ":old"

    case EffectBoundary.invoke(
           fn ->
             backend.revoke(%{
               credential_ref: operation.prior_credential_ref,
               expected_credential_version: operation.prior_credential_version,
               correlation_id: idempotency_key,
               idempotency_key: idempotency_key
             })
           end,
           :authorization_backend_unavailable
         ) do
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

  defp classify_pointer_failure(operation, backend) do
    Repo.transaction(fn ->
      connection = lock_connection(operation.connection_id)
      locked = lock_operation(operation.id)

      cond do
        locked.status in ["backend_committed", "connection_committed", "finalized"] and
          connection.credential_backend_ref == locked.result_ref and
            connection.credential_version == locked.result_credential_version ->
          {:winner, locked}

        locked.status == "backend_committed" and
          connection.connection_version >= locked.expected_connection_version + 2 and
            (connection.credential_backend_ref != locked.result_ref or
               connection.credential_version != locked.result_credential_version) ->
          cleanup =
            locked
            |> Ecto.Changeset.change(
              status: "cleanup_pending",
              safe_error_code: "cleanup_pending",
              provider_cleanup_status: "pending",
              credential_cleanup_status: "pending"
            )
            |> Repo.update!()

          {:loser, cleanup}

        true ->
          {:retry, locked}
      end
    end)
    |> case do
      {:ok, {:winner, %Operation{status: "finalized"} = winner}} -> result(winner)
      {:ok, {:winner, winner}} -> revoke_prior_and_finalize(winner, backend)
      {:ok, {:loser, loser}} -> cleanup_operation(loser)
      {:ok, {:retry, _operation}} -> {:error, :refresh_in_progress}
      {:error, _reason} -> {:error, :refresh_in_progress}
    end
  end

  defp cleanup_operation(operation) do
    connection = Repo.get!(Connection, operation.connection_id)
    operation = cleanup_provider_independently(operation, connection)
    operation = cleanup_credential_independently(operation, connection)
    finish_cleanup(operation)
  end

  defp cleanup_provider_independently(operation, connection) do
    case RuntimeBindings.resolve_provider_cleanup(connection, operation) do
      {:ok, _pair, driver} ->
        cleanup_provider(operation, driver.implementation, connection)

      {:error, reason} ->
        persist_cleanup(operation.id, :provider, {"pending", normalize_cleanup_error(reason)})
    end
  end

  defp cleanup_credential_independently(operation, connection) do
    case RuntimeBindings.resolve_credential_cleanup(connection, operation) do
      {:ok, _pair, backend} ->
        cleanup_credential(operation, backend)

      {:error, reason} ->
        persist_cleanup(operation.id, :credential, {"pending", normalize_cleanup_error(reason)})
    end
  end

  defp cleanup_provider(
         %Operation{provider_cleanup_status: status} = operation,
         _driver,
         _connection
       )
       when status in ["confirmed", "not_required"],
       do: operation

  defp cleanup_provider(operation, driver, connection) do
    context = %{
      owner_uri: connection.owner_uri,
      workspace_uri: operation.workspace_uri,
      provider_id: connection.provider_id,
      acquisition_method: connection.acquisition_method,
      governed_host: connection.governed_host,
      backend_pair_id: operation.backend_pair_id,
      operation_id: operation.id,
      connection_id: operation.connection_id,
      expected_connection_version: operation.expected_connection_version,
      authorization_ref: operation.expected_authorization_ref,
      expected_authorization_version: operation.expected_authorization_version,
      correlation_id: operation.correlation_id,
      command_digest: operation.bound_input_digest,
      expected_credential_version: operation.expected_credential_version,
      provider_result_ref: operation.provider_result_ref,
      discard_idempotency_key: operation.correlation_id <> ":provider-discard"
    }

    status =
      case EffectBoundary.invoke(
             fn -> driver.discard_refresh_result(context) end,
             :backend_unavailable
           ) do
        :ok -> {"confirmed", nil}
        {:error, reason} -> {"pending", normalize_cleanup_error(reason)}
      end

    persist_cleanup(operation.id, :provider, status)
  end

  defp cleanup_credential(%Operation{credential_cleanup_status: status} = operation, _backend)
       when status in ["confirmed", "not_required"],
       do: operation

  defp cleanup_credential(operation, backend) do
    key = operation.correlation_id <> ":credential-revoke"

    status =
      case EffectBoundary.invoke(
             fn ->
               backend.revoke(%{
                 credential_ref: operation.result_ref,
                 expected_credential_version: operation.result_credential_version,
                 correlation_id: key,
                 idempotency_key: key
               })
             end,
             :backend_unavailable
           ) do
        :ok -> {"confirmed", nil}
        {:ok, _receipt} -> {"confirmed", nil}
        {:error, reason} -> {"pending", normalize_cleanup_error(reason)}
      end

    persist_cleanup(operation.id, :credential, status)
  end

  defp persist_cleanup(operation_id, kind, {status, error}) do
    Repo.transaction(fn ->
      operation = Repo.get!(Operation, operation_id)
      _connection = lock_connection(operation.connection_id)
      operation = lock_operation(operation_id)

      current =
        case kind do
          :provider -> operation.provider_cleanup_status
          :credential -> operation.credential_cleanup_status
        end

      if current in ["confirmed", "not_required"] do
        operation
      else
        attrs =
          case kind do
            :provider ->
              %{provider_cleanup_status: status, provider_cleanup_error_code: error}

            :credential ->
              %{credential_cleanup_status: status, credential_cleanup_error_code: error}
          end

        operation |> Ecto.Changeset.change(attrs) |> Repo.update!()
      end
    end)
    |> case do
      {:ok, operation} -> operation
      {:error, _reason} -> Repo.get!(Operation, operation_id)
    end
  end

  defp finish_cleanup(operation) do
    complete? = fn status -> status in ["confirmed", "not_required"] end

    Repo.transaction(fn ->
      _connection = lock_connection(operation.connection_id)
      locked = lock_operation(operation.id)

      if complete?.(locked.provider_cleanup_status) and
           complete?.(locked.credential_cleanup_status) do
        locked
        |> Ecto.Changeset.change(status: "finalized", safe_error_code: nil, next_recovery_at: nil)
        |> Repo.update!()
      else
        locked
      end
    end)

    {:error, :refresh_lease_lost}
  end

  defp normalize_cleanup_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_cleanup_error(_reason), do: "backend_unavailable"

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

  defp normalize_exchange_error(operation, :correlation_conflict, now) do
    case pre_effect_fence(operation, now) do
      :ok -> {:error, :correlation_conflict}
      {:error, :refresh_lease_lost} -> {:error, :refresh_lease_lost}
    end
  end

  defp normalize_exchange_error(_operation, reason, _now), do: {:error, reason}

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

  if @test_build do
    defp test_crash_barrier(stage, context) do
      case Application.get_env(:ezagent_domain_provider_connection, :refresh_crash_barrier) do
        barrier when is_function(barrier, 2) -> barrier.(stage, context)
        _closed -> :ok
      end
    end
  else
    defp test_crash_barrier(_stage, _context), do: :ok
  end
end
