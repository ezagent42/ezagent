defmodule Ezagent.DomainGit.D0BackendReuseGate.InProcessFake do
  @moduledoc false

  use GenServer

  @behaviour Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  @behaviour Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend

  @now ~U[2030-01-01 00:00:00Z]

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  def reset(server), do: GenServer.call(server, :reset)
  def advance_time(server, seconds), do: GenServer.call(server, {:advance_time, seconds})
  def authorization_count(server), do: GenServer.call(server, :authorization_count)
  def credential_store_count(server), do: GenServer.call(server, :credential_store_count)
  def provider_effect_count(server), do: GenServer.call(server, :provider_effect_count)

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
  def store(_request), do: {:error, :credential_backend_unavailable}

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def replace(_request), do: {:error, :credential_backend_unavailable}

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def status(_request), do: {:error, :credential_backend_unavailable}

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def lease_for_operation(_request), do: {:error, :credential_backend_unavailable}

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def consume_lease(_request), do: {:error, :credential_backend_unavailable}

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def revoke(_request), do: {:error, :credential_backend_unavailable}

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
         owner_uri: %URI{
           scheme: "entity",
           host: workspace,
           path: "/user/" <> owner_name,
           query: nil,
           fragment: nil
         },
         workspace_uri: %URI{
           scheme: "workspace",
           host: workspace,
           path: path,
           query: nil,
           fragment: nil
         },
         provider_id: provider_id,
         governed_host: governed_host,
         connection_id: connection_id,
         connection_version: version
       })
       when is_integer(version) and version >= 0 do
    if path in [nil, ""] and
         Enum.all?(
           [workspace, owner_name, provider_id, governed_host, connection_id],
           &nonempty?/1
         ),
       do: :ok,
       else: {:error, :invalid_authorization_subject}
  end

  defp validate_subject(_subject), do: {:error, :invalid_authorization_subject}

  defp validate_acquisition_method("oauth_user"), do: :ok
  defp validate_acquisition_method(_method), do: {:error, :invalid_acquisition_method}

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp initial_state do
    %{
      authorizations: %{},
      credentials: %{},
      now: @now,
      credential_store_count: 0,
      provider_effect_count: 0
    }
  end
end
