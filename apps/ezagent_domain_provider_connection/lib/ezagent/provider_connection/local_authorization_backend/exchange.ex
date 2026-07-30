defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.Exchange do
  @moduledoc """
  Durable local implementation of the frozen D0 authorization boundary.

  Begin and consume use two transactions. The first commits the prepared
  command and encrypted recovery material. The second locks that durable state
  through the driver effect and commit. A stable correlation id is supplied to
  the driver for its provider-side idempotency across the unavoidable crash
  window after a provider effect and before the second transaction commits.
  """

  import Ecto.Query

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Lifecycle
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.CallbackOperation
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.Connection
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias Ezagent.ProviderConnection.Operation
  alias Ezagent.ProviderConnection.SealedEnvelope
  alias Ezagent.ProviderConnection.EffectBoundary
  alias EzagentCore.Repo

  # Still used by `state_key_id/1` to validate the key id embedded in an opaque
  # state token. The crypto that used to live here moved to `SealedEnvelope`.
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/
  @begin_keys MapSet.new(
                ~w(subject acquisition_method requested_permissions_digest redirect_uri_id correlation_id bound_input_digest)a ++
                  ["bound_input_digest"]
              )
  @consume_keys MapSet.new(
                  ~w(authorization_ref callback_envelope expected_subject correlation_id bound_input_digest)a ++
                    ["bound_input_digest"]
                )

  @doc false
  def begin_authorization(request) when is_map(request) do
    with :ok <- Support.closed_keys(request, @begin_keys),
         {:ok, subject} <- Support.subject(request[:subject]),
         {:ok, correlation_id} <-
           Support.required_binary(request, :correlation_id, :callback_invalid),
         {:ok, method} <- Support.acquisition_method(request),
         {:ok, _permissions_digest} <-
           Support.required_binary(request, :requested_permissions_digest, :callback_invalid),
         {:ok, _redirect_uri_id} <-
           Support.required_binary(request, :redirect_uri_id, :callback_invalid),
         {:ok, pair_id} <- Lifecycle.configured_pair(subject.provider_id, method),
         {:ok, digest} <- Support.command_digest(:begin, request),
         {:ok, authorization_ref} <- prepare_begin(request, subject, pair_id, digest),
         result <- finish_begin(pair_id, correlation_id, digest, authorization_ref) do
      result
    end
  end

  def begin_authorization(_request), do: {:error, :callback_invalid}

  @doc false
  def consume_callback(request) when is_map(request) do
    with :ok <- Support.closed_keys(request, @consume_keys),
         {:ok, authorization_ref} <-
           Support.required_binary(request, :authorization_ref, :callback_invalid),
         {:ok, correlation_id} <-
           Support.required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- Support.command_digest(:consume, request),
         {:ok, pair_id} <- prepare_consume(request, authorization_ref, correlation_id, digest),
         result <- finish_consume(pair_id, correlation_id, digest, request) do
      result
    end
  end

  def consume_callback(_request), do: {:error, :callback_invalid}

  @doc false
  def state_digest(raw_state) when is_binary(raw_state) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, key_id} <- state_key_id(raw_state),
         {:ok, key} <- Map.fetch(snapshot.keys, key_id) do
      {:ok, :crypto.mac(:hmac, :sha256, key, raw_state) |> Base.encode16(case: :lower)}
    else
      _reason -> {:error, :callback_invalid}
    end
  end

  def state_digest(_raw_state), do: {:error, :callback_invalid}

  @doc false
  def stage_callback(pair_id, authorization_ref, correlation_id, raw_state, provider_envelope)
      when is_binary(pair_id) and is_binary(authorization_ref) and is_binary(correlation_id) and
             is_binary(raw_state) and is_map(provider_envelope) do
    Repo.transaction(fn ->
      with %AuthorizationBackendRecord{} = row <- locked_record(authorization_ref),
           true <- row.backend_pair_id == pair_id,
           true <- row.lifecycle_status in ["pending", "consuming"],
           :lt <- DateTime.compare(DateTime.utc_now(), row.expires_at),
           {:ok, snapshot} <- SealedEnvelope.snapshot() do
        callback = Map.put(provider_envelope, :state, raw_state)
        digest = Support.digest(callback)

        cond do
          is_binary(row.callback_ciphertext) and row.consume_correlation_id == correlation_id and
              row.consume_input_digest == digest ->
            :ok

          is_binary(row.callback_ciphertext) ->
            {:error, :correlation_conflict}

          true ->
            sealed =
              SealedEnvelope.seal(
                snapshot,
                :active,
                :authorization_callback,
                callback,
                Support.callback_aad(row, correlation_id, digest)
              )

            row
            |> Ecto.Changeset.change(
              consume_correlation_id: correlation_id,
              consume_input_digest: digest,
              callback_key_id: sealed.key_id,
              callback_key_fingerprint: sealed.key_fingerprint,
              callback_nonce: sealed.nonce,
              callback_ciphertext: sealed.ciphertext
            )
            |> Repo.update!()

            :ok
        end
      else
        _reason -> {:error, :callback_invalid}
      end
    end)
    |> Support.unwrap_transaction()
  end

  @doc false
  def handoff_to_registered_credential(operation_id, attempt_ref)
      when is_binary(operation_id) and is_binary(attempt_ref) do
    with %Operation{status: "prepared"} = operation <- Repo.get(Operation, operation_id),
         %AuthorizationAttempt{} = attempt <- Repo.get(AuthorizationAttempt, attempt_ref),
         %Connection{} = connection <- Repo.get(Connection, attempt.connection_id),
         :ok <- Support.validate_operation_fence(operation, attempt, connection),
         %AuthorizationBackendRecord{} = row <-
           Repo.get_by(AuthorizationBackendRecord,
             authorization_ref: attempt.authorization_ref
           ),
         :ok <- Support.validate_handoff(row, operation, attempt, connection),
         {:ok, credential_backend} <-
           registered_credential_backend(attempt.backend_pair_id),
         {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, envelope} <- Support.decode_handoff_envelope(row.handoff_ciphertext),
         {:ok, credential_material} <-
           SealedEnvelope.open(
             snapshot,
             :credential_handoff,
             envelope,
             Support.handoff_aad(
               row,
               attempt.correlation_id,
               operation.handoff_ref,
               operation.operation_class
             )
           ),
         {:ok, result} <-
           apply_credential_effect(
             credential_backend,
             operation,
             attempt,
             connection,
             credential_material
           ) do
      {:ok, result}
    else
      nil -> {:error, :credential_conflict}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  def handoff_to_registered_credential(_operation_id, _attempt_ref),
    do: {:error, :credential_conflict}

  @doc false
  def handoff_reconciled_to_registered_credential(operation_id, attempt_ref)
      when is_binary(operation_id) and is_binary(attempt_ref) do
    with %Operation{status: "prepared"} = operation <- Repo.get(Operation, operation_id),
         %AuthorizationAttempt{} = attempt <- Repo.get(AuthorizationAttempt, attempt_ref),
         %Connection{} = connection <- Repo.get(Connection, attempt.connection_id),
         true <- connection.status in ["revoking", "disconnecting"],
         true <- connection.connection_version == operation.expected_connection_version + 1,
         base_connection <-
           %{connection | connection_version: operation.expected_connection_version},
         :ok <- Support.validate_operation_fence(operation, attempt, base_connection),
         %AuthorizationBackendRecord{} = row <-
           Repo.get_by(AuthorizationBackendRecord,
             authorization_ref: attempt.authorization_ref
           ),
         :ok <- Support.validate_handoff(row, operation, attempt, base_connection),
         {:ok, credential_backend} <-
           registered_credential_backend(attempt.backend_pair_id),
         {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, envelope} <- Support.decode_handoff_envelope(row.handoff_ciphertext),
         {:ok, credential_material} <-
           SealedEnvelope.open(
             snapshot,
             :credential_handoff,
             envelope,
             Support.handoff_aad(
               row,
               attempt.correlation_id,
               operation.handoff_ref,
               operation.operation_class
             )
           ),
         {:ok, result} <-
           apply_credential_effect(
             credential_backend,
             operation,
             attempt,
             base_connection,
             credential_material
           ) do
      {:ok, result}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  def handoff_reconciled_to_registered_credential(_operation_id, _attempt_ref),
    do: {:error, :credential_conflict}

  defp prepare_begin(request, subject, pair_id, digest) do
    correlation_id = request.correlation_id
    authorization_ref = Support.stable_ref("auth", pair_id, correlation_id)
    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
    aad = Support.begin_aad(authorization_ref, pair_id, digest, subject, request, expires_at)

    with {:ok, snapshot} <- SealedEnvelope.snapshot() do
      payload = %{
        state: "#{snapshot.active_key_id}.#{Support.random_token(32)}",
        pkce_verifier: Support.random_token(48),
        redirect: nil
      }

      envelope = SealedEnvelope.seal(snapshot, :active, :authorization_attempt, payload, aad)

      Repo.transaction(fn ->
        attrs =
          Support.command_attrs(
            URI.to_string(subject.workspace_uri),
            pair_id,
            "begin",
            correlation_id,
            digest,
            authorization_ref
          )

        case insert_command(attrs) do
          :inserted ->
            insert_backend_record!(
              request,
              subject,
              pair_id,
              digest,
              authorization_ref,
              expires_at,
              envelope
            )

            {:ok, authorization_ref}

          :existing ->
            command = command(pair_id, "begin", correlation_id)

            if command.bound_input_digest == digest,
              do: {:ok, command.authorization_ref},
              else: {:error, :correlation_conflict}
        end
      end)
      |> Support.unwrap_transaction()
    end
  end

  defp finish_begin(pair_id, correlation_id, digest, authorization_ref) do
    Repo.transaction(fn ->
      command = locked_command(pair_id, "begin", correlation_id)

      cond do
        command.bound_input_digest != digest ->
          {:error, :correlation_conflict}

        command.authorization_ref != authorization_ref ->
          {:error, :correlation_conflict}

        command.status == "terminal_failed" ->
          {:error, Support.safe_error(command.safe_error_code)}

        true ->
          row = locked_record(authorization_ref)
          finish_begin_command(command, row)
      end
    end)
    |> Support.unwrap_transaction()
  end

  defp finish_begin_command(command, row) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, payload} <-
           SealedEnvelope.open(
             snapshot,
             :authorization_attempt,
             Support.envelope(row),
             Support.row_aad(row)
           ) do
      if command.status == "committed" do
        case payload.redirect do
          redirect when is_map(redirect) -> {:ok, Support.begin_result(row, redirect)}
          _other -> {:error, :provider_protocol_error}
        end
      else
        invoke_prepared_begin(command, row, payload, snapshot)
      end
    else
      _error -> {:error, :state_mismatch}
    end
  end

  defp invoke_prepared_begin(command, row, payload, snapshot) do
    with {:ok, driver} <- frozen_driver(row),
         {:ok, driver_result} <-
           invoke_driver(driver, :begin_authorization, row, command, payload, %{}, %{}),
         {:ok, redirect} <- Support.normalize_begin_result(driver_result, payload, driver),
         {:ok, sealed} <-
           SealedEnvelope.seal_with_record_key(
             snapshot,
             row,
             :authorization_attempt,
             %{payload | redirect: redirect},
             Support.row_aad(row)
           ) do
      row
      |> Ecto.Changeset.change(
        key_id: sealed.key_id,
        key_fingerprint: sealed.key_fingerprint,
        nonce: sealed.nonce,
        ciphertext: sealed.ciphertext
      )
      |> Repo.update!()

      commit_command(command, %{"authorization_ref" => row.authorization_ref})
      {:ok, Support.begin_result(row, redirect)}
    else
      {:error, reason} -> handle_driver_failure(command, reason)
    end
  end

  defp prepare_consume(request, authorization_ref, correlation_id, digest) do
    Repo.transaction(fn ->
      with %AuthorizationBackendRecord{} = row <- locked_record(authorization_ref),
           :ok <- existing_digest_matches(row.backend_pair_id, "consume", correlation_id, digest),
           :ok <- Support.expected_subject(row, request.expected_subject),
           :ok <- prepare_consume_lifecycle(row, correlation_id, digest) do
        attrs = Support.command_attrs(row, "consume", correlation_id, digest, authorization_ref)

        case insert_command(attrs) do
          :inserted ->
            with {:ok, sealed} <-
                   seal_callback_for_command(row, request, correlation_id, digest) do
              row
              |> Ecto.Changeset.change(
                consume_correlation_id: correlation_id,
                consume_input_digest: digest,
                callback_key_id: sealed.key_id,
                callback_key_fingerprint: sealed.key_fingerprint,
                callback_nonce: sealed.nonce,
                callback_ciphertext: sealed.ciphertext
              )
              |> Repo.update!()

              {:ok, row.backend_pair_id}
            end

          :existing ->
            reconcile_prepared_command(attrs, digest)
        end
      else
        nil -> {:error, :callback_invalid}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Support.unwrap_transaction()
  end

  defp seal_callback_for_command(row, request, correlation_id, digest) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, callback} <- callback_for_command(snapshot, row, request, correlation_id) do
      {:ok,
       SealedEnvelope.seal(
         snapshot,
         :active,
         :authorization_callback,
         callback,
         Support.callback_aad(row, correlation_id, digest)
       )}
    end
  end

  defp callback_for_command(_snapshot, _row, %{callback_envelope: callback}, _correlation_id)
       when is_map(callback),
       do: {:ok, callback}

  defp callback_for_command(snapshot, row, _request, correlation_id) do
    if row.consume_correlation_id == correlation_id and is_binary(row.consume_input_digest) do
      SealedEnvelope.open(
        snapshot,
        :authorization_callback,
        Support.callback_envelope(row),
        Support.callback_aad(row, correlation_id, row.consume_input_digest)
      )
    else
      {:error, :callback_invalid}
    end
  end

  defp finish_consume(pair_id, correlation_id, digest, request) do
    Repo.transaction(fn ->
      command = locked_command(pair_id, "consume", correlation_id)

      cond do
        command.bound_input_digest != digest ->
          {:error, :correlation_conflict}

        command.status == "committed" ->
          {:ok, Support.decode_consume_result(command.safe_result)}

        command.status == "terminal_failed" ->
          {:error, Support.safe_error(command.safe_error_code)}

        true ->
          row = locked_record(command.authorization_ref)

          with :ok <- consume_available(row, correlation_id, digest),
               :ok <- Support.expected_subject(row, request.expected_subject) do
            invoke_prepared_consume(command, row)
          end
      end
    end)
    |> Support.unwrap_transaction()
  end

  defp invoke_prepared_consume(command, row) do
    handoff_ref = Support.stable_ref("handoff", row.authorization_ref, command.correlation_id)

    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         {:ok, payload} <-
           SealedEnvelope.open(
             snapshot,
             :authorization_attempt,
             Support.envelope(row),
             Support.row_aad(row)
           ),
         {:ok, callback_envelope} <-
           SealedEnvelope.open(
             snapshot,
             :authorization_callback,
             Support.callback_envelope(row),
             Support.callback_aad(row, command.correlation_id, command.bound_input_digest)
           ),
         :ok <- Support.validate_callback(payload, callback_envelope, row),
         {:ok, _connection} <- connection_for_backend(row),
         {:ok, driver} <- frozen_driver(row),
         {:ok, {attempt, operation}} <- CallbackOperation.resolve(row, command),
         driver_identity <- CallbackOperation.driver_identity(row, command, attempt, operation),
         {:ok, driver_result} <-
           invoke_driver(
             driver,
             :consume_callback,
             row,
             command,
             payload,
             callback_envelope,
             driver_identity
           ),
         {:ok, normalized} <-
           Support.validate_consume_result(
             driver_result,
             callback_envelope,
             driver,
             operation.expected_authorization_ref,
             operation.expected_authorization_version
           ),
         handoff <-
           SealedEnvelope.seal(
             snapshot,
             :active,
             :credential_handoff,
             normalized.credential_material,
             Support.handoff_aad(
               row,
               command.correlation_id,
               handoff_ref,
               operation.operation_class
             )
           ) do
      safe_result =
        Map.put(normalized, :credential_material, {:write_only_handoff, handoff_ref})

      encoded = Support.encode_consume_result(safe_result)

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

      commit_command(command, encoded)
      {:ok, safe_result}
    else
      {:error, :authentication_failed} ->
        terminal_consume_failure(command, row, :state_mismatch)

      {:error, reason} ->
        handle_consume_failure(command, row, reason)
    end
  end

  defp invoke_driver(driver, operation, row, command, payload, callback_envelope, driver_identity) do
    private_frame = %{
      state: payload.state,
      pkce_verifier: payload.pkce_verifier,
      callback_envelope: callback_envelope,
      provider_id: row.provider_id,
      acquisition_method: row.acquisition_method,
      governed_host: row.governed_host
    }

    exchange = fn
      provider_exchange when is_function(provider_exchange, 1) ->
        provider_exchange.(private_frame)

      _other ->
        {:error, :provider_protocol_error}
    end

    context =
      Map.merge(
        %{
          authorization_ref: row.authorization_ref,
          correlation_id: command.correlation_id,
          callback_envelope_digest: Support.secret_digest(callback_envelope),
          exchange: exchange
        },
        driver_identity
      )

    EffectBoundary.invoke(
      fn -> apply(driver.implementation, operation, [context]) end,
      :provider_protocol_error
    )
    |> normalize_driver_reply()
  end

  defp normalize_driver_reply({:ok, result}) when is_map(result), do: {:ok, result}

  defp normalize_driver_reply({:error, reason}) when is_atom(reason) do
    {:ok, normalized} = normalize_error(reason)
    {:error, normalized}
  end

  defp normalize_driver_reply(_reply), do: {:error, :provider_protocol_error}

  defp apply_credential_effect(backend, operation, attempt, connection, credential_material) do
    command =
      operation
      |> Support.credential_command(attempt, connection)
      |> Map.put(:credential_material, credential_material)

    case operation.operation_class do
      "store" ->
        EffectBoundary.invoke(
          fn -> backend.store(command) end,
          :authorization_backend_unavailable
        )

      "replace" ->
        EffectBoundary.invoke(
          fn -> backend.replace(command) end,
          :authorization_backend_unavailable
        )

      _other ->
        {:error, :credential_conflict}
    end
  end

  defp prepare_consume_lifecycle(
         %{lifecycle_status: "pending", expires_at: expires_at} = row,
         _correlation_id,
         _digest
       ) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      row |> Ecto.Changeset.change(lifecycle_status: "expired") |> Repo.update!()
      {:error, :callback_expired}
    end
  end

  defp prepare_consume_lifecycle(%{lifecycle_status: "cancelled"}, _correlation_id, _digest),
    do: {:error, :authorization_cancelled}

  defp prepare_consume_lifecycle(%{lifecycle_status: "expired"}, _correlation_id, _digest),
    do: {:error, :callback_expired}

  defp prepare_consume_lifecycle(%{lifecycle_status: "consumed"} = row, correlation_id, digest) do
    cond do
      row.consume_correlation_id != correlation_id -> {:error, :callback_already_consumed}
      row.consume_input_digest != digest -> {:error, :correlation_conflict}
      true -> :ok
    end
  end

  defp consume_available(row, correlation_id, digest),
    do: prepare_consume_lifecycle(row, correlation_id, digest)

  defp connection_for_backend(row) do
    case Repo.get(Connection, row.connection_id) do
      %Connection{} = connection ->
        case Support.validate_backend_connection_scope(row, connection) do
          :ok -> {:ok, connection}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :invalid_authorization_subject}
    end
  end

  defp frozen_driver(row) do
    with {:ok, driver} <-
           normalize_lookup(DriverRegistry.lookup(row.provider_id, row.acquisition_method)),
         true <- row.backend_pair_id in driver.backend_pair_ids,
         :ok <- Support.local_pair?(row.backend_pair_id) do
      {:ok, driver}
    else
      _other -> {:error, :authorization_backend_unavailable}
    end
  end

  defp registered_credential_backend(pair_id) do
    implementations =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations,
        %{}
      )

    with {:ok, pair} <- BackendPairRegistry.lookup(pair_id),
         {:ok, module} <- Map.fetch(implementations, pair.credential_backend.id),
         true <- is_atom(module) do
      {:ok, module}
    else
      _reason -> {:error, :credential_conflict}
    end
  end

  defp normalize_lookup({:ok, value}), do: {:ok, value}
  defp normalize_lookup(:error), do: {:error, :authorization_backend_unavailable}

  defp existing_digest_matches(pair_id, operation, correlation_id, digest) do
    case maybe_command(pair_id, operation, correlation_id) do
      %{bound_input_digest: ^digest} -> :ok
      %ProviderAuthorizationCommand{} -> {:error, :correlation_conflict}
      nil -> :ok
    end
  end

  defp reconcile_prepared_command(attrs, digest) do
    command = command(attrs.backend_pair_id, attrs.operation_class, attrs.correlation_id)

    if command.bound_input_digest == digest,
      do: {:ok, attrs.backend_pair_id},
      else: {:error, :correlation_conflict}
  end

  defp insert_command(attrs) do
    now = DateTime.utc_now()
    row = Map.merge(attrs, %{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(ProviderAuthorizationCommand, [row],
           on_conflict: :nothing,
           conflict_target: [:backend_pair_id, :operation_class, :correlation_id]
         ) do
      {1, _rows} -> :inserted
      {0, _rows} -> :existing
    end
  end

  defp insert_backend_record!(request, subject, pair_id, digest, ref, expires_at, envelope) do
    %{
      id: Ecto.UUID.generate(),
      workspace_uri: URI.to_string(subject.workspace_uri),
      backend_pair_id: pair_id,
      authorization_ref: ref,
      key_id: envelope.key_id,
      key_fingerprint: envelope.key_fingerprint,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext,
      bound_input_digest: digest,
      begin_correlation_id: request.correlation_id,
      owner_uri: URI.to_string(subject.owner_uri),
      execution_identity: subject.execution_identity,
      connection_id: subject.connection_id,
      connection_version: subject.connection_version,
      provider_id: subject.provider_id,
      governed_host: subject.governed_host,
      acquisition_method: request.acquisition_method,
      requested_permissions_digest: request.requested_permissions_digest,
      redirect_uri_id: request.redirect_uri_id,
      lifecycle_status: "pending",
      expires_at: expires_at
    }
    |> AuthorizationBackendRecord.create_changeset()
    |> Repo.insert!()
  end

  defp commit_command(command_or_attrs, safe_result) do
    command =
      locked_command(
        command_or_attrs.backend_pair_id,
        command_or_attrs.operation_class,
        command_or_attrs.correlation_id
      )

    command
    |> Ecto.Changeset.change(status: "committed", safe_result: safe_result, safe_error_code: nil)
    |> Repo.update!()
  end

  defp fail_command(command_or_attrs, reason) do
    command =
      locked_command(
        command_or_attrs.backend_pair_id,
        command_or_attrs.operation_class,
        command_or_attrs.correlation_id
      )

    command
    |> Ecto.Changeset.change(status: "terminal_failed", safe_error_code: Atom.to_string(reason))
    |> Repo.update!()
  end

  defp handle_driver_failure(command, reason) do
    with {:ok, normalized} <- normalize_error(reason) do
      if normalized == :authorization_backend_unavailable,
        do: {:error, normalized},
        else: terminal_failure(command, normalized)
    else
      _error -> terminal_failure(command, :provider_protocol_error)
    end
  end

  defp handle_consume_failure(command, row, reason) do
    with {:ok, normalized} <- normalize_error(reason) do
      if normalized == :authorization_backend_unavailable,
        do: {:error, normalized},
        else: terminal_consume_failure(command, row, normalized)
    else
      _error -> terminal_consume_failure(command, row, :provider_protocol_error)
    end
  end

  defp terminal_consume_failure(command, row, reason) do
    row |> Ecto.Changeset.change(callback_nonce: nil, callback_ciphertext: nil) |> Repo.update!()
    terminal_failure(command, reason)
  end

  defp terminal_failure(command, reason) do
    fail_command(command, reason)
    {:error, reason}
  end

  defp normalize_error(:backend_unavailable), do: {:ok, :authorization_backend_unavailable}
  defp normalize_error(:provider_denied), do: {:ok, :provider_authorization_denied}
  defp normalize_error(:provider_protocol_failed), do: {:ok, :provider_protocol_error}

  defp normalize_error(reason)
       when reason in ~w(authorization_backend_unavailable correlation_conflict invalid_authorization_subject invalid_acquisition_method governed_host_mismatch state_mismatch pkce_mismatch callback_expired callback_already_consumed callback_invalid external_account_mismatch reauthentication_required reauthentication_failed authorization_cancelled provider_authorization_denied provider_protocol_error stale_connection_version)a,
       do: {:ok, reason}

  defp normalize_error(_reason), do: {:ok, :provider_protocol_error}

  defp locked_record(ref) do
    Repo.one(
      from(row in AuthorizationBackendRecord,
        where: row.authorization_ref == ^ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp command(pair, operation, correlation) do
    Repo.one!(
      from(command in ProviderAuthorizationCommand,
        where:
          command.backend_pair_id == ^pair and command.operation_class == ^operation and
            command.correlation_id == ^correlation
      )
    )
  end

  defp maybe_command(pair, operation, correlation) do
    Repo.one(
      from(command in ProviderAuthorizationCommand,
        where:
          command.backend_pair_id == ^pair and command.operation_class == ^operation and
            command.correlation_id == ^correlation
      )
    )
  end

  defp locked_command(pair, operation, correlation) do
    Repo.one!(
      from(command in ProviderAuthorizationCommand,
        where:
          command.backend_pair_id == ^pair and command.operation_class == ^operation and
            command.correlation_id == ^correlation,
        lock: "FOR UPDATE"
      )
    )
  end

  defp state_key_id(raw_state) do
    case :binary.matches(raw_state, ".") do
      [] ->
        {:error, :callback_invalid}

      matches ->
        {separator, 1} = List.last(matches)
        key_id = binary_part(raw_state, 0, separator)
        opaque_size = byte_size(raw_state) - separator - 1

        if opaque_size > 0 and Regex.match?(@key_id_pattern, key_id),
          do: {:ok, key_id},
          else: {:error, :callback_invalid}
    end
  end
end
