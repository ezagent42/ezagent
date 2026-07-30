defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.Reconciliation do
  @moduledoc false
  import Ecto.Query
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support
  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.SealedEnvelope
  alias Ezagent.ProviderConnection.Connection
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.Operation
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias Ezagent.ProviderConnection.EffectBoundary
  alias EzagentCore.Repo

  @doc false
  def reconcile(operation_id, attempt_ref)
      when is_binary(operation_id) and is_binary(attempt_ref) do
    with {:ok, recovery} <- recovery_context(operation_id, attempt_ref) do
      case recovery do
        %{replay: result} ->
          result

        recovery ->
          case invoke_recovery_driver(recovery) do
            {:ok, :not_completed} -> terminalize_absence(recovery)
            {:ok, driver_result} -> commit_callback(recovery, driver_result)
            {:error, _reason} -> {:error, :authorization_backend_unavailable}
          end
      end
    end
  end

  def reconcile(_operation_id, _attempt_ref), do: {:error, :authorization_backend_unavailable}

  defp recovery_driver(row) do
    with {:ok, driver} <-
           normalize_recovery_lookup(
             DriverRegistry.lookup(row.provider_id, row.acquisition_method)
           ),
         true <- row.backend_pair_id in driver.backend_pair_ids,
         :ok <- Support.local_pair?(row.backend_pair_id) do
      {:ok, driver}
    else
      _other -> {:error, :authorization_backend_unavailable}
    end
  end

  defp normalize_recovery_lookup({:ok, value}), do: {:ok, value}
  defp normalize_recovery_lookup(:error), do: {:error, :authorization_backend_unavailable}

  defp recovery_context(operation_id, attempt_ref) do
    operation = Repo.get(Operation, operation_id)
    attempt = Repo.get(AuthorizationAttempt, attempt_ref)

    with %Operation{status: "prepared"} <- operation,
         %AuthorizationAttempt{} <- attempt,
         true <- operation.attempt_ref == attempt.attempt_ref,
         %Connection{} = connection <- Repo.get(Connection, operation.connection_id),
         true <- connection.status in ["revoking", "disconnecting"],
         true <- connection.connection_version == operation.expected_connection_version + 1,
         base_connection <-
           %{connection | connection_version: operation.expected_connection_version},
         %AuthorizationBackendRecord{} = row <-
           Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref),
         %ProviderAuthorizationCommand{} = command <-
           recovery_command(operation.backend_pair_id, attempt.correlation_id),
         :ok <- validate_recovery_scope(operation, attempt, row, command, base_connection) do
      build_recovery_context(
        operation,
        attempt,
        row,
        command,
        base_connection
      )
    else
      _reason -> {:error, :authorization_backend_unavailable}
    end
  end

  defp validate_recovery_scope(operation, attempt, row, command, connection) do
    if operation.backend_pair_id == attempt.backend_pair_id and
         operation.backend_pair_id == row.backend_pair_id and
         operation.backend_pair_id == command.backend_pair_id and
         operation.operation_class == callback_operation_class(attempt.purpose) and
         operation.correlation_id == "#{operation.operation_class}:#{attempt.correlation_id}" and
         operation.bound_input_digest == Operation.callback_digest(row, attempt, connection) and
         operation.attempt_claim_token == attempt.claim_token and
         operation.attempt_version == attempt.attempt_version and
         operation.expected_connection_version == attempt.connection_version and
         operation.expected_authorization_ref == attempt.authorization_ref and
         operation.expected_authorization_version == connection.authorization_version and
         operation.expected_credential_version == connection.credential_version and
         command.operation_class == "consume" and
         command.correlation_id == attempt.correlation_id and
         command.bound_input_digest == row.consume_input_digest and
         command.authorization_ref == attempt.authorization_ref and
         command.status in ["prepared", "committed", "terminal_failed"] and
         row.consume_correlation_id == attempt.correlation_id do
      :ok
    else
      {:error, :correlation_conflict}
    end
  end

  defp build_recovery_context(operation, attempt, row, command, base_connection) do
    common = %{
      operation: operation,
      attempt: attempt,
      row: row,
      command: command,
      base_connection: base_connection
    }

    case command do
      %ProviderAuthorizationCommand{status: "committed", safe_result: safe_result}
      when is_map(safe_result) ->
        result = Support.decode_consume_result(safe_result)
        {:write_only_handoff, handoff_ref} = result.credential_material

        if row.handoff_ref == handoff_ref and is_binary(row.handoff_ciphertext) do
          {:ok, Map.put(common, :replay, {:ok, result})}
        else
          {:error, :correlation_conflict}
        end

      %ProviderAuthorizationCommand{
        status: "terminal_failed",
        safe_error_code: "not_completed"
      } ->
        {:ok, Map.put(common, :replay, {:ok, :not_completed})}

      %ProviderAuthorizationCommand{status: "prepared"} ->
        with true <- is_binary(row.callback_ciphertext),
             {:ok, snapshot} <- recovery_crypto_state(),
             {:ok, payload} <-
               unseal_recovered_attempt(
                 snapshot,
                 Support.envelope(row),
                 Support.row_aad(row)
               ),
             {:ok, callback_envelope} <-
               unseal_recovered_callback(
                 snapshot,
                 Support.callback_envelope(row),
                 Support.callback_aad(row, command.correlation_id, command.bound_input_digest)
               ),
             :ok <- validate_recovered_callback(payload, callback_envelope, row),
             {:ok, driver} <- recovery_driver(row) do
          {:ok,
           Map.merge(common, %{
             payload: payload,
             callback_envelope: callback_envelope,
             driver: driver,
             snapshot: snapshot
           })}
        else
          _reason -> {:error, :authorization_backend_unavailable}
        end

      _other ->
        {:error, :correlation_conflict}
    end
  end

  defp invoke_recovery_driver(recovery) do
    context = recovery_driver_context(recovery)

    reply =
      EffectBoundary.invoke(
        fn -> apply(recovery.driver.implementation, :reconcile_callback, [context]) end,
        :provider_protocol_error
      )

    case reply do
      {:ok, :not_completed} -> {:ok, :not_completed}
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, _reason} -> {:error, :provider_outcome_ambiguous}
      _reply -> {:error, :provider_outcome_ambiguous}
    end
  end

  defp recovery_driver_context(recovery) do
    private_frame = %{
      state: recovery.payload.state,
      pkce_verifier: recovery.payload.pkce_verifier,
      callback_envelope: recovery.callback_envelope,
      provider_id: recovery.row.provider_id,
      acquisition_method: recovery.row.acquisition_method,
      governed_host: recovery.row.governed_host
    }

    exchange = fn
      provider_exchange when is_function(provider_exchange, 1) ->
        provider_exchange.(private_frame)

      _other ->
        {:error, :provider_protocol_error}
    end

    %{
      owner_uri: recovery.row.owner_uri,
      workspace_uri: recovery.row.workspace_uri,
      provider_id: recovery.row.provider_id,
      acquisition_method: recovery.row.acquisition_method,
      governed_host: recovery.row.governed_host,
      authorization_ref: recovery.operation.expected_authorization_ref,
      backend_pair_id: recovery.command.backend_pair_id,
      operation_id: recovery.operation.id,
      connection_id: recovery.operation.connection_id,
      correlation_id: recovery.operation.correlation_id,
      attempt_ref: recovery.attempt.attempt_ref,
      expected_connection_version: recovery.operation.expected_connection_version,
      expected_authorization_version: recovery.operation.expected_authorization_version,
      expected_credential_version: recovery.operation.expected_credential_version,
      command_digest: recovery.operation.bound_input_digest,
      callback_envelope_digest: Support.secret_digest(recovery.callback_envelope),
      exchange: exchange
    }
  end

  defp terminalize_absence(%{command: %{status: "terminal_failed"}}),
    do: {:ok, :not_completed}

  defp terminalize_absence(recovery) do
    Repo.transaction(fn ->
      connection =
        Connection
        |> where([item], item.connection_id == ^recovery.operation.connection_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      attempt =
        AuthorizationAttempt
        |> where([item], item.attempt_ref == ^recovery.attempt.attempt_ref)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      operation =
        Operation
        |> where([item], item.id == ^recovery.operation.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      command =
        lock_recovery_command(
          recovery.command.backend_pair_id,
          recovery.command.correlation_id
        )

      row = lock_recovery_record(recovery.row.authorization_ref)
      base_connection = %{connection | connection_version: operation.expected_connection_version}

      if connection.status in ["revoking", "disconnecting"] and
           connection.connection_version == operation.expected_connection_version + 1 and
           operation.status == "prepared" and is_nil(operation.handoff_ref) and
           terminal_claim_expired?(attempt, operation) and
           command.status == "prepared" and
           coherent_pending_without_handoff?(row) and
           :ok == validate_recovery_scope(operation, attempt, row, command, base_connection) do
        command
        |> Ecto.Changeset.change(
          status: "terminal_failed",
          safe_result: nil,
          safe_error_code: "not_completed"
        )
        |> Repo.update!()

        row
        |> Ecto.Changeset.change(lifecycle_status: "cancelled")
        |> Repo.update!()

        attempt
        |> Ecto.Changeset.change(status: "cancelled", claim_token: nil, claim_until: nil)
        |> Repo.update!()

        operation
        |> Ecto.Changeset.change(attempt_claim_token: nil)
        |> Repo.update!()

        {:ok, :not_completed}
      else
        Repo.rollback(:correlation_conflict)
      end
    end)
    |> Support.unwrap_transaction()
  end

  defp coherent_pending_without_handoff?(row),
    do:
      row.lifecycle_status == "pending" and is_nil(row.handoff_ref) and
        is_nil(row.handoff_ciphertext) and is_nil(row.shredded_at)

  defp terminal_claim_expired?(attempt, operation) do
    attempt.status == "consuming" and attempt.claim_token == operation.attempt_claim_token and
      attempt.attempt_version == operation.attempt_version and
      is_struct(attempt.claim_until, DateTime) and
      DateTime.compare(attempt.claim_until, DateTime.utc_now()) != :gt
  end

  defp commit_callback(recovery, driver_result) do
    handoff_ref =
      Support.stable_ref(
        "handoff",
        recovery.row.authorization_ref,
        recovery.command.correlation_id
      )

    with {:ok, normalized} <-
           normalize_recovered_result(
             driver_result,
             recovery.callback_envelope,
             recovery.driver,
             recovery.operation
           ),
         handoff <-
           seal_recovered_handoff(
             recovery.snapshot,
             normalized.credential_material,
             Support.handoff_aad(
               recovery.row,
               recovery.command.correlation_id,
               handoff_ref,
               recovery.operation.operation_class
             )
           ) do
      Repo.transaction(fn ->
        connection =
          Connection
          |> where([item], item.connection_id == ^recovery.operation.connection_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        attempt =
          AuthorizationAttempt
          |> where([item], item.attempt_ref == ^recovery.attempt.attempt_ref)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        operation =
          Operation
          |> where([item], item.id == ^recovery.operation.id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        command =
          lock_recovery_command(
            recovery.command.backend_pair_id,
            recovery.command.correlation_id
          )

        row = lock_recovery_record(recovery.row.authorization_ref)

        base_connection = %{
          connection
          | connection_version: operation.expected_connection_version
        }

        if connection.status in ["revoking", "disconnecting"] and
             connection.connection_version == operation.expected_connection_version + 1 and
             command.status == "prepared" and operation.status == "prepared" and
             is_nil(operation.handoff_ref) and
             :ok ==
               validate_recovery_scope(operation, attempt, row, command, base_connection) do
          safe_result =
            Map.put(normalized, :credential_material, {:write_only_handoff, handoff_ref})

          row
          |> Ecto.Changeset.change(
            lifecycle_status: "consumed",
            nonce: nil,
            ciphertext: nil,
            callback_nonce: nil,
            callback_ciphertext: nil,
            handoff_ref: handoff_ref,
            handoff_ciphertext: :erlang.term_to_binary(handoff, [:deterministic])
          )
          |> Repo.update!()

          commit_recovery_command(command, Support.encode_consume_result(safe_result))

          {:ok, safe_result}
        else
          {:error, :correlation_conflict}
        end
      end)
      |> Support.unwrap_transaction()
    else
      _reason -> {:error, :authorization_backend_unavailable}
    end
  end

  defp normalize_recovered_result(result, callback, driver, operation) do
    Support.validate_consume_result(
      result,
      callback,
      driver,
      operation.expected_authorization_ref,
      operation.expected_authorization_version
    )
  end

  defp validate_recovered_callback(payload, callback, row) when is_map(callback) do
    cond do
      Support.field(callback, :state) != payload.state ->
        {:error, :state_mismatch}

      Support.field(callback, :pkce_digest) != Support.pkce_digest(payload.pkce_verifier) ->
        {:error, :pkce_mismatch}

      Support.field(callback, :governed_host) != row.governed_host ->
        {:error, :governed_host_mismatch}

      Support.field(callback, :acquisition_origin) == :social_login ->
        {:error, :callback_invalid}

      true ->
        :ok
    end
  end

  defp validate_recovered_callback(_payload, _callback, _row), do: {:error, :callback_invalid}

  defp commit_recovery_command(command_or_attrs, safe_result) do
    true = command_or_attrs.operation_class == "consume"

    command =
      lock_recovery_command(
        command_or_attrs.backend_pair_id,
        command_or_attrs.correlation_id
      )

    command
    |> Ecto.Changeset.change(status: "committed", safe_result: safe_result, safe_error_code: nil)
    |> Repo.update!()
  end

  defp lock_recovery_record(ref),
    do:
      Repo.one(
        from(row in AuthorizationBackendRecord,
          where: row.authorization_ref == ^ref,
          lock: "FOR UPDATE"
        )
      )

  defp recovery_command(pair, correlation),
    do:
      Repo.one(
        from(command in ProviderAuthorizationCommand,
          where:
            command.backend_pair_id == ^pair and command.operation_class == "consume" and
              command.correlation_id == ^correlation
        )
      )

  defp lock_recovery_command(pair, correlation),
    do:
      Repo.one!(
        from(command in ProviderAuthorizationCommand,
          where:
            command.backend_pair_id == ^pair and command.operation_class == "consume" and
              command.correlation_id == ^correlation,
          lock: "FOR UPDATE"
        )
      )

  # The purpose stays hardcoded: this path only ever re-seals a credential
  # handoff. Passing it in would let a caller choose, which this path must not.
  defp seal_recovered_handoff(snapshot, value, aad),
    do: SealedEnvelope.seal(snapshot, :active, :credential_handoff, value, aad)

  defp unseal_recovered_attempt(snapshot, envelope, aad),
    do: decrypt_recovery_envelope(snapshot, :authorization_attempt, envelope, aad)

  defp unseal_recovered_callback(snapshot, envelope, aad),
    do: decrypt_recovery_envelope(snapshot, :authorization_callback, envelope, aad)

  # This allowlist is the RECOVERY path's own restriction and stays here.
  # `SealedEnvelope` deliberately does not police purposes — it serves callers
  # that legitimately open `:credential_handoff` (see `exchange.ex`). Centralising
  # this would impose it on them; deleting it would let recovery decrypt a
  # credential handoff, which is exactly the boundary it must not cross.
  @recovery_purposes [:authorization_attempt, :authorization_callback]

  defp decrypt_recovery_envelope(snapshot, purpose, envelope, aad) do
    if purpose in @recovery_purposes do
      SealedEnvelope.open(snapshot, purpose, envelope, aad)
    else
      {:error, :authentication_failed}
    end
  end

  defp recovery_crypto_state, do: SealedEnvelope.snapshot()

  defp callback_operation_class("initial_bind"), do: "store"
  defp callback_operation_class("reauthorize"), do: "replace"
  defp callback_operation_class(_purpose), do: nil
end
