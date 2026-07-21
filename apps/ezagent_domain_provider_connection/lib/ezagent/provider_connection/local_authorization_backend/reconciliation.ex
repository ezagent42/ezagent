defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.Reconciliation do
  @moduledoc false
  import Ecto.Query
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support
  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias Ezagent.ProviderConnection.Connection
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.Operation
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias Ezagent.ProviderConnection.EffectBoundary
  alias EzagentCore.Repo
  @tag_bytes 16
  @fixture_enabled Application.compile_env(
                     :ezagent_domain_provider_connection,
                     :authorization_key_ring_fixture_enabled,
                     false
                   )
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/

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
             Support.handoff_aad(recovery.row, recovery.command.correlation_id, handoff_ref)
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

  defp seal_recovered_handoff(snapshot, value, aad) do
    key_id = snapshot.active_key_id
    key = Map.fetch!(snapshot.keys, key_id)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = :erlang.term_to_binary(value, [:deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        Support.encode_aad(:credential_handoff, aad),
        true
      )

    %{
      key_id: key_id,
      key_fingerprint: Support.sha256(key),
      nonce: nonce,
      ciphertext: <<tag::binary, ciphertext::binary>>
    }
  end

  defp unseal_recovered_attempt(snapshot, envelope, aad),
    do: decrypt_recovery_envelope(snapshot, :authorization_attempt, envelope, aad)

  defp unseal_recovered_callback(snapshot, envelope, aad),
    do: decrypt_recovery_envelope(snapshot, :authorization_callback, envelope, aad)

  defp decrypt_recovery_envelope(
         snapshot,
         purpose,
         %{key_id: key_id, key_fingerprint: fingerprint, nonce: nonce, ciphertext: blob},
         aad
       )
       when is_binary(key_id) and is_binary(fingerprint) and is_binary(nonce) and
              byte_size(nonce) == 12 and is_binary(blob) and byte_size(blob) >= @tag_bytes do
    if purpose in [:authorization_attempt, :authorization_callback] do
      with {:ok, key} <- Map.fetch(snapshot.keys, key_id),
           true <- Support.sha256(key) == fingerprint do
        <<tag::binary-size(@tag_bytes), ciphertext::binary>> = blob

        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               nonce,
               ciphertext,
               Support.encode_aad(purpose, aad),
               tag,
               false
             ) do
          :error -> {:error, :authentication_failed}
          plaintext -> {:ok, :erlang.binary_to_term(plaintext, [:safe])}
        end
      else
        _error -> {:error, :authentication_failed}
      end
    else
      {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  defp decrypt_recovery_envelope(_snapshot, _purpose, _envelope, _aad),
    do: {:error, :authentication_failed}

  defp recovery_crypto_state do
    with {:ok, state} <- parse_recovery_crypto_config(),
         {:ok, validated} <- AuthorizationKeyRing.validated_fingerprint(),
         true <- recovery_crypto_fingerprint(state) == validated do
      {:ok, state}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  defp parse_recovery_crypto_config do
    config = Application.get_env(:ezagent_domain_provider_connection, AuthorizationKeyRing, [])

    with {:ok, keys} <- load_recovery_keys(Keyword.get(config, :source), config),
         active when is_binary(active) <- Keyword.get(config, :active_key_id),
         true <- Regex.match?(@key_id_pattern, active),
         true <- Map.has_key?(keys, active) do
      {:ok, %{active_key_id: active, keys: keys}}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  if @fixture_enabled do
    defp load_recovery_keys(:explicit_test, config) do
      case Keyword.get(config, :keys) do
        keys when is_map(keys) -> validate_recovery_keys(Map.to_list(keys))
        _other -> {:error, :invalid}
      end
    end
  end

  defp load_recovery_keys(:runtime_env, config) do
    with json when is_binary(json) <- Keyword.get(config, :keys_json),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(json, objects: :ordered_objects) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {id, encoded}, {:ok, keys} ->
        with true <- valid_recovery_key_id?(id),
             {:ok, key} <- decode_recovery_key(encoded),
             false <- Map.has_key?(keys, id) do
          {:cont, {:ok, Map.put(keys, id, key)}}
        else
          _invalid -> {:halt, {:error, :invalid}}
        end
      end)
    else
      _error -> {:error, :invalid}
    end
  end

  defp load_recovery_keys(_source, _config), do: {:error, :invalid}

  if @fixture_enabled do
    defp validate_recovery_keys(pairs) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {id, key}, {:ok, keys} ->
        case {valid_recovery_key_id?(id), is_binary(key) and byte_size(key) == 32,
              Map.has_key?(keys, id)} do
          {true, true, false} -> {:cont, {:ok, Map.put(keys, id, key)}}
          _invalid -> {:halt, {:error, :invalid}}
        end
      end)
    end
  end

  defp valid_recovery_key_id?(id),
    do: is_binary(id) and Regex.match?(@key_id_pattern, id)

  defp decode_recovery_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _invalid -> {:error, :invalid}
    end
  end

  defp decode_recovery_key(_encoded), do: {:error, :invalid}

  defp recovery_crypto_fingerprint(%{active_key_id: active, keys: keys}) do
    keys
    |> Enum.map(fn {id, key} -> {id, Support.sha256(key)} end)
    |> Map.new()
    |> then(&{active, &1})
    |> :erlang.term_to_binary([:deterministic])
    |> Support.sha256()
  end

  defp callback_operation_class("initial_bind"), do: "store"
  defp callback_operation_class("reauthorize"), do: "replace"
  defp callback_operation_class(_purpose), do: nil
end
