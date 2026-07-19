defmodule Ezagent.ProviderConnection.Test.Task8Driver do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.Driver

  @impl true
  def begin_authorization(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def consume_callback(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_callback(_context), do: {:ok, :not_completed}

  @impl true
  def refresh(context), do: effect(:refresh, context)

  @impl true
  def revoke(context), do: effect(:provider_revoke, context)

  defp effect(kind, context) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task8_effect_state)

    {reply, barrier} =
      Agent.get_and_update(state, fn current ->
        count = Map.get(current.counts, kind, 0) + 1
        reply = Map.get(current.replies, kind, default_reply(kind, context))
        barrier = Map.get(current.barriers, kind)
        next = put_in(current, [:counts, kind], count)
        {{reply, barrier}, next}
      end)

    maybe_barrier(barrier, kind, context)
    reply
  end

  defp default_reply(:refresh, _context) do
    {:ok,
     %{
       credential_material: "task8-rotated-material",
       permission_digest: "permissions-v2",
       expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
     }}
  end

  defp default_reply(:provider_revoke, _context), do: {:ok, %{provider_request_id: "req-1"}}

  defp maybe_barrier(nil, _kind, _context), do: :ok

  defp maybe_barrier(owner, kind, context) when is_pid(owner) do
    send(owner, {:task8_barrier, kind, self(), context})

    receive do
      {:release_task8, ^kind} -> :ok
    end
  end
end

defmodule Ezagent.ProviderConnection.Test.Task8CredentialBackend do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @impl true
  def store(_command), do: {:error, :credential_conflict}

  @impl true
  def replace(command), do: effect(:replace, command)

  @impl true
  def status(command), do: {:ok, command}

  @impl true
  def lease_for_operation(command), do: {:ok, command}

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def revoke(command), do: effect(:credential_revoke, command)

  defp effect(kind, command) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task8_effect_state)

    {reply, barrier} =
      Agent.get_and_update(state, fn current ->
        count = Map.get(current.counts, kind, 0) + 1
        calls = Map.update(current.calls, kind, [command], &[command | &1])

        reply = reconcile_reply(kind, command, current)

        next = %{current | counts: Map.put(current.counts, kind, count), calls: calls}
        next = maybe_remember_result(next, kind, command, reply)
        {{reply, Map.get(current.barriers, kind)}, next}
      end)

    maybe_barrier(barrier, kind, command)
    reply
  end

  defp default_reply(:replace, command, current) do
    case Map.fetch(current.results, command.correlation_id) do
      {:ok, result} ->
        {:ok, result}

      :error ->
        {:ok,
         %{
           credential_ref: "credential-ref-#{map_size(current.results) + 1}",
           credential_version: command.expected_credential_version + 1
         }}
    end
  end

  defp default_reply(:credential_revoke, _command, _current), do: :ok

  defp reconcile_reply(kind, command, current) do
    existing_digest = Map.get(current.canonical_digests, command.correlation_id)

    cond do
      kind == :replace and is_binary(existing_digest) and
          existing_digest != canonical_digest(command) ->
        {:error, :correlation_conflict}

      configured = Map.get(current.replies, kind) ->
        configured

      true ->
        default_reply(kind, command, current)
    end
  end

  defp maybe_remember_result(state, :replace, command, {:ok, result}) do
    state
    |> put_in([:results, command.correlation_id], result)
    |> put_in([:canonical_digests, command.correlation_id], canonical_digest(command))
  end

  defp maybe_remember_result(state, _kind, _command, _reply), do: state

  defp canonical_digest(command) do
    command
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp maybe_barrier(nil, _kind, _command), do: :ok

  defp maybe_barrier(owner, kind, command) when is_pid(owner) do
    send(owner, {:task8_barrier, kind, self(), command})

    receive do
      {:release_task8, ^kind} -> :ok
    end
  end
end

defmodule Ezagent.ProviderConnection.Test.Task8Fixtures do
  @moduledoc false

  alias Ezagent.ProviderConnection.{AuthorizationAttempt, BackendPair, Connection, Driver}
  alias Ezagent.ProviderConnection.Test.{Task8CredentialBackend, Task8Driver}
  alias EzagentCore.Repo

  def owner, do: Ezagent.URI.user("acme", "alice")

  def effect_state,
    do: %{
      counts: %{},
      calls: %{},
      replies: %{},
      barriers: %{},
      results: %{},
      canonical_digests: %{}
    }

  def pair do
    BackendPair.new!(%{
      pair_id: "pair-task8-v1",
      authorization_backend: %{
        id: "local-authorization-v1",
        fingerprint: "local-authorization-contract-v1"
      },
      credential_backend: %{
        id: "credential-task8-v1",
        fingerprint: "credential-task8-contract-v1"
      }
    })
  end

  def driver do
    Driver.new!(%{
      provider_id: "task8-provider",
      acquisition_method: "oauth_user",
      provider_fingerprint: "task8-driver-v1",
      implementation: Task8Driver,
      backend_pair_ids: ["pair-task8-v1"],
      metadata: %{
        authorization_redirect_schema: %{type: :map, fields: %{}},
        provider_metadata_schema: %{type: :map, fields: %{}}
      }
    })
  end

  def credential_implementations, do: %{"credential-task8-v1" => Task8CredentialBackend}

  def connection(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          connection_id: Ecto.UUID.generate(),
          workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
          owner_uri: URI.to_string(owner()),
          provider_id: "task8-provider",
          governed_host: "git.example",
          external_account_id: "account-#{System.unique_integer([:positive])}",
          display_login: "alice",
          execution_identity: "connected_user:account-1",
          acquisition_method: "oauth_user",
          authorization_backend_ref: "authorization-ref",
          credential_backend_ref: "credential-ref-old",
          backend_pair_id: "pair-task8-v1",
          authorization_backend_id: "local-authorization-v1",
          credential_backend_id: "credential-task8-v1",
          status: "active"
        },
        overrides
      )

    attrs
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(
      connection_version: Map.get(attrs, :connection_version, 0),
      credential_version: Map.get(attrs, :credential_version, 0)
    )
    |> Repo.insert!()
  end

  def attempt(connection, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          attempt_ref: Ecto.UUID.generate(),
          workspace_uri: connection.workspace_uri,
          backend_pair_id: "pair-task8-v1",
          authorization_ref: "authorization-#{System.unique_integer([:positive])}",
          connection_id: connection.connection_id,
          connection_version: connection.connection_version,
          bound_subject_digest: "subject-digest",
          state_digest: "state-#{System.unique_integer([:positive])}",
          correlation_id: "callback-#{System.unique_integer([:positive])}",
          status: "consumed",
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        },
        overrides
      )

    attrs
    |> AuthorizationAttempt.create_changeset()
    |> Ecto.Changeset.change(
      attempt_version: Map.get(attrs, :attempt_version, 0),
      claim_token: Map.get(attrs, :claim_token),
      claim_until: Map.get(attrs, :claim_until),
      consumed_at: Map.get(attrs, :consumed_at)
    )
    |> Repo.insert!()
  end
end
