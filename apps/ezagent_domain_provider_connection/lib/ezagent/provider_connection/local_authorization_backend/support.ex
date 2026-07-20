defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.Support do
  @moduledoc false

  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.Driver
  alias Ezagent.ProviderConnection.Operation

  @backend_id "local-authorization-v1"
  @digest_schema "provider-authorization-command-v1"

  @doc false
  def local_pair?(pair_id) do
    with {:ok, pair} <- BackendPairRegistry.lookup(pair_id),
         true <- pair.authorization_backend.id == @backend_id do
      :ok
    else
      _other -> {:error, :authorization_backend_unavailable}
    end
  end

  @doc false
  def command_attrs(row, operation, correlation, digest, authorization_ref),
    do:
      command_attrs(
        row.workspace_uri,
        row.backend_pair_id,
        operation,
        correlation,
        digest,
        authorization_ref
      )

  @doc false
  def command_attrs(workspace_uri, pair_id, operation, correlation, digest, authorization_ref) do
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

  @doc false
  def expected_subject(row, value) do
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

  @doc false
  def subject(
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

  def subject(_value), do: {:error, :invalid_authorization_subject}

  @doc false
  def acquisition_method(request) do
    required_binary(request, :acquisition_method, :invalid_acquisition_method)
  end

  @doc false
  def begin_aad(ref, pair, digest, subject, request, expires_at) do
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

  @doc false
  def row_aad(row) do
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

  @doc false
  def handoff_aad(row, correlation, handoff_ref),
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

  @doc false
  def validate_handoff(row, operation, attempt, connection) do
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
         row.execution_identity == connection_execution_identity(connection) and
         operation.bound_input_digest == Operation.callback_digest(row, attempt, connection) and
         row.handoff_ref == operation.handoff_ref and
         row.consume_correlation_id == attempt.correlation_id and
         row.lifecycle_status == "consumed" and is_binary(row.handoff_ciphertext) and
         is_nil(row.shredded_at),
       do: :ok,
       else: {:error, :credential_conflict}
  end

  @doc false
  def validate_backend_connection_scope(row, connection) do
    if row.owner_uri == connection.owner_uri and
         row.workspace_uri == connection.workspace_uri and
         row.connection_id == connection.connection_id and
         row.connection_version == connection.connection_version and
         row.provider_id == connection.provider_id and
         row.governed_host == connection.governed_host and
         row.acquisition_method == connection.acquisition_method and
         row.execution_identity == connection_execution_identity(connection),
       do: :ok,
       else: {:error, :credential_conflict}
  end

  defp connection_execution_identity(%{status: "pending_authorization"} = connection),
    do: connection.requested_execution_identity_class

  defp connection_execution_identity(connection), do: connection.execution_identity

  @doc false
  def validate_operation_fence(operation, attempt, connection) do
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

  @doc false
  def credential_command(operation, attempt, connection),
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

  @doc false
  def decode_handoff_envelope(ciphertext) when is_binary(ciphertext) do
    {:ok, :erlang.binary_to_term(ciphertext, [:safe])}
  rescue
    _error -> {:error, :credential_conflict}
  end

  @doc false
  def decode_handoff_envelope(_ciphertext), do: {:error, :credential_conflict}

  @doc false
  def envelope(row),
    do: %{
      key_id: row.key_id,
      key_fingerprint: row.key_fingerprint,
      nonce: row.nonce,
      ciphertext: row.ciphertext
    }

  @doc false
  def callback_envelope(row),
    do: %{
      key_id: row.callback_key_id,
      key_fingerprint: row.callback_key_fingerprint,
      nonce: row.callback_nonce,
      ciphertext: row.callback_ciphertext
    }

  @doc false
  def callback_aad(row, correlation_id, digest),
    do: %{
      authorization_ref: row.authorization_ref,
      backend_pair_id: row.backend_pair_id,
      correlation_id: correlation_id,
      bound_input_digest: digest,
      expires_at: DateTime.to_iso8601(row.expires_at)
    }

  @doc false
  def begin_result(row, redirect),
    do: %{
      authorization_ref: row.authorization_ref,
      redirect: redirect,
      expires_at: row.expires_at
    }

  @doc false
  def command_digest(operation, request) do
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

  @doc false
  def closed_keys(request, allowed) do
    if MapSet.subset?(MapSet.new(Map.keys(request)), allowed),
      do: :ok,
      else: {:error, :callback_invalid}
  end

  @doc false
  def secret_digest(value),
    do:
      value
      |> normalize()
      |> :erlang.term_to_binary([:deterministic])
      |> sha256()
      |> Base.encode16(case: :lower)

  @doc false
  def normalize(%URI{} = uri), do: URI.to_string(uri)

  @doc false
  def normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize(value)} end)

  @doc false
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  @doc false
  def normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1) |> List.to_tuple()

  @doc false
  def normalize(value), do: value

  @doc false
  def encode_consume_result(result) do
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

  @doc false
  def decode_consume_result(result) do
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

  @doc false
  def execution_kind("connected_user"), do: :connected_user
  @doc false
  def execution_kind(_other), do: :connected_user

  @doc false
  def decode_reauth_result(result) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(result["expires_at"])
    %{reauth_ref: result["reauth_ref"], expires_at: expires_at}
  end

  @doc false
  def safe_error("authorization_backend_unavailable"), do: :authorization_backend_unavailable
  @doc false
  def safe_error("correlation_conflict"), do: :correlation_conflict
  @doc false
  def safe_error("invalid_authorization_subject"), do: :invalid_authorization_subject
  @doc false
  def safe_error("invalid_acquisition_method"), do: :invalid_acquisition_method
  @doc false
  def safe_error("governed_host_mismatch"), do: :governed_host_mismatch
  @doc false
  def safe_error("state_mismatch"), do: :state_mismatch
  @doc false
  def safe_error("pkce_mismatch"), do: :pkce_mismatch
  @doc false
  def safe_error("callback_expired"), do: :callback_expired
  @doc false
  def safe_error("callback_already_consumed"), do: :callback_already_consumed
  @doc false
  def safe_error("callback_invalid"), do: :callback_invalid
  @doc false
  def safe_error("external_account_mismatch"), do: :external_account_mismatch
  @doc false
  def safe_error("reauthentication_required"), do: :reauthentication_required
  @doc false
  def safe_error("reauthentication_failed"), do: :reauthentication_failed
  @doc false
  def safe_error("authorization_cancelled"), do: :authorization_cancelled
  @doc false
  def safe_error("provider_authorization_denied"), do: :provider_authorization_denied
  @doc false
  def safe_error("provider_protocol_error"), do: :provider_protocol_error
  @doc false
  def safe_error("stale_connection_version"), do: :stale_connection_version
  @doc false
  def safe_error(_unknown), do: :authorization_backend_unavailable

  @doc false
  def portable_secret?(value)
      when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
      do: false

  @doc false
  def portable_secret?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> portable_secret?(key) and portable_secret?(item) end)

  @doc false
  def portable_secret?(value) when is_list(value), do: Enum.all?(value, &portable_secret?/1)

  @doc false
  def portable_secret?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> portable_secret?()

  @doc false
  def portable_secret?(_value), do: true

  @doc false
  def stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)

  @doc false
  def stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  @doc false
  def stringify_keys(value), do: value

  @doc false
  def field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @doc false
  def execution_identity(
        %{kind: :connected_user, external_account_id: external_account_id} = identity,
        external_account_id
      )
      when map_size(identity) == 2,
      do: :ok

  def execution_identity(_identity, _external_account_id),
    do: {:error, :provider_protocol_error}

  @doc false
  def external_account_binding(callback, external_account_id) do
    case field(callback, :external_account_id) do
      nil -> :ok
      ^external_account_id -> :ok
      _other -> {:error, :external_account_mismatch}
    end
  end

  @doc false
  def validate_callback(payload, callback, row) when is_map(callback) do
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

  def validate_callback(_payload, _callback, _row), do: {:error, :callback_invalid}

  @doc false
  def normalize_begin_result(%{redirect: redirect} = result, payload, driver)
      when map_size(result) == 1 and is_map(redirect) do
    with uri when is_binary(uri) and uri != "" <- field(redirect, :authorization_uri),
         true <- field(redirect, :state) == payload.state,
         true <- field(redirect, :pkce_digest) == pkce_digest(payload.pkce_verifier),
         true <- Driver.matches_schema?(redirect, driver.metadata.authorization_redirect_schema) do
      {:ok, stringify_keys(redirect)}
    else
      _other -> {:error, :provider_protocol_error}
    end
  end

  def normalize_begin_result(_result, _payload, _driver),
    do: {:error, :provider_protocol_error}

  @doc false
  def validate_consume_result(result, callback, driver) do
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
      {:ok, stringify_keys(result.provider_metadata)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :provider_protocol_error}
    end
  end

  @doc false
  def encode_aad(purpose, aad), do: :erlang.term_to_binary({purpose, aad}, [:deterministic])
  @doc false
  def pkce_digest(verifier), do: verifier |> sha256() |> Base.url_encode64(padding: false)

  @doc false
  def random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc false
  def stable_ref(prefix, left, right) do
    digest = sha256(:erlang.term_to_binary({prefix, left, right}, [:deterministic]))
    "#{prefix}:#{Base.url_encode64(digest, padding: false)}"
  end

  @doc false
  def sha256(value), do: :crypto.hash(:sha256, value)

  @doc false
  def digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> sha256()
      |> Base.encode16(case: :lower)

  @doc false
  def required_binary(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  @doc false
  def unwrap_transaction({:ok, value}), do: value
  @doc false
  def unwrap_transaction({:error, _reason}), do: {:error, :authorization_backend_unavailable}
end
