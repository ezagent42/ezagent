defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend do
  @moduledoc """
  Durable local implementation of the frozen D0 authorization boundary.

  Begin and consume use two transactions. The first commits the prepared
  command and encrypted recovery material. The second locks that durable state
  through the driver effect and commit. A stable correlation id is supplied to
  the driver for its provider-side idempotency across the unavoidable crash
  window after a provider effect and before the second transaction commits.
  """

  @behaviour Ezagent.ProviderConnection.ProviderAuthorizationBackend

  import Ecto.Query

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.Connection
  alias Ezagent.ProviderConnection.Driver
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias Ezagent.ProviderConnection.Operation
  alias EzagentCore.Repo

  @backend_id "local-authorization-v1"
  @digest_schema "provider-authorization-command-v1"
  @tag_bytes 16
  @fixture_enabled Application.compile_env(
                     :ezagent_domain_provider_connection,
                     :authorization_key_ring_fixture_enabled,
                     false
                   )
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/
  @authorization_errors ~w(
    authorization_backend_unavailable correlation_conflict invalid_authorization_subject
    invalid_acquisition_method governed_host_mismatch state_mismatch pkce_mismatch
    callback_expired callback_already_consumed callback_invalid external_account_mismatch
    reauthentication_required reauthentication_failed authorization_cancelled
    provider_authorization_denied provider_protocol_error stale_connection_version
  )a

  @begin_keys MapSet.new(
                ~w(subject acquisition_method requested_permissions_digest redirect_uri_id correlation_id bound_input_digest)a ++
                  ["bound_input_digest"]
              )
  @consume_keys MapSet.new(
                  ~w(authorization_ref callback_envelope expected_subject correlation_id bound_input_digest)a ++
                    ["bound_input_digest"]
                )
  @cancel_keys MapSet.new(
                 ~w(authorization_ref expected_subject correlation_id bound_input_digest)a ++
                   ["bound_input_digest"]
               )
  @reauth_keys MapSet.new(
                 ~w(subject session_assurance_evidence correlation_id bound_input_digest)a ++
                   ["bound_input_digest"]
               )

  @impl true
  def begin_authorization(request) when is_map(request) do
    with :ok <- closed_keys(request, @begin_keys),
         {:ok, subject} <- subject(request[:subject]),
         {:ok, correlation_id} <- required_binary(request, :correlation_id, :callback_invalid),
         {:ok, method} <- acquisition_method(request),
         {:ok, _permissions_digest} <-
           required_binary(request, :requested_permissions_digest, :callback_invalid),
         {:ok, _redirect_uri_id} <-
           required_binary(request, :redirect_uri_id, :callback_invalid),
         {:ok, driver, pair_id} <- configured_driver(subject.provider_id, method),
         {:ok, digest} <- command_digest(:begin, request),
         {:ok, authorization_ref} <- prepare_begin(request, subject, pair_id, digest),
         result <- finish_begin(pair_id, correlation_id, digest, driver, authorization_ref) do
      result
    end
  end

  def begin_authorization(_request), do: {:error, :callback_invalid}

  @impl true
  def consume_callback(request) when is_map(request) do
    with :ok <- closed_keys(request, @consume_keys),
         {:ok, authorization_ref} <-
           required_binary(request, :authorization_ref, :callback_invalid),
         {:ok, correlation_id} <- required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- command_digest(:consume, request),
         {:ok, pair_id} <- prepare_consume(request, authorization_ref, correlation_id, digest),
         result <- finish_consume(pair_id, correlation_id, digest, request) do
      result
    end
  end

  def consume_callback(_request), do: {:error, :callback_invalid}

  @doc "Computes the callback-state digest without exposing key material."
  @spec state_digest(String.t()) :: {:ok, String.t()} | {:error, :callback_invalid}
  def state_digest(raw_state) when is_binary(raw_state) do
    with {:ok, snapshot} <- crypto_state(),
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
           {:ok, snapshot} <- crypto_state() do
        callback = Map.put(provider_envelope, :state, raw_state)
        digest = digest(callback)

        cond do
          is_binary(row.callback_ciphertext) and row.consume_correlation_id == correlation_id and
              row.consume_input_digest == digest ->
            :ok

          is_binary(row.callback_ciphertext) ->
            {:error, :correlation_conflict}

          true ->
            sealed =
              seal_with(
                snapshot,
                :active,
                :authorization_callback,
                callback,
                callback_aad(row, correlation_id, digest)
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
    |> unwrap_transaction()
  end

  @doc false
  def handoff_to_registered_credential(operation_id, attempt_ref)
      when is_binary(operation_id) and is_binary(attempt_ref) do
    with %Operation{status: "prepared"} = operation <- Repo.get(Operation, operation_id),
         %AuthorizationAttempt{} = attempt <- Repo.get(AuthorizationAttempt, attempt_ref),
         %Connection{} = connection <- Repo.get(Connection, attempt.connection_id),
         :ok <- validate_operation_fence(operation, attempt, connection),
         %AuthorizationBackendRecord{} = row <-
           Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref),
         :ok <- validate_handoff(row, operation, attempt, connection),
         {:ok, credential_backend} <- registered_credential_backend(attempt.backend_pair_id),
         {:ok, snapshot} <- crypto_state(),
         {:ok, envelope} <- decode_handoff_envelope(row.handoff_ciphertext),
         {:ok, credential_material} <-
           unseal_with(
             snapshot,
             :credential_handoff,
             envelope,
             handoff_aad(row, attempt.correlation_id, operation.handoff_ref)
           ),
         {:ok, result} <-
           credential_backend.store(
             operation
             |> credential_command(attempt, connection)
             |> Map.put(:credential_material, credential_material)
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

  @impl true
  def cancel_authorization(request) when is_map(request) do
    with :ok <- closed_keys(request, @cancel_keys),
         {:ok, authorization_ref} <-
           required_binary(request, :authorization_ref, :callback_invalid),
         {:ok, correlation_id} <- required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- command_digest(:cancel, request) do
      Repo.transaction(fn ->
        cancel_locked(authorization_ref, correlation_id, digest, request)
      end)
      |> unwrap_transaction()
    end
  end

  def cancel_authorization(_request), do: {:error, :callback_invalid}

  @impl true
  def reauthenticate(request) when is_map(request) do
    with :ok <- closed_keys(request, @reauth_keys),
         {:ok, subject} <- subject(request[:subject]),
         {:ok, correlation_id} <- required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- command_digest(:reauthenticate, request),
         {:ok, pair_id} <- durable_pair_for_reauthentication(subject, correlation_id, digest),
         :ok <- local_pair?(pair_id),
         true <- is_binary(pair_id) do
      attrs =
        command_attrs(
          URI.to_string(subject.workspace_uri),
          pair_id,
          "reauthenticate",
          correlation_id,
          digest,
          nil
        )

      Repo.transaction(fn ->
        case insert_command(attrs) do
          :inserted -> commit_reauthentication(attrs, request)
          :existing -> reconcile_reauthentication(pair_id, correlation_id, digest)
        end
      end)
      |> unwrap_transaction()
    end
  end

  def reauthenticate(_request), do: {:error, :callback_invalid}

  defp prepare_begin(request, subject, pair_id, digest) do
    correlation_id = request.correlation_id
    authorization_ref = stable_ref("auth", pair_id, correlation_id)
    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
    aad = begin_aad(authorization_ref, pair_id, digest, subject, request, expires_at)

    with {:ok, snapshot} <- crypto_state() do
      payload = %{
        state: "#{snapshot.active_key_id}.#{random_token(32)}",
        pkce_verifier: random_token(48),
        redirect: nil
      }

      envelope = seal_with(snapshot, :active, :authorization_attempt, payload, aad)

      Repo.transaction(fn ->
        attrs =
          command_attrs(
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
      |> unwrap_transaction()
    end
  end

  defp finish_begin(pair_id, correlation_id, digest, _driver, authorization_ref) do
    Repo.transaction(fn ->
      command = locked_command(pair_id, "begin", correlation_id)

      cond do
        command.bound_input_digest != digest ->
          {:error, :correlation_conflict}

        command.authorization_ref != authorization_ref ->
          {:error, :correlation_conflict}

        command.status == "terminal_failed" ->
          {:error, safe_error(command.safe_error_code)}

        true ->
          row = locked_record(authorization_ref)
          finish_begin_command(command, row)
      end
    end)
    |> unwrap_transaction()
  end

  defp finish_begin_command(command, row) do
    with {:ok, snapshot} <- crypto_state(),
         {:ok, payload} <-
           unseal_with(snapshot, :authorization_attempt, envelope(row), row_aad(row)) do
      if command.status == "committed" do
        case payload.redirect do
          redirect when is_map(redirect) -> {:ok, begin_result(row, redirect)}
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
           invoke_driver(driver, :begin_authorization, row, command, payload, %{}),
         {:ok, redirect} <- normalize_begin_result(driver_result, payload, driver),
         {:ok, sealed} <-
           seal_with_record_key(
             snapshot,
             row,
             :authorization_attempt,
             %{payload | redirect: redirect},
             row_aad(row)
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
      {:ok, begin_result(row, redirect)}
    else
      {:error, reason} -> handle_driver_failure(command, reason)
    end
  end

  defp prepare_consume(request, authorization_ref, correlation_id, digest) do
    Repo.transaction(fn ->
      with %AuthorizationBackendRecord{} = row <- locked_record(authorization_ref),
           :ok <- existing_digest_matches(row.backend_pair_id, "consume", correlation_id, digest),
           :ok <- expected_subject(row, request.expected_subject),
           :ok <- prepare_consume_lifecycle(row, correlation_id, digest) do
        attrs = command_attrs(row, "consume", correlation_id, digest, authorization_ref)

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
    |> unwrap_transaction()
  end

  defp seal_callback_for_command(row, request, correlation_id, digest) do
    with {:ok, snapshot} <- crypto_state(),
         {:ok, callback} <- callback_for_command(snapshot, row, request, correlation_id) do
      {:ok,
       seal_with(
         snapshot,
         :active,
         :authorization_callback,
         callback,
         callback_aad(row, correlation_id, digest)
       )}
    end
  end

  defp callback_for_command(_snapshot, _row, %{callback_envelope: callback}, _correlation_id)
       when is_map(callback),
       do: {:ok, callback}

  defp callback_for_command(snapshot, row, _request, correlation_id) do
    if row.consume_correlation_id == correlation_id and is_binary(row.consume_input_digest) do
      unseal_with(
        snapshot,
        :authorization_callback,
        callback_envelope(row),
        callback_aad(row, correlation_id, row.consume_input_digest)
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
          {:ok, decode_consume_result(command.safe_result)}

        command.status == "terminal_failed" ->
          {:error, safe_error(command.safe_error_code)}

        true ->
          row = locked_record(command.authorization_ref)

          with :ok <- consume_available(row, correlation_id, digest),
               :ok <- expected_subject(row, request.expected_subject) do
            invoke_prepared_consume(command, row)
          end
      end
    end)
    |> unwrap_transaction()
  end

  defp invoke_prepared_consume(command, row) do
    handoff_ref = stable_ref("handoff", row.authorization_ref, command.correlation_id)

    with {:ok, snapshot} <- crypto_state(),
         {:ok, payload} <-
           unseal_with(snapshot, :authorization_attempt, envelope(row), row_aad(row)),
         {:ok, callback_envelope} <-
           unseal_with(
             snapshot,
             :authorization_callback,
             callback_envelope(row),
             callback_aad(row, command.correlation_id, command.bound_input_digest)
           ),
         :ok <- validate_callback(payload, callback_envelope, row),
         {:ok, _connection} <- connection_for_backend(row),
         {:ok, driver} <- frozen_driver(row),
         {:ok, driver_result} <-
           invoke_driver(driver, :consume_callback, row, command, payload, callback_envelope),
         {:ok, normalized} <-
           normalize_consume_result(driver_result, callback_envelope, driver),
         handoff <-
           seal_with(
             snapshot,
             :active,
             :credential_handoff,
             normalized.credential_material,
             handoff_aad(row, command.correlation_id, handoff_ref)
           ) do
      safe_result = Map.put(normalized, :credential_material, {:write_only_handoff, handoff_ref})
      encoded = encode_consume_result(safe_result)

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

  defp cancel_locked(authorization_ref, correlation_id, digest, request) do
    with %AuthorizationBackendRecord{} = row <- locked_record(authorization_ref),
         :ok <- existing_digest_matches(row.backend_pair_id, "cancel", correlation_id, digest),
         :ok <- expected_subject(row, request.expected_subject) do
      case cancel_lifecycle(row) do
        :pending -> cancel_pending(row, correlation_id, digest)
        {:error, :authorization_cancelled} -> replay_cancel(row, correlation_id, digest)
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :callback_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_pending(row, correlation_id, digest) do
    attrs = command_attrs(row, "cancel", correlation_id, digest, row.authorization_ref)

    case insert_command(attrs) do
      :inserted ->
        row |> Ecto.Changeset.change(lifecycle_status: "cancelled") |> Repo.update!()
        commit_command(attrs, nil)
        :ok

      :existing ->
        replay_cancel(row, correlation_id, digest)
    end
  end

  defp replay_cancel(row, correlation_id, digest) do
    case maybe_command(row.backend_pair_id, "cancel", correlation_id) do
      %{bound_input_digest: ^digest, status: "committed"} -> :ok
      nil -> {:error, :authorization_cancelled}
      _other -> {:error, :correlation_conflict}
    end
  end

  defp commit_reauthentication(attrs, %{session_assurance_evidence: %{aal: aal}})
       when aal in [:aal2, :aal3] do
    result = %{
      "reauth_ref" => stable_ref("reauth", attrs.backend_pair_id, attrs.correlation_id),
      "expires_at" => DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()
    }

    commit_command(attrs, result)
    {:ok, decode_reauth_result(result)}
  end

  defp commit_reauthentication(attrs, _request) do
    fail_command(attrs, :reauthentication_failed)
    {:error, :reauthentication_failed}
  end

  defp reconcile_reauthentication(pair_id, correlation_id, digest) do
    command = locked_command(pair_id, "reauthenticate", correlation_id)

    cond do
      command.bound_input_digest != digest -> {:error, :correlation_conflict}
      command.status == "committed" -> {:ok, decode_reauth_result(command.safe_result)}
      command.status == "terminal_failed" -> {:error, safe_error(command.safe_error_code)}
      true -> {:error, :authorization_backend_unavailable}
    end
  end

  defp durable_pair_for_reauthentication(subject, correlation_id, digest) do
    case durable_pairs(subject, true) do
      [pair_id] ->
        {:ok, pair_id}

      _other ->
        case durable_pairs(subject, false) do
          [pair_id] ->
            case maybe_command(pair_id, "reauthenticate", correlation_id) do
              %{bound_input_digest: stored} when stored != digest ->
                {:error, :correlation_conflict}

              _command ->
                {:error, :invalid_authorization_subject}
            end

          _other ->
            {:error, :invalid_authorization_subject}
        end
    end
  end

  defp durable_pairs(subject, exact_version?) do
    query =
      AuthorizationBackendRecord
      |> where(
        [row],
        row.owner_uri == ^URI.to_string(subject.owner_uri) and
          row.workspace_uri == ^URI.to_string(subject.workspace_uri) and
          row.connection_id == ^subject.connection_id and
          row.provider_id == ^subject.provider_id and row.governed_host == ^subject.governed_host
      )

    query =
      if exact_version?,
        do: where(query, [row], row.connection_version == ^subject.connection_version),
        else: query

    query
    |> select([row], row.backend_pair_id)
    |> distinct(true)
    |> Repo.all()
  end

  defp existing_digest_matches(pair_id, operation, correlation_id, digest) do
    case maybe_command(pair_id, operation, correlation_id) do
      %{bound_input_digest: ^digest} -> :ok
      %ProviderAuthorizationCommand{} -> {:error, :correlation_conflict}
      nil -> :ok
    end
  end

  defp configured_driver(provider_id, method) do
    mappings =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :local_authorization_backend_pairs,
        %{}
      )

    with {:ok, pair_id} <- Map.fetch(mappings, {provider_id, method}),
         {:ok, driver} <- normalize_lookup(DriverRegistry.lookup(provider_id, method)),
         true <- pair_id in driver.backend_pair_ids,
         :ok <- local_pair?(pair_id) do
      {:ok, driver, pair_id}
    else
      :error -> missing_mapping_error(mappings, provider_id)
      false -> {:error, :authorization_backend_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing_mapping_error(mappings, provider_id) do
    if Enum.any?(Map.keys(mappings), fn
         {^provider_id, _method} -> true
         _other -> false
       end) do
      {:error, :invalid_acquisition_method}
    else
      {:error, :authorization_backend_unavailable}
    end
  end

  defp frozen_driver(row) do
    with {:ok, driver} <-
           normalize_lookup(DriverRegistry.lookup(row.provider_id, row.acquisition_method)),
         true <- row.backend_pair_id in driver.backend_pair_ids,
         :ok <- local_pair?(row.backend_pair_id) do
      {:ok, driver}
    else
      _other -> {:error, :authorization_backend_unavailable}
    end
  end

  defp local_pair?(pair_id) do
    with {:ok, pair} <- BackendPairRegistry.lookup(pair_id),
         true <- pair.authorization_backend.id == @backend_id do
      :ok
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

  defp invoke_driver(driver, operation, row, command, payload, callback_envelope) do
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

    context = %{
      authorization_ref: row.authorization_ref,
      correlation_id: command.correlation_id,
      callback_envelope_digest: secret_digest(callback_envelope),
      exchange: exchange
    }

    try do
      apply(driver.implementation, operation, [context])
    rescue
      _error -> {:error, :provider_protocol_error}
    catch
      _kind, _reason -> {:error, :provider_protocol_error}
    end
    |> normalize_driver_reply()
  end

  defp normalize_driver_reply({:ok, result}) when is_map(result), do: {:ok, result}

  defp normalize_driver_reply({:error, reason}) when is_atom(reason) do
    {:ok, normalized} = normalize_error(reason)
    {:error, normalized}
  end

  defp normalize_driver_reply(_reply), do: {:error, :provider_protocol_error}

  defp normalize_begin_result(%{redirect: redirect} = result, payload, driver)
       when map_size(result) == 1 and is_map(redirect) do
    with uri when is_binary(uri) and uri != "" <- field(redirect, :authorization_uri),
         true <- field(redirect, :state) == payload.state,
         true <- field(redirect, :pkce_digest) == pkce_digest(payload.pkce_verifier),
         true <-
           Driver.matches_schema?(
             redirect,
             driver.metadata.authorization_redirect_schema
           ) do
      {:ok, stringify_keys(redirect)}
    else
      _other -> {:error, :provider_protocol_error}
    end
  end

  defp normalize_begin_result(_result, _payload, _driver),
    do: {:error, :provider_protocol_error}

  defp normalize_consume_result(result, callback, driver) do
    expected_keys =
      MapSet.new(
        ~w(external_account_id display_login execution_identity credential_material granted_permissions_digest provider_metadata)a
      )

    with true <- MapSet.new(Map.keys(result)) == expected_keys,
         external_account_id when is_binary(external_account_id) and external_account_id != "" <-
           result.external_account_id,
         display_login when is_binary(display_login) and display_login != "" <-
           result.display_login,
         :ok <- execution_identity(result.execution_identity, external_account_id),
         true <- portable_secret?(result.credential_material),
         digest when is_binary(digest) and digest != "" <- result.granted_permissions_digest,
         true <-
           Driver.matches_schema?(
             result.provider_metadata,
             driver.metadata.provider_metadata_schema
           ),
         :ok <- external_account_binding(callback, external_account_id) do
      {:ok, %{result | provider_metadata: stringify_keys(result.provider_metadata)}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :provider_protocol_error}
    end
  end

  defp execution_identity(
         %{kind: :connected_user, external_account_id: external_account_id} = identity,
         external_account_id
       )
       when map_size(identity) == 2,
       do: :ok

  defp execution_identity(_identity, _external_account_id),
    do: {:error, :provider_protocol_error}

  defp external_account_binding(callback, external_account_id) do
    case field(callback, :external_account_id) do
      nil -> :ok
      ^external_account_id -> :ok
      _other -> {:error, :external_account_mismatch}
    end
  end

  defp validate_callback(payload, callback, row) when is_map(callback) do
    cond do
      field(callback, :state) != payload.state ->
        {:error, :state_mismatch}

      field(callback, :pkce_digest) != pkce_digest(payload.pkce_verifier) ->
        {:error, :pkce_mismatch}

      field(callback, :governed_host) != row.governed_host ->
        {:error, :governed_host_mismatch}

      field(callback, :acquisition_origin) == :social_login ->
        {:error, :callback_invalid}

      true ->
        :ok
    end
  end

  defp validate_callback(_payload, _callback, _row), do: {:error, :callback_invalid}

  defp handle_driver_failure(command, reason) do
    with {:ok, normalized} <- normalize_error(reason) do
      if normalized == :authorization_backend_unavailable do
        {:error, normalized}
      else
        terminal_failure(command, normalized)
      end
    else
      _error -> terminal_failure(command, :provider_protocol_error)
    end
  end

  defp handle_consume_failure(command, row, reason) do
    with {:ok, normalized} <- normalize_error(reason) do
      if normalized == :authorization_backend_unavailable do
        {:error, normalized}
      else
        terminal_consume_failure(command, row, normalized)
      end
    else
      _error -> terminal_consume_failure(command, row, :provider_protocol_error)
    end
  end

  defp terminal_consume_failure(command, row, reason) do
    row
    |> Ecto.Changeset.change(callback_nonce: nil, callback_ciphertext: nil)
    |> Repo.update!()

    terminal_failure(command, reason)
  end

  defp terminal_failure(command, reason) do
    fail_command(command, reason)
    {:error, reason}
  end

  defp normalize_error(:backend_unavailable), do: {:ok, :authorization_backend_unavailable}
  defp normalize_error(:provider_denied), do: {:ok, :provider_authorization_denied}
  defp normalize_error(:provider_protocol_failed), do: {:ok, :provider_protocol_error}
  defp normalize_error(reason) when reason in @authorization_errors, do: {:ok, reason}
  defp normalize_error(_reason), do: {:ok, :provider_protocol_error}

  defp prepare_consume_lifecycle(
         %{lifecycle_status: "pending", expires_at: expires_at} = row,
         _corr,
         _digest
       ) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      row |> Ecto.Changeset.change(lifecycle_status: "expired") |> Repo.update!()
      {:error, :callback_expired}
    end
  end

  defp prepare_consume_lifecycle(%{lifecycle_status: "cancelled"}, _corr, _digest),
    do: {:error, :authorization_cancelled}

  defp prepare_consume_lifecycle(%{lifecycle_status: "expired"}, _corr, _digest),
    do: {:error, :callback_expired}

  defp prepare_consume_lifecycle(%{lifecycle_status: "consumed"} = row, corr, digest) do
    cond do
      row.consume_correlation_id != corr -> {:error, :callback_already_consumed}
      row.consume_input_digest != digest -> {:error, :correlation_conflict}
      true -> :ok
    end
  end

  defp consume_available(row, corr, digest), do: prepare_consume_lifecycle(row, corr, digest)

  defp cancel_lifecycle(%{lifecycle_status: "pending", expires_at: expires_at} = row) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :pending
    else
      row |> Ecto.Changeset.change(lifecycle_status: "expired") |> Repo.update!()
      {:error, :callback_expired}
    end
  end

  defp cancel_lifecycle(%{lifecycle_status: "cancelled"}),
    do: {:error, :authorization_cancelled}

  defp cancel_lifecycle(%{lifecycle_status: "consumed"}),
    do: {:error, :callback_already_consumed}

  defp cancel_lifecycle(%{lifecycle_status: "expired"}), do: {:error, :callback_expired}

  defp reconcile_prepared_command(attrs, digest) do
    command = command(attrs.backend_pair_id, attrs.operation_class, attrs.correlation_id)

    if command.bound_input_digest == digest,
      do: {:ok, attrs.backend_pair_id},
      else: {:error, :correlation_conflict}
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

  defp command_attrs(row, operation, correlation, digest, authorization_ref),
    do:
      command_attrs(
        row.workspace_uri,
        row.backend_pair_id,
        operation,
        correlation,
        digest,
        authorization_ref
      )

  defp command_attrs(workspace_uri, pair_id, operation, correlation, digest, authorization_ref) do
    %{
      workspace_uri: workspace_uri,
      backend_pair_id: pair_id,
      operation_class: operation,
      correlation_id: correlation,
      bound_input_digest: digest,
      authorization_ref: authorization_ref,
      status: "prepared"
    }
  end

  defp locked_record(ref),
    do:
      Repo.one(
        from(row in AuthorizationBackendRecord,
          where: row.authorization_ref == ^ref,
          lock: "FOR UPDATE"
        )
      )

  defp command(pair, operation, correlation),
    do:
      Repo.one!(
        from(command in ProviderAuthorizationCommand,
          where:
            command.backend_pair_id == ^pair and command.operation_class == ^operation and
              command.correlation_id == ^correlation
        )
      )

  defp maybe_command(pair, operation, correlation),
    do:
      Repo.one(
        from(command in ProviderAuthorizationCommand,
          where:
            command.backend_pair_id == ^pair and command.operation_class == ^operation and
              command.correlation_id == ^correlation
        )
      )

  defp locked_command(pair, operation, correlation),
    do:
      Repo.one!(
        from(command in ProviderAuthorizationCommand,
          where:
            command.backend_pair_id == ^pair and command.operation_class == ^operation and
              command.correlation_id == ^correlation,
          lock: "FOR UPDATE"
        )
      )

  defp expected_subject(row, value) do
    with {:ok, subject} <- subject(value),
         true <- URI.to_string(subject.owner_uri) == row.owner_uri,
         true <- URI.to_string(subject.workspace_uri) == row.workspace_uri,
         true <- subject.connection_id == row.connection_id,
         true <- subject.connection_version == row.connection_version,
         true <- subject.provider_id == row.provider_id,
         true <- subject.governed_host == row.governed_host,
         true <- subject.execution_identity == row.execution_identity do
      :ok
    else
      _other -> {:error, :invalid_authorization_subject}
    end
  end

  defp subject(
         %{
           owner_uri: %URI{} = owner,
           workspace_uri: %URI{} = workspace,
           provider_id: provider,
           governed_host: host,
           connection_id: connection,
           connection_version: version,
           execution_identity: execution_identity
         } = subject
       )
       when map_size(subject) == 7 and is_binary(provider) and provider != "" and
              is_binary(host) and host != "" and is_binary(connection) and connection != "" and
              is_integer(version) and version >= 0 and is_binary(execution_identity) and
              execution_identity != "" do
    with true <- Ezagent.URI.scheme?(owner, :entity),
         true <- Ezagent.URI.type?(owner, :user),
         true <- Ezagent.URI.scheme?(workspace, :workspace),
         {:ok, owner_workspace} <- Ezagent.URI.workspace_name(owner),
         {:ok, workspace_name} <- Ezagent.URI.workspace_name(workspace),
         {:ok, owner_name} <- Ezagent.URI.name(owner),
         true <- owner_workspace == workspace_name,
         true <- owner == Ezagent.URI.user(owner_workspace, owner_name),
         true <- workspace == Ezagent.URI.workspace(workspace_name) do
      {:ok, subject}
    else
      _other -> {:error, :invalid_authorization_subject}
    end
  end

  defp subject(_value), do: {:error, :invalid_authorization_subject}

  defp acquisition_method(request) do
    required_binary(request, :acquisition_method, :invalid_acquisition_method)
  end

  defp begin_aad(ref, pair, digest, subject, request, expires_at) do
    %{
      authorization_ref: ref,
      backend_pair_id: pair,
      bound_input_digest: digest,
      owner_uri: URI.to_string(subject.owner_uri),
      workspace_uri: URI.to_string(subject.workspace_uri),
      connection_id: subject.connection_id,
      connection_version: subject.connection_version,
      execution_identity: subject.execution_identity,
      provider_id: subject.provider_id,
      governed_host: subject.governed_host,
      acquisition_method: request.acquisition_method,
      requested_permissions_digest: request.requested_permissions_digest,
      redirect_uri_id: request.redirect_uri_id,
      begin_correlation_id: request.correlation_id,
      expires_at: DateTime.to_iso8601(expires_at)
    }
  end

  defp row_aad(row) do
    %{
      authorization_ref: row.authorization_ref,
      backend_pair_id: row.backend_pair_id,
      bound_input_digest: row.bound_input_digest,
      owner_uri: row.owner_uri,
      workspace_uri: row.workspace_uri,
      connection_id: row.connection_id,
      connection_version: row.connection_version,
      execution_identity: row.execution_identity,
      provider_id: row.provider_id,
      governed_host: row.governed_host,
      acquisition_method: row.acquisition_method,
      requested_permissions_digest: row.requested_permissions_digest,
      redirect_uri_id: row.redirect_uri_id,
      begin_correlation_id: row.begin_correlation_id,
      expires_at: DateTime.to_iso8601(row.expires_at)
    }
  end

  defp handoff_aad(row, correlation, handoff_ref),
    do: %{
      authorization_ref: row.authorization_ref,
      bound_input_digest: row.bound_input_digest,
      begin_correlation_id: row.begin_correlation_id,
      owner_uri: row.owner_uri,
      workspace_uri: row.workspace_uri,
      connection_id: row.connection_id,
      connection_version: row.connection_version,
      backend_pair_id: row.backend_pair_id,
      provider_id: row.provider_id,
      governed_host: row.governed_host,
      acquisition_method: row.acquisition_method,
      execution_identity: row.execution_identity,
      requested_permissions_digest: row.requested_permissions_digest,
      redirect_uri_id: row.redirect_uri_id,
      correlation_id: correlation,
      credential_correlation_id: "store:#{correlation}",
      handoff_ref: handoff_ref
    }

  defp validate_handoff(row, operation, attempt, connection) do
    if row.backend_pair_id == operation.backend_pair_id and
         row.backend_pair_id == attempt.backend_pair_id and
         row.authorization_ref == attempt.authorization_ref and
         row.bound_input_digest == attempt.bound_subject_digest and
         row.owner_uri == connection.owner_uri and
         row.workspace_uri == operation.workspace_uri and
         row.workspace_uri == attempt.workspace_uri and
         row.workspace_uri == connection.workspace_uri and
         row.connection_id == operation.connection_id and
         row.connection_id == attempt.connection_id and
         row.connection_id == connection.connection_id and
         row.connection_version == operation.expected_connection_version and
         row.connection_version == attempt.connection_version and
         row.connection_version == connection.connection_version and
         row.provider_id == connection.provider_id and
         row.governed_host == connection.governed_host and
         row.acquisition_method == connection.acquisition_method and
         row.execution_identity == connection.execution_identity and
         operation.bound_input_digest == Operation.callback_digest(row, attempt, connection) and
         row.handoff_ref == operation.handoff_ref and
         row.consume_correlation_id == attempt.correlation_id and
         row.lifecycle_status == "consumed" and is_binary(row.handoff_ciphertext) and
         is_nil(row.shredded_at),
       do: :ok,
       else: {:error, :credential_conflict}
  end

  defp validate_backend_connection_scope(row, connection) do
    if row.owner_uri == connection.owner_uri and
         row.workspace_uri == connection.workspace_uri and
         row.connection_id == connection.connection_id and
         row.connection_version == connection.connection_version and
         row.provider_id == connection.provider_id and
         row.governed_host == connection.governed_host and
         row.acquisition_method == connection.acquisition_method and
         row.execution_identity == connection.execution_identity,
       do: :ok,
       else: {:error, :credential_conflict}
  end

  defp connection_for_backend(row) do
    case Repo.get(Connection, row.connection_id) do
      %Connection{} = connection ->
        case validate_backend_connection_scope(row, connection) do
          :ok -> {:ok, connection}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :credential_conflict}
    end
  end

  defp validate_operation_fence(operation, attempt, connection) do
    if operation.workspace_uri == attempt.workspace_uri and
         operation.workspace_uri == connection.workspace_uri and
         operation.connection_id == attempt.connection_id and
         operation.connection_id == connection.connection_id and
         operation.backend_pair_id == attempt.backend_pair_id and
         operation.correlation_id == "store:#{attempt.correlation_id}" and
         operation.attempt_claim_token == attempt.claim_token and
         operation.attempt_version == attempt.attempt_version and
         operation.expected_connection_version == attempt.connection_version and
         operation.expected_connection_version == connection.connection_version and
         attempt.status == "consuming" do
      :ok
    else
      {:error, :credential_conflict}
    end
  end

  defp credential_command(operation, attempt, connection),
    do: %{
      correlation_id: operation.correlation_id,
      workspace_uri: operation.workspace_uri,
      owner_uri: connection.owner_uri,
      connection_id: operation.connection_id,
      connection_version: operation.expected_connection_version,
      backend_pair_id: operation.backend_pair_id,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      execution_identity: connection.execution_identity,
      attempt_ref: attempt.attempt_ref
    }

  defp decode_handoff_envelope(ciphertext) when is_binary(ciphertext) do
    {:ok, :erlang.binary_to_term(ciphertext, [:safe])}
  rescue
    _error -> {:error, :credential_conflict}
  end

  defp decode_handoff_envelope(_ciphertext), do: {:error, :credential_conflict}

  defp envelope(row),
    do: %{
      key_id: row.key_id,
      key_fingerprint: row.key_fingerprint,
      nonce: row.nonce,
      ciphertext: row.ciphertext
    }

  defp callback_envelope(row),
    do: %{
      key_id: row.callback_key_id,
      key_fingerprint: row.callback_key_fingerprint,
      nonce: row.callback_nonce,
      ciphertext: row.callback_ciphertext
    }

  defp callback_aad(row, correlation_id, digest),
    do: %{
      authorization_ref: row.authorization_ref,
      backend_pair_id: row.backend_pair_id,
      correlation_id: correlation_id,
      bound_input_digest: digest,
      expires_at: DateTime.to_iso8601(row.expires_at)
    }

  defp begin_result(row, redirect),
    do: %{
      authorization_ref: row.authorization_ref,
      redirect: redirect,
      expires_at: row.expires_at
    }

  defp command_digest(operation, request) do
    projected =
      case operation do
        :begin ->
          Map.take(
            request,
            ~w(subject acquisition_method requested_permissions_digest redirect_uri_id correlation_id)a
          )

        :consume ->
          request
          |> Map.take(~w(authorization_ref expected_subject correlation_id)a)
          |> Map.put(:callback_envelope_digest, secret_digest(request[:callback_envelope]))

        :cancel ->
          Map.take(request, ~w(authorization_ref expected_subject correlation_id)a)

        :reauthenticate ->
          request
          |> Map.take(~w(subject correlation_id)a)
          |> Map.put(
            :session_assurance_evidence_digest,
            secret_digest(request[:session_assurance_evidence])
          )
      end

    digest =
      {@digest_schema, operation, normalize(projected)}
      |> :erlang.term_to_binary([:deterministic])
      |> sha256()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  end

  defp closed_keys(request, allowed) do
    if MapSet.subset?(MapSet.new(Map.keys(request)), allowed),
      do: :ok,
      else: {:error, :callback_invalid}
  end

  defp secret_digest(value),
    do:
      value
      |> normalize()
      |> :erlang.term_to_binary([:deterministic])
      |> sha256()
      |> Base.encode16(case: :lower)

  defp normalize(%URI{} = uri), do: URI.to_string(uri)

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1) |> List.to_tuple()

  defp normalize(value), do: value

  defp encode_consume_result(result) do
    %{
      "external_account_id" => result.external_account_id,
      "display_login" => result.display_login,
      "execution_identity" => %{
        "kind" => Atom.to_string(result.execution_identity.kind),
        "external_account_id" => result.execution_identity.external_account_id
      },
      "handoff_ref" => elem(result.credential_material, 1),
      "granted_permissions_digest" => result.granted_permissions_digest,
      "provider_metadata" => result.provider_metadata
    }
  end

  defp decode_consume_result(result) do
    %{
      external_account_id: result["external_account_id"],
      display_login: result["display_login"],
      execution_identity: %{
        kind: execution_kind(result["execution_identity"]["kind"]),
        external_account_id: result["execution_identity"]["external_account_id"]
      },
      credential_material: {:write_only_handoff, result["handoff_ref"]},
      granted_permissions_digest: result["granted_permissions_digest"],
      provider_metadata: result["provider_metadata"] || %{}
    }
  end

  defp execution_kind("connected_user"), do: :connected_user
  defp execution_kind(_other), do: :connected_user

  defp decode_reauth_result(result) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(result["expires_at"])
    %{reauth_ref: result["reauth_ref"], expires_at: expires_at}
  end

  defp safe_error("authorization_backend_unavailable"), do: :authorization_backend_unavailable
  defp safe_error("correlation_conflict"), do: :correlation_conflict
  defp safe_error("invalid_authorization_subject"), do: :invalid_authorization_subject
  defp safe_error("invalid_acquisition_method"), do: :invalid_acquisition_method
  defp safe_error("governed_host_mismatch"), do: :governed_host_mismatch
  defp safe_error("state_mismatch"), do: :state_mismatch
  defp safe_error("pkce_mismatch"), do: :pkce_mismatch
  defp safe_error("callback_expired"), do: :callback_expired
  defp safe_error("callback_already_consumed"), do: :callback_already_consumed
  defp safe_error("callback_invalid"), do: :callback_invalid
  defp safe_error("external_account_mismatch"), do: :external_account_mismatch
  defp safe_error("reauthentication_required"), do: :reauthentication_required
  defp safe_error("reauthentication_failed"), do: :reauthentication_failed
  defp safe_error("authorization_cancelled"), do: :authorization_cancelled
  defp safe_error("provider_authorization_denied"), do: :provider_authorization_denied
  defp safe_error("provider_protocol_error"), do: :provider_protocol_error
  defp safe_error("stale_connection_version"), do: :stale_connection_version
  defp safe_error(_unknown), do: :authorization_backend_unavailable

  defp seal_with(snapshot, :active, purpose, value, aad),
    do: seal_with(snapshot, snapshot.active_key_id, purpose, value, aad)

  defp seal_with(snapshot, key_id, purpose, value, aad) do
    key = Map.fetch!(snapshot.keys, key_id)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = :erlang.term_to_binary(value, [:deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        encode_aad(purpose, aad),
        true
      )

    %{
      key_id: key_id,
      key_fingerprint: sha256(key),
      nonce: nonce,
      ciphertext: <<tag::binary, ciphertext::binary>>
    }
  end

  defp seal_with_record_key(snapshot, row, purpose, value, aad) do
    with {:ok, key} <- Map.fetch(snapshot.keys, row.key_id),
         true <- sha256(key) == row.key_fingerprint do
      {:ok, seal_with(snapshot, row.key_id, purpose, value, aad)}
    else
      _error -> {:error, :authentication_failed}
    end
  end

  defp unseal_with(
         snapshot,
         purpose,
         %{key_id: key_id, key_fingerprint: fingerprint, nonce: nonce, ciphertext: blob},
         aad
       )
       when is_binary(key_id) and is_binary(fingerprint) and is_binary(nonce) and
              byte_size(nonce) == 12 and is_binary(blob) and byte_size(blob) >= @tag_bytes do
    with {:ok, key} <- Map.fetch(snapshot.keys, key_id),
         true <- sha256(key) == fingerprint do
      <<tag::binary-size(@tag_bytes), ciphertext::binary>> = blob

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             encode_aad(purpose, aad),
             tag,
             false
           ) do
        :error -> {:error, :authentication_failed}
        plaintext -> {:ok, :erlang.binary_to_term(plaintext, [:safe])}
      end
    else
      _error -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  defp unseal_with(_snapshot, _purpose, _envelope, _aad),
    do: {:error, :authentication_failed}

  defp crypto_state do
    with {:ok, state} <- parse_crypto_config(),
         {:ok, validated} <- AuthorizationKeyRing.validated_fingerprint(),
         true <- crypto_fingerprint(state) == validated do
      {:ok, state}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  defp parse_crypto_config do
    config = Application.get_env(:ezagent_domain_provider_connection, AuthorizationKeyRing, [])

    with {:ok, pairs} <- crypto_pairs(Keyword.get(config, :source), config),
         {:ok, keys} <- crypto_keys(pairs),
         active when is_binary(active) <- Keyword.get(config, :active_key_id),
         true <- Regex.match?(@key_id_pattern, active),
         true <- Map.has_key?(keys, active) do
      {:ok, %{active_key_id: active, keys: keys}}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  if @fixture_enabled do
    defp crypto_pairs(:explicit_test, config) do
      case Keyword.get(config, :keys) do
        keys when is_map(keys) -> {:ok, Map.to_list(keys)}
        _other -> {:error, :invalid}
      end
    end
  end

  defp crypto_pairs(:runtime_env, config) do
    with json when is_binary(json) <- Keyword.get(config, :keys_json),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(json, objects: :ordered_objects) do
      Enum.reduce_while(pairs, {:ok, []}, fn {id, encoded}, {:ok, acc} ->
        case is_binary(encoded) && Base.decode64(encoded) do
          {:ok, key} -> {:cont, {:ok, [{id, key} | acc]}}
          _other -> {:halt, {:error, :invalid}}
        end
      end)
    else
      _error -> {:error, :invalid}
    end
  end

  defp crypto_pairs(_source, _config), do: {:error, :invalid}

  defp crypto_keys(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {id, key}, {:ok, acc} ->
      if is_binary(id) and Regex.match?(@key_id_pattern, id) and is_binary(key) and
           byte_size(key) == 32 and not Map.has_key?(acc, id) do
        {:cont, {:ok, Map.put(acc, id, key)}}
      else
        {:halt, {:error, :invalid}}
      end
    end)
  end

  defp crypto_fingerprint(%{active_key_id: active, keys: keys}) do
    key_digests = Map.new(keys, fn {id, key} -> {id, sha256(key)} end)
    sha256(:erlang.term_to_binary({active, key_digests}, [:deterministic]))
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

  defp portable_secret?(value)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: false

  defp portable_secret?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> portable_secret?(key) and portable_secret?(item) end)

  defp portable_secret?(value) when is_list(value), do: Enum.all?(value, &portable_secret?/1)

  defp portable_secret?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> portable_secret?()

  defp portable_secret?(_value), do: true

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp encode_aad(purpose, aad), do: :erlang.term_to_binary({purpose, aad}, [:deterministic])
  defp pkce_digest(verifier), do: verifier |> sha256() |> Base.url_encode64(padding: false)

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp stable_ref(prefix, left, right) do
    digest = sha256(:erlang.term_to_binary({prefix, left, right}, [:deterministic]))
    "#{prefix}:#{Base.url_encode64(digest, padding: false)}"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value)

  defp digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> sha256()
      |> Base.encode16(case: :lower)

  defp required_binary(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp unwrap_transaction({:ok, value}), do: value
  defp unwrap_transaction({:error, _reason}), do: {:error, :authorization_backend_unavailable}
end
