defmodule Ezagent.ProviderConnection.CredentialReplacement do
  @moduledoc "Fenced pointer CAS and durable handoff finalization."
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    CallbackTerminalProof,
    Connection,
    Driver,
    LocalAuthorizationBackend,
    Operation,
    ProviderAuthorizationCommand,
    RowLock,
    RuntimeBindings
  }

  alias EzagentCore.Repo

  @finalization_lease_seconds 30

  @doc "CAS the credential pointer for a backend-committed operation."
  def commit(operation_id) when is_binary(operation_id) do
    commit(operation_id, DateTime.utc_now())
  end

  @doc false
  def commit(operation_id, %DateTime{} = now) when is_binary(operation_id) do
    case Repo.get(Operation, operation_id) do
      %Operation{status: "finalized", safe_error_code: "account_conflict"} ->
        {:error, :account_conflict}

      %Operation{status: "finalized"} = operation ->
        {:ok, operation}

      %Operation{status: "connection_committed"} ->
        finalize_claimed(operation_id, now)

      %Operation{status: "backend_committed"} = operation ->
        cas(operation, now)

      %Operation{} ->
        {:error, :stale_version}

      nil ->
        {:error, :stale_version}
    end
  end

  @doc false
  def cleanup(operation_id) when is_binary(operation_id) do
    now = DateTime.utc_now()

    case claim_cleanup_obligation(operation_id, now) do
      {:ok, :finalized} ->
        :ok

      {:ok, snapshot} ->
        provider_result = cleanup_provider_result(snapshot)
        credential_result = cleanup_credential_result(snapshot)

        result =
          with :ok <- provider_result,
               :ok <- credential_result,
               :ok <- cleanup_obligations_complete(snapshot.operation_id),
               :ok <-
                 LocalAuthorizationBackend.prepare_handoff_finalization(
                   snapshot.authorization_ref
                 ),
               :ok <- LocalAuthorizationBackend.finalize_handoff(snapshot.authorization_ref),
               :ok <- mark_cleanup_finalized(snapshot) do
            :ok
          end

        if result != :ok, do: release_cleanup_claim(snapshot)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def fence(operation_id) when is_binary(operation_id) do
    lock_fence_candidate(operation_id)
  end

  defp lock_fence_candidate(operation_id) do
    case Repo.get(Operation, operation_id) do
      %Operation{} = snapshot ->
        Repo.transaction(fn ->
          connection = lock_connection(snapshot.connection_id)
          attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
          operation = lock_operation(snapshot.id)

          {command, record} =
            case {operation, attempt} do
              {%Operation{} = operation, %AuthorizationAttempt{} = attempt} ->
                {
                  lock_consume_command(operation.backend_pair_id, attempt.correlation_id),
                  RowLock.authorization_backend_record(attempt.authorization_ref)
                }

              _other ->
                {nil, nil}
            end

          with %Connection{} <- connection,
               %AuthorizationAttempt{} <- attempt,
               %Operation{status: "prepared"} <- operation,
               true <- operation.attempt_ref == attempt.attempt_ref,
               true <- attempt.status == "cancelled",
               true <- is_nil(attempt.claim_token) and is_nil(attempt.claim_until),
               true <- Operation.provider_result_unowned?(operation),
               true <- connection.status in ["revoking", "disconnecting"],
               true <-
                 connection.connection_version == operation.expected_connection_version + 1,
               true <-
                 connection.authorization_version == operation.expected_authorization_version,
               true <- connection.credential_version == operation.expected_credential_version,
               :confirmed_absence <-
                 CallbackTerminalProof.classify(connection, operation, attempt, command, record) do
            attempt
            |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
            |> Repo.update!()

            operation
            |> Ecto.Changeset.change(status: "fenced", safe_error_code: "connection_terminal")
            |> Repo.update!()

            :ok
          else
            {:error, :credential_conflict} -> Repo.rollback(:credential_conflict)
            _other -> Repo.rollback(:credential_conflict)
          end
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :stale_version}
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

            {:ok, %{credential_material: {:write_only_handoff, handoff_ref}} = result} ->
              with {:ok, operation} <- journal_reconciled_provider(operation, attempt, result) do
                reconcile_handoff(operation, attempt, handoff_ref)
              end

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

  defp cas(operation, now) do
    do_cas(operation)
    |> case do
      {:ok, _connection} ->
        finalize_claimed(operation.id, now)

      {:loser, _operation} ->
        with :ok <- cleanup(operation.id) do
          {:error, :account_conflict}
        else
          {:error, _cleanup_reason} -> {:error, :account_conflict}
        end

      {:error, reason} ->
        case cleanup(operation.id) do
          :ok -> {:error, :connection_terminal}
          {:error, _cleanup_reason} -> {:error, reason}
        end
    end
  end

  defp do_cas(operation) do
    Repo.transaction(fn ->
      connection = lock_connection(operation.connection_id)
      attempt = RowLock.authorization_attempt(operation.attempt_ref)
      current = lock_operation(operation.id)

      with %Connection{} <- connection,
           %AuthorizationAttempt{} <- attempt,
           %Operation{status: "backend_committed"} <- current,
           true <- current.expected_connection_version == connection.connection_version,
           true <- current.expected_credential_version == connection.credential_version,
           true <- current.attempt_version == attempt.attempt_version,
           true <- current.attempt_claim_token == attempt.claim_token,
           {:ok, pair, _driver, _backend} <- RuntimeBindings.resolve(connection, current),
           :ok <- lock_binding_key(connection, current) do
        case identity_compatible(connection, attempt, current) do
          :ok ->
            if conflicting_binding?(connection, current) do
              terminalize_loser(connection, attempt, current)
            else
              with {:ok, updated} <- update_connection_binding(connection, attempt, current, pair) do
                current
                |> Ecto.Changeset.change(status: "connection_committed")
                |> Repo.update!()

                {:winner, updated}
              end
            end

          {:error, :account_conflict} ->
            terminalize_loser(connection, attempt, current)
        end
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          if unique_binding_conflict?(changeset),
            do: Repo.rollback(:account_conflict),
            else: Repo.rollback(:stale_version)

        _other ->
          Repo.rollback(:stale_version)
      end
    end)
    |> case do
      {:ok, {:winner, connection}} -> {:ok, connection}
      {:ok, {:loser, operation}} -> {:loser, operation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity_compatible(
         %Connection{status: "pending_authorization"},
         %{purpose: "initial_bind"},
         _operation
       ),
       do: :ok

  defp identity_compatible(connection, %{purpose: "reauthorize"}, operation) do
    if connection.external_account_id == operation.result_external_account_id and
         connection.execution_identity == operation.result_execution_identity,
       do: :ok,
       else: {:error, :account_conflict}
  end

  defp identity_compatible(_connection, _attempt, _operation), do: {:error, :account_conflict}

  defp update_connection_binding(connection, attempt, operation, pair) do
    attrs = %{
      external_account_id: operation.result_external_account_id,
      display_login: operation.result_display_login,
      execution_identity: operation.result_execution_identity,
      authorization_backend_ref: operation.result_authorization_ref,
      authorization_version: operation.result_authorization_version,
      credential_backend_ref: operation.result_ref,
      credential_version: operation.result_credential_version,
      backend_pair_id: operation.backend_pair_id,
      authorization_backend_id: pair.authorization_backend.id,
      credential_backend_id: pair.credential_backend.id,
      permission_digest: operation.result_permission_digest,
      expires_at: operation.result_expires_at,
      connection_version: connection.connection_version + 1,
      status: "active",
      last_error_code: nil
    }

    changeset =
      if attempt.purpose == "initial_bind" do
        Connection.bind_changeset(connection, attrs)
      else
        Connection.transition_changeset(
          connection,
          Map.drop(attrs, [:external_account_id, :execution_identity])
        )
      end

    Repo.update(changeset)
  end

  defp unique_binding_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:external_account_id, {_message, options}} ->
        options[:constraint_name] == "provider_connections_active_binding_index"

      _other ->
        false
    end)
  end

  defp lock_binding_key(connection, operation) do
    key =
      Enum.join(
        [
          connection.workspace_uri,
          connection.owner_uri,
          connection.provider_id,
          connection.governed_host,
          operation.result_external_account_id,
          operation.result_execution_identity
        ],
        "\u001f"
      )

    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp conflicting_binding?(connection, operation) do
    Repo.exists?(
      from(candidate in Connection,
        where:
          candidate.connection_id != ^connection.connection_id and
            candidate.workspace_uri == ^connection.workspace_uri and
            candidate.owner_uri == ^connection.owner_uri and
            candidate.provider_id == ^connection.provider_id and
            candidate.governed_host == ^connection.governed_host and
            candidate.external_account_id == ^operation.result_external_account_id and
            candidate.execution_identity == ^operation.result_execution_identity and
            candidate.status not in ["failed", "revoked", "disconnected"]
      )
    )
  end

  defp terminalize_loser(connection, attempt, operation) do
    if connection.status == "pending_authorization" do
      connection
      |> Connection.bind_changeset(%{
        status: "failed",
        last_error_code: "account_conflict",
        connection_version: connection.connection_version + 1
      })
      |> Repo.update!()
    end

    attempt
    |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
    |> Repo.update!()

    loser =
      operation
      |> Ecto.Changeset.change(
        status: "cleanup_pending",
        safe_error_code: "account_conflict",
        provider_cleanup_status: "pending",
        credential_cleanup_status: "pending",
        next_recovery_at: DateTime.utc_now()
      )
      |> Repo.update!()

    {:loser, loser}
  end

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

  defp journal_reconciled_provider(operation, attempt, result) do
    attrs = %{
      handoff_ref: elem(result.credential_material, 1),
      provider_result_ref: result.provider_result_ref,
      result_external_account_id: result.external_account_id,
      result_display_login: result.display_login,
      result_execution_identity: Atom.to_string(result.execution_identity.kind),
      result_authorization_ref: result.authorization_ref,
      result_authorization_version: result.authorization_version,
      result_permission_digest: result.granted_permissions_digest,
      result_expires_at: result.expires_at
    }

    Repo.transaction(fn ->
      connection = lock_connection(operation.connection_id)
      locked_attempt = RowLock.authorization_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      if connection.status in ["revoking", "disconnecting"] and
           connection.connection_version == locked_operation.expected_connection_version + 1 and
           locked_operation.status == "prepared" and
           locked_operation.attempt_ref == locked_attempt.attempt_ref do
        locked_operation
        |> Operation.provider_ownership_changeset(attrs)
        |> Repo.update!()
      else
        Repo.rollback(:stale_version)
      end
    end)
  end

  defp ensure_reconciled_handoff(operation, handoff_ref) do
    case Repo.get(Operation, operation.id) do
      %Operation{handoff_ref: ^handoff_ref} = current ->
        {:ok, current}

      %Operation{handoff_ref: nil} ->
        {:error, :stale_version}

      _other ->
        {:error, :stale_version}
    end
  end

  defp journal_reconciled_result(operation_id, result) do
    snapshot = Repo.get!(Operation, operation_id)

    Repo.transaction(fn ->
      connection = lock_connection(snapshot.connection_id)
      _attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
      operation = lock_operation(operation_id)

      if operation.status == "prepared" and
           connection.status in ["revoking", "disconnecting"] and
           connection.connection_version == operation.expected_connection_version + 1 and
           connection.credential_version == operation.expected_credential_version do
        operation
        |> Operation.credential_ownership_changeset("cleanup_pending", %{
          result_ref: result.credential_ref,
          result_credential_version: result.credential_version
        })
        |> Ecto.Changeset.change(
          safe_error_code: "cleanup_pending",
          provider_cleanup_status: "pending",
          credential_cleanup_status: "pending"
        )
        |> Repo.update!()
      else
        Repo.rollback(:stale_version)
      end
    end)
  end

  defp claim_cleanup_obligation(operation_id, now) do
    case Repo.get(Operation, operation_id) do
      %Operation{} = snapshot ->
        Repo.transaction(fn ->
          connection = lock_connection(snapshot.connection_id)
          attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
          operation = lock_operation(operation_id)

          operation = transition_terminal_cleanup(operation, connection)

          cond do
            operation.status == "finalized" ->
              :finalized

            operation.status != "cleanup_pending" ->
              Repo.rollback(:credential_conflict)

            not cleanup_claim_available?(operation, now) ->
              Repo.rollback(:callback_in_progress)

            true ->
              with %AuthorizationAttempt{} <- attempt,
                   {:ok, _pair, driver, backend} <-
                     RuntimeBindings.resolve(connection, operation) do
                token = Ecto.UUID.generate()

                operation
                |> Ecto.Changeset.change(
                  lease_token: token,
                  lease_until: DateTime.add(now, @finalization_lease_seconds, :second)
                )
                |> Repo.update!()

                cleanup_snapshot(operation, attempt, connection, driver, backend, token)
              else
                _other -> Repo.rollback(:credential_conflict)
              end
          end
        end)
        |> case do
          {:ok, :finalized} -> {:ok, :finalized}
          {:ok, cleanup_snapshot} -> {:ok, cleanup_snapshot}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :credential_conflict}
    end
  end

  defp transition_terminal_cleanup(
         %Operation{status: "cleanup_pending"} = operation,
         _connection
       ),
       do: operation

  defp transition_terminal_cleanup(%Operation{status: "finalized"} = operation, _connection),
    do: operation

  defp transition_terminal_cleanup(
         %Operation{status: "backend_committed"} = operation,
         connection
       )
       when connection.status in ["revoking", "disconnecting", "failed"] do
    operation
    |> Ecto.Changeset.change(
      status: "cleanup_pending",
      safe_error_code: operation.safe_error_code || "cleanup_pending",
      provider_cleanup_status: "pending",
      credential_cleanup_status: "pending",
      next_recovery_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp transition_terminal_cleanup(_operation, _connection),
    do: Repo.rollback(:credential_conflict)

  defp cleanup_claim_available?(%Operation{lease_token: nil}, _now), do: true

  defp cleanup_claim_available?(%Operation{lease_until: %DateTime{} = until}, now),
    do: DateTime.compare(until, now) in [:lt, :eq]

  defp cleanup_claim_available?(_operation, _now), do: false

  defp cleanup_snapshot(operation, attempt, connection, driver, backend, token) do
    %{
      operation_id: operation.id,
      connection_id: connection.connection_id,
      attempt_ref: attempt.attempt_ref,
      authorization_ref: attempt.authorization_ref,
      claim_token: token,
      provider_status: operation.provider_cleanup_status,
      credential_status: operation.credential_cleanup_status,
      driver: driver.implementation,
      backend: backend,
      provider_context: %{
        owner_uri: connection.owner_uri,
        workspace_uri: connection.workspace_uri,
        provider_id: connection.provider_id,
        acquisition_method: connection.acquisition_method,
        governed_host: connection.governed_host,
        backend_pair_id: operation.backend_pair_id,
        operation_id: operation.id,
        connection_id: operation.connection_id,
        expected_connection_version: operation.expected_connection_version,
        attempt_ref: attempt.attempt_ref,
        authorization_ref: operation.expected_authorization_ref,
        expected_authorization_version: operation.expected_authorization_version,
        correlation_id: operation.correlation_id,
        command_digest: operation.bound_input_digest,
        expected_credential_version: operation.expected_credential_version,
        provider_result_ref: operation.provider_result_ref,
        discard_idempotency_key: operation.correlation_id <> ":provider-discard"
      },
      credential_context: %{
        credential_ref: operation.result_ref,
        expected_credential_version: operation.result_credential_version,
        correlation_id: operation.correlation_id <> ":terminal-cleanup",
        idempotency_key: operation.correlation_id <> ":terminal-cleanup"
      }
    }
  end

  defp cleanup_provider_result(snapshot) do
    case snapshot.provider_status do
      status when status in ["confirmed", "not_required"] ->
        :ok

      "pending" ->
        result =
          with :ok <- Driver.validate_discard_context(:callback, snapshot.provider_context) do
            try do
              apply(snapshot.driver, :discard_callback_result, [snapshot.provider_context])
            rescue
              _error -> {:error, :backend_unavailable}
            catch
              _kind, _reason -> {:error, :backend_unavailable}
            end
          end

        persist_cleanup_result(snapshot, :provider, result)
    end
  end

  defp cleanup_credential_result(snapshot) do
    case snapshot.credential_status do
      status when status in ["confirmed", "not_required"] ->
        :ok

      "pending" ->
        persist_cleanup_result(snapshot, :credential, revoke_result(snapshot))
    end
  end

  defp revoke_result(snapshot) do
    case snapshot.backend.revoke(snapshot.credential_context) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      _ -> {:error, :authorization_backend_unavailable}
    end
  end

  defp persist_cleanup_result(snapshot, kind, result) do
    {status_field, error_field} =
      if kind == :provider,
        do: {:provider_cleanup_status, :provider_cleanup_error_code},
        else: {:credential_cleanup_status, :credential_cleanup_error_code}

    normalized =
      case result do
        :ok -> :ok
        {:ok, _receipt} -> :ok
        {:error, reason} when is_atom(reason) -> {:error, cleanup_error(reason)}
        _other -> {:error, "backend_unavailable"}
      end

    Repo.transaction(fn ->
      _connection = lock_connection(snapshot.connection_id)
      _attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
      operation = lock_operation(snapshot.operation_id)

      if operation.lease_token != snapshot.claim_token,
        do: Repo.rollback(:credential_conflict)

      case {Map.fetch!(operation, status_field), normalized} do
        {status, _result} when status in ["confirmed", "not_required"] ->
          :ok

        {"pending", :ok} ->
          operation
          |> Ecto.Changeset.change(%{status_field => "confirmed", error_field => nil})
          |> Repo.update!()

          :ok

        {"pending", {:error, code}} ->
          operation
          |> Ecto.Changeset.change(%{error_field => code})
          |> Repo.update!()

          {:failed, code}

        _other ->
          Repo.rollback(:credential_conflict)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:failed, _code}} -> {:error, :authorization_backend_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_error(reason)
       when reason in [:backend_unavailable, :authorization_backend_unavailable],
       do: "backend_unavailable"

  defp cleanup_error(:correlation_conflict), do: "correlation_conflict"
  defp cleanup_error(:provider_denied), do: "provider_denied"
  defp cleanup_error(:provider_protocol_failed), do: "provider_protocol_failed"
  defp cleanup_error(:credential_conflict), do: "credential_conflict"
  defp cleanup_error(_reason), do: "backend_unavailable"

  defp cleanup_obligations_complete(operation_id) do
    operation = Repo.get!(Operation, operation_id)

    if operation.provider_cleanup_status in ["confirmed", "not_required"] and
         operation.credential_cleanup_status in ["confirmed", "not_required"],
       do: :ok,
       else: {:error, :authorization_backend_unavailable}
  end

  defp mark_cleanup_finalized(snapshot) do
    Repo.transaction(fn ->
      _connection = lock_connection(snapshot.connection_id)
      attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
      operation = lock_operation(snapshot.operation_id)

      with %Operation{status: "cleanup_pending"} <- operation,
           %AuthorizationAttempt{} <- attempt,
           true <- operation.lease_token == snapshot.claim_token,
           true <- operation.provider_cleanup_status in ["confirmed", "not_required"],
           true <- operation.credential_cleanup_status in ["confirmed", "not_required"] do
        attempt
        |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
        |> Repo.update!()

        operation
        |> Ecto.Changeset.change(
          status: "finalized",
          safe_error_code:
            if(operation.safe_error_code == "account_conflict",
              do: "account_conflict",
              else: "connection_terminal"
            ),
          next_recovery_at: nil,
          lease_token: nil,
          lease_until: nil
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

  defp release_cleanup_claim(snapshot) do
    Repo.transaction(fn ->
      _connection = lock_connection(snapshot.connection_id)
      _attempt = RowLock.authorization_attempt(snapshot.attempt_ref)
      operation = lock_operation(snapshot.operation_id)

      if operation.status == "cleanup_pending" and operation.lease_token == snapshot.claim_token do
        operation
        |> Ecto.Changeset.change(lease_token: nil, lease_until: nil)
        |> Repo.update!()

        :ok
      else
        Repo.rollback(:stale_version)
      end
    end)
  end

  defp finalize_claimed(operation_id, now) do
    case claim_finalization(operation_id, now) do
      {:ok, {:finalized, operation}} ->
        {:ok, operation}

      {:ok, {:claimed, operation, attempt, connection, token}} ->
        result =
          with {:ok, _pair, _driver, backend} <-
                 RuntimeBindings.resolve(connection, operation),
               :ok <- revoke_prior(operation, attempt, backend),
               :ok <-
                 LocalAuthorizationBackend.prepare_handoff_finalization(attempt.authorization_ref),
               :ok <- LocalAuthorizationBackend.finalize_handoff(attempt.authorization_ref),
               {:ok, finalized} <-
                 complete_finalization(operation.id, attempt.attempt_ref, token, now) do
            {:ok, finalized}
          else
            {:error, _reason} = error -> error
            _ -> {:error, :credential_conflict}
          end

        case result do
          {:ok, _finalized} = ok ->
            ok

          {:error, _reason} = error ->
            _ = release_finalization_claim(operation.id, attempt.attempt_ref, token)
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_finalization(operation_id, now) do
    operation = Repo.get(Operation, operation_id)

    if match?(%Operation{}, operation) do
      Repo.transaction(fn ->
        connection = lock_connection(operation.connection_id)
        attempt = RowLock.authorization_attempt(operation.attempt_ref)
        current = lock_operation(operation.id)

        cond do
          is_nil(connection) or is_nil(attempt) or is_nil(current) ->
            Repo.rollback(:stale_version)

          current.status == "finalized" ->
            {:finalized, current}

          current.status == "connection_committed" and claim_available?(current, now) ->
            token = Ecto.UUID.generate()

            claimed =
              current
              |> Ecto.Changeset.change(
                lease_token: token,
                lease_until: DateTime.add(now, @finalization_lease_seconds, :second)
              )
              |> Repo.update!()

            {:claimed, claimed, attempt, connection, token}

          current.status == "connection_committed" ->
            Repo.rollback(:callback_in_progress)

          true ->
            Repo.rollback(:stale_version)
        end
      end)
    else
      {:error, :stale_version}
    end
  end

  defp claim_available?(%Operation{lease_token: nil}, _now), do: true

  defp claim_available?(%Operation{lease_until: %DateTime{} = lease_until}, now),
    do: DateTime.compare(lease_until, now) in [:lt, :eq]

  defp claim_available?(_operation, _now), do: false

  defp revoke_prior(
         %Operation{prior_credential_ref: nil, prior_credential_version: nil},
         %AuthorizationAttempt{purpose: "initial_bind"},
         _backend
       ),
       do: :ok

  defp revoke_prior(
         %Operation{
           prior_credential_ref: prior_ref,
           prior_credential_version: prior_version
         } = operation,
         %AuthorizationAttempt{purpose: "reauthorize"},
         backend
       )
       when is_binary(prior_ref) and is_integer(prior_version) do
    idempotency_key = operation.correlation_id <> ":old"

    case backend.revoke(%{
           credential_ref: prior_ref,
           expected_credential_version: prior_version,
           correlation_id: idempotency_key,
           idempotency_key: idempotency_key
         }) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      {:error, _reason} -> {:error, :authorization_backend_unavailable}
    end
  end

  defp revoke_prior(%Operation{}, %AuthorizationAttempt{}, _backend),
    do: {:error, :credential_conflict}

  defp complete_finalization(operation_id, attempt_ref, token, now) do
    Repo.transaction(fn ->
      operation_snapshot = Repo.get!(Operation, operation_id)
      _connection = lock_connection(operation_snapshot.connection_id)
      attempt = RowLock.authorization_attempt(attempt_ref)
      operation = lock_operation(operation_id)

      case operation do
        %Operation{status: "connection_committed", lease_token: ^token} ->
          attempt
          |> Ecto.Changeset.change(
            status: "consumed",
            claim_token: nil,
            claim_until: nil,
            consumed_at: attempt.consumed_at || now
          )
          |> Repo.update!()

          operation
          |> Ecto.Changeset.change(
            status: "finalized",
            lease_token: nil,
            lease_until: nil,
            next_recovery_at: nil
          )
          |> Repo.update!()

        _ ->
          Repo.rollback(:stale_version)
      end
    end)
  end

  defp release_finalization_claim(operation_id, attempt_ref, token) do
    operation_snapshot = Repo.get(Operation, operation_id)

    if match?(%Operation{}, operation_snapshot) do
      Repo.transaction(fn ->
        _connection = lock_connection(operation_snapshot.connection_id)
        _attempt = RowLock.authorization_attempt(attempt_ref)
        operation = lock_operation(operation_id)

        if match?(%Operation{status: "connection_committed", lease_token: ^token}, operation) do
          operation
          |> Ecto.Changeset.change(lease_token: nil, lease_until: nil)
          |> Repo.update!()

          :ok
        else
          Repo.rollback(:stale_version)
        end
      end)
    else
      {:error, :stale_version}
    end
  end

  defp lock_operation(id),
    do: Operation |> where([row], row.id == ^id) |> lock("FOR UPDATE") |> Repo.one()

  defp lock_connection(id),
    do:
      Ezagent.ProviderConnection.Connection
      |> where([row], row.connection_id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_consume_command(backend_pair_id, correlation_id),
    do:
      ProviderAuthorizationCommand
      |> where(
        [row],
        row.backend_pair_id == ^backend_pair_id and row.operation_class == "consume" and
          row.correlation_id == ^correlation_id
      )
      |> lock("FOR UPDATE")
      |> Repo.one()
end
