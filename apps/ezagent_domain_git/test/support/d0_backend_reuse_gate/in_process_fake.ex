defmodule Ezagent.DomainGit.D0BackendReuseGate.InProcessFake do
  @moduledoc false

  use GenServer

  alias Ezagent.DomainGit.D0BackendReuseGate.{RemoteSeal, SensitiveCredential}

  @behaviour Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  @behaviour Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend

  @now ~U[2030-01-01 00:00:00Z]

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  def reset(server), do: GenServer.call(server, :reset)
  def advance_time(server, seconds), do: GenServer.call(server, {:advance_time, seconds})
  def authorization_count(server), do: GenServer.call(server, :authorization_count)
  def credential_store_count(server), do: GenServer.call(server, :credential_store_count)
  def provider_effect_count(server), do: GenServer.call(server, :provider_effect_count)
  def prepare_lease(request), do: GenServer.call(__MODULE__, {:prepare_lease, request})
  def record_provider_effect, do: GenServer.call(__MODULE__, :record_provider_effect)

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def begin_authorization(request),
    do: GenServer.call(__MODULE__, {:begin_authorization, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def consume_callback(request), do: GenServer.call(__MODULE__, {:consume_callback, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def reauthenticate(request), do: GenServer.call(__MODULE__, {:reauthenticate, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def cancel_authorization(request),
    do: GenServer.call(__MODULE__, {:cancel_authorization, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def store(request), do: GenServer.call(__MODULE__, {:store, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def replace(request), do: GenServer.call(__MODULE__, {:replace, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def status(request), do: GenServer.call(__MODULE__, {:status, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def lease_for_operation(request),
    do: GenServer.call(__MODULE__, {:lease_for_operation, request})

  def lease_for_operation_sealed(request),
    do: GenServer.call(__MODULE__, {:lease_for_operation_sealed, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def consume_lease(request), do: GenServer.call(__MODULE__, {:consume_lease, request})

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def revoke(request), do: GenServer.call(__MODULE__, {:revoke, request})

  @impl GenServer
  def init(:ok), do: {:ok, initial_state()}

  @impl GenServer
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  def handle_call({:advance_time, seconds}, _from, state)
      when is_integer(seconds) and seconds >= 0 do
    {:reply, :ok, %{state | now: DateTime.add(state.now, seconds, :second)}}
  end

  def handle_call(:authorization_count, _from, state),
    do: {:reply, map_size(state.authorizations), state}

  def handle_call(:credential_store_count, _from, state),
    do: {:reply, state.credential_store_count, state}

  def handle_call(:provider_effect_count, _from, state),
    do: {:reply, state.provider_effect_count, state}

  def handle_call(:record_provider_effect, _from, state) do
    {:reply, :ok, %{state | provider_effect_count: state.provider_effect_count + 1}}
  end

  def handle_call({:store, request}, _from, state) do
    if request.expected_absent == true and state.credentials == %{} do
      record = %{
        scope: request.scope,
        secret: request.credential_material,
        version: 1,
        status: :active,
        expires_at: nil
      }

      {:reply, {:ok, public_record("cred-1", record)},
       put_in(state.credentials["cred-1"], record)}
    else
      {:reply, {:error, :credential_store_failed}, state}
    end
  end

  def handle_call({:status, request}, _from, state) do
    with {:ok, record} <- fetch_credential(state, request.credential_ref),
         :ok <- validate_scope(record.scope, request.expected_scope) do
      {:reply,
       {:ok, %{status: record.status, version: record.version, expires_at: record.expires_at}},
       state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, request}, _from, state) do
    with {:ok, record} <- fetch_credential(state, request.credential_ref),
         :ok <- validate_scope(record.scope, request.expected_scope),
         :ok <- validate_version(record.version, request.expected_version),
         :ok <- validate_active(record.status) do
      updated = %{record | secret: request.credential_material, version: record.version + 1}

      {:reply, {:ok, public_record(request.credential_ref, updated)},
       put_in(state.credentials[request.credential_ref], updated)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lease_for_operation, request}, _from, state) do
    issue_lease(request, state, :sensitive)
  end

  def handle_call({:lease_for_operation_sealed, request}, _from, state) do
    issue_lease(request, state, :sealed)
  end

  def handle_call({:prepare_lease, request}, _from, state) do
    with {:ok, lease} <- fetch_lease(state, request.lease_id),
         :ok <- validate_scope(lease.scope, request.expected_scope),
         :ok <- validate_version(lease.version, request.expected_version),
         :ok <- validate_lease_time(lease, state.now),
         :ok <- validate_lease_available(lease.status) do
      {:reply, :ok, put_in(state.leases[request.lease_id].status, :in_use)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_lease, request}, _from, state) do
    with {:ok, lease} <- fetch_lease(state, request.lease_id),
         :ok <- validate_scope(lease.scope, request.expected_scope),
         :ok <- validate_version(lease.version, request.expected_version),
         :ok <- validate_lease_time(lease, state.now),
         :ok <- validate_lease_in_use(lease.status) do
      {:reply, :ok, put_in(state.leases[request.lease_id].status, :consumed)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke, request}, _from, state) do
    with {:ok, record} <- fetch_credential(state, request.credential_ref),
         :ok <- validate_scope(record.scope, request.expected_scope),
         :ok <- validate_version(record.version, request.expected_version) do
      updated = %{record | version: record.version + 1, status: :revoked}

      {:reply, {:ok, public_record(request.credential_ref, updated)},
       put_in(state.credentials[request.credential_ref], updated)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin_authorization, request}, _from, state) do
    with :ok <- validate_subject(request.subject),
         :ok <- validate_acquisition_method(request.acquisition_method) do
      authorization_ref = "auth_#{map_size(state.authorizations) + 1}"
      expires_at = DateTime.add(state.now, 300, :second)

      record = %{
        subject: request.subject,
        state: "state-1",
        pkce_digest: "pkce-digest-1",
        expires_at: expires_at,
        consumed?: false,
        cancelled?: false,
        result: nil
      }

      started = %{
        authorization_ref: authorization_ref,
        redirect: %{
          "authorization_uri" => "https://github.com/login/oauth/authorize",
          "state" => record.state,
          "pkce_digest" => record.pkce_digest
        },
        expires_at: expires_at
      }

      {:reply, {:ok, started}, put_in(state.authorizations[authorization_ref], record)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_callback, request}, _from, state) do
    case Map.fetch(state.authorizations, request.authorization_ref) do
      :error ->
        {:reply, {:error, :callback_invalid}, state}

      {:ok, record} ->
        consume_callback(record, request, state)
    end
  end

  def handle_call({:reauthenticate, request}, _from, state) do
    with :ok <- validate_subject(request.subject),
         %{aal: aal} when aal in [:aal2, :aal3] <- request.session_assurance_evidence do
      result = %{reauth_ref: "reauth-1", expires_at: DateTime.add(state.now, 120, :second)}
      {:reply, {:ok, result}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :reauthentication_failed}, state}
    end
  end

  def handle_call({:cancel_authorization, request}, _from, state) do
    case Map.fetch(state.authorizations, request.authorization_ref) do
      {:ok, %{subject: subject} = record} when subject == request.expected_subject ->
        updated = %{record | cancelled?: true}
        {:reply, :ok, put_in(state.authorizations[request.authorization_ref], updated)}

      _ ->
        {:reply, {:error, :invalid_authorization_subject}, state}
    end
  end

  defp issue_lease(request, state, response_kind) when response_kind in [:sensitive, :sealed] do
    with {:ok, record} <- fetch_credential(state, request.credential_ref),
         :ok <- validate_scope(record.scope, request.expected_scope),
         :ok <- validate_version(record.version, request.expected_version),
         :ok <- validate_active(record.status),
         :ok <- validate_operation_grant(request) do
      lease_id = "lease-#{map_size(state.leases) + 1}"
      expires_at = DateTime.add(state.now, 30, :second)

      lease_record = %{
        scope: record.scope,
        version: record.version,
        expires_at: expires_at,
        status: :available
      }

      lease = %{
        lease_id: lease_id,
        expires_at: expires_at,
        observed_version: record.version
      }

      lease =
        case response_kind do
          :sensitive -> Map.put(lease, :sensitive, %SensitiveCredential{value: record.secret})
          :sealed -> Map.put(lease, :sealed_credential, RemoteSeal.seal(record.secret))
        end

      {:reply, {:ok, lease}, put_in(state.leases[lease_id], lease_record)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp consume_callback(record, request, state) do
    envelope = request.callback_envelope

    cond do
      record.subject != request.expected_subject ->
        {:reply, {:error, :invalid_authorization_subject}, state}

      record.cancelled? ->
        {:reply, {:error, :authorization_cancelled}, state}

      record.consumed? ->
        {:reply, {:error, :callback_already_consumed}, state}

      DateTime.compare(record.expires_at, state.now) != :gt ->
        {:reply, {:error, :callback_expired}, state}

      field(envelope, :acquisition_origin) == :social_login ->
        {:reply, {:error, :callback_invalid}, state}

      field(envelope, :state) != record.state ->
        {:reply, {:error, :state_mismatch}, state}

      field(envelope, :pkce_digest) != record.pkce_digest ->
        {:reply, {:error, :pkce_mismatch}, state}

      field(envelope, :governed_host) != record.subject.governed_host ->
        {:reply, {:error, :governed_host_mismatch}, state}

      field(envelope, :external_account_id) != "github-user-42" ->
        {:reply, {:error, :external_account_mismatch}, state}

      true ->
        result = %{
          external_account_id: "github-user-42",
          display_login: "alice-gh",
          execution_identity: %{kind: :connected_user, external_account_id: "github-user-42"},
          credential_material: {:write_only_handoff, "handoff-1"},
          granted_permissions_digest: "permissions-digest-1",
          provider_metadata: %{"account_kind" => "user"}
        }

        updated = %{record | consumed?: true, result: result}
        {:reply, {:ok, result}, put_in(state.authorizations[request.authorization_ref], updated)}
    end
  end

  defp validate_subject(%{
         owner_uri: %URI{} = owner_uri,
         workspace_uri: %URI{} = workspace_uri,
         provider_id: provider_id,
         governed_host: governed_host,
         connection_id: connection_id,
         connection_version: version
       })
       when is_integer(version) and version >= 0 do
    with true <- Ezagent.URI.scheme?(owner_uri, :entity),
         true <- Ezagent.URI.type?(owner_uri, :user),
         {:ok, owner_name} <- Ezagent.URI.name(owner_uri),
         {:ok, owner_workspace} <- Ezagent.URI.workspace_name(owner_uri),
         {:ok, subject_workspace} <- Ezagent.URI.workspace_name(workspace_uri),
         true <- owner_workspace == subject_workspace,
         true <- workspace_uri == Ezagent.URI.workspace(subject_workspace),
         true <- owner_uri == Ezagent.URI.user(owner_workspace, owner_name),
         true <-
           Enum.all?(
             [owner_workspace, owner_name, provider_id, governed_host, connection_id],
             &nonempty?/1
           ) do
      :ok
    else
      _ -> {:error, :invalid_authorization_subject}
    end
  end

  defp validate_subject(_subject), do: {:error, :invalid_authorization_subject}

  defp validate_acquisition_method("oauth_user"), do: :ok
  defp validate_acquisition_method(_method), do: {:error, :invalid_acquisition_method}

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp fetch_credential(state, credential_ref) do
    case Map.fetch(state.credentials, credential_ref) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :credential_not_found}
    end
  end

  defp fetch_lease(state, lease_id) do
    case Map.fetch(state.leases, lease_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, :lease_not_found}
    end
  end

  defp validate_scope(actual, expected) do
    cond do
      actual.governed_host != expected.governed_host -> {:error, :credential_host_mismatch}
      actual != expected -> {:error, :credential_scope_mismatch}
      true -> :ok
    end
  end

  defp validate_version(actual, expected) when actual == expected, do: :ok
  defp validate_version(_actual, _expected), do: {:error, :credential_version_conflict}

  defp validate_active(:active), do: :ok
  defp validate_active(:revoked), do: {:error, :credential_revoked}

  defp validate_operation_grant(%{operation_grant: nil}),
    do: {:error, :operation_grant_missing}

  defp validate_operation_grant(%{operation_grant: grant} = request) when is_map(grant) do
    expected = %{
      receiver: :provider_adapter,
      credential_ref: request.credential_ref,
      expected_scope: request.expected_scope,
      expected_version: request.expected_version,
      operation_class: request.operation_class
    }

    cond do
      map_size(grant) == 0 ->
        {:error, :operation_grant_invalid}

      Map.get(grant, :receiver) != :provider_adapter ->
        {:error, :operation_grant_invalid}

      Map.get(grant, :operation_class) != request.operation_class ->
        {:error, :operation_not_permitted}

      grant != expected ->
        {:error, :operation_grant_invalid}

      true ->
        :ok
    end
  end

  defp validate_operation_grant(_request), do: {:error, :operation_grant_invalid}

  defp validate_lease_time(lease, now) do
    if DateTime.compare(lease.expires_at, now) == :gt, do: :ok, else: {:error, :lease_expired}
  end

  defp validate_lease_available(:available), do: :ok
  defp validate_lease_available(_status), do: {:error, :lease_already_consumed}
  defp validate_lease_in_use(:in_use), do: :ok
  defp validate_lease_in_use(_status), do: {:error, :lease_already_consumed}

  defp public_record(ref, record),
    do: %{credential_ref: ref, version: record.version, status: record.status}

  defp initial_state do
    %{
      authorizations: %{},
      credentials: %{},
      leases: %{},
      now: @now,
      credential_store_count: 0,
      provider_effect_count: 0
    }
  end
end
