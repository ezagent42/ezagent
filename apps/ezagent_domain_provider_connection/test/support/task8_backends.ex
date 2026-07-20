defmodule Ezagent.ProviderConnection.Test.Task8Driver do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.Driver

  @impl true
  def begin_authorization(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    exchange.(fn private_frame ->
      provider_result_ref = provider_result_ref(context, private_frame)
      :ok = remember_callback_result(context, provider_result_ref)

      {:ok,
       %{
         provider_result_ref: provider_result_ref,
         external_account_id: "task8-account",
         display_login: "task8-user",
         execution_identity: %{kind: :connected_user, external_account_id: "task8-account"},
         authorization_ref: context.authorization_ref,
         authorization_version: context.expected_authorization_version + 1,
         credential_material: "task8-callback-material",
         granted_permissions_digest: "task8-callback-permissions",
         expires_at: nil,
         provider_metadata: %{}
       }}
    end)
  end

  def consume_callback(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_callback(_context), do: {:ok, :not_completed}

  @impl true
  def refresh(context), do: effect(:refresh, context)

  @impl true
  def reconcile_refresh(context), do: effect(:reconcile_refresh, context)

  @impl true
  def discard_callback_result(context), do: discard_callback_result_effect(context)

  @impl true
  def discard_refresh_result(context), do: effect(:discard_refresh_result, context)

  @impl true
  def revoke(context), do: effect(:provider_revoke, context)

  def remember_callback_result(context, provider_result_ref)
      when is_map(context) and is_binary(provider_result_ref) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task8_effect_state)
    binding = Map.take(context, callback_discard_binding_keys())

    Agent.update(state, fn current ->
      put_in(current, [:provider_results, provider_result_ref], binding)
    end)
  end

  defp discard_callback_result_effect(context) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task8_effect_state)

    with :ok <-
           Ezagent.ProviderConnection.Driver.validate_discard_context(:callback, context) do
      {reply, barrier} =
        Agent.get_and_update(state, fn current ->
          expected = Map.get(current.provider_results, context.provider_result_ref)
          actual = Map.take(context, callback_discard_binding_keys())
          key = context.discard_idempotency_key
          digest = canonical_digest(context)

          cond do
            expected != actual ->
              {{{:error, :correlation_conflict}, nil}, current}

            Map.get(current.provider_discards, key) == digest ->
              {{:ok, nil}, current}

            Map.has_key?(current.provider_discards, key) or
                Map.has_key?(current.discarded_provider_results, context.provider_result_ref) ->
              {{{:error, :correlation_conflict}, nil}, current}

            true ->
              reply = Map.get(current.replies, :discard_callback_result, :ok)
              count = Map.get(current.counts, :discard_callback_result, 0) + 1

              calls =
                Map.update(current.calls, :discard_callback_result, [context], &[context | &1])

              next = %{
                current
                | counts: Map.put(current.counts, :discard_callback_result, count),
                  calls: calls
              }

              next =
                if reply == :ok or match?({:ok, _receipt}, reply) do
                  next
                  |> put_in([:provider_discards, key], digest)
                  |> put_in(
                    [:discarded_provider_results, context.provider_result_ref],
                    key
                  )
                else
                  next
                end

              {{reply, Map.get(current.barriers, :discard_callback_result)}, next}
          end
        end)

      maybe_barrier(barrier, :discard_callback_result, context)
      reply
    end
  end

  defp callback_discard_binding_keys do
    ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id expected_connection_version attempt_ref authorization_ref expected_authorization_version correlation_id command_digest expected_credential_version)a
  end

  defp provider_result_ref(context, private_frame) do
    {Map.drop(context, [:exchange]), Map.drop(private_frame, [:pkce_verifier])}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("task8-provider-result:" <> &1))
  end

  defp canonical_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

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

  defp default_reply(:reconcile_refresh, _context), do: {:ok, :not_completed}
  defp default_reply(:discard_callback_result, _context), do: :ok
  defp default_reply(:discard_refresh_result, _context), do: :ok

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
      canonical_digests: %{},
      provider_results: %{},
      provider_discards: %{},
      discarded_provider_results: %{}
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
          execution_identity: "connected_user_account_1",
          requested_execution_identity_class: "connected_user",
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

    attrs =
      if attrs.status == "pending_authorization" do
        Map.merge(attrs, %{
          external_account_id: nil,
          display_login: nil,
          execution_identity: nil,
          authorization_backend_ref: nil,
          credential_backend_ref: nil,
          backend_pair_id: nil,
          authorization_backend_id: nil,
          credential_backend_id: nil,
          permission_digest: nil,
          expires_at: nil
        })
      else
        attrs
      end

    attrs
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(
      connection_version: Map.get(attrs, :connection_version, 0),
      credential_version: Map.get(attrs, :credential_version, 0)
    )
    |> Repo.insert!()
  end

  def attempt(connection, overrides \\ %{}) do
    purpose =
      if connection.status == "pending_authorization", do: "initial_bind", else: "reauthorize"

    attrs =
      Map.merge(
        %{
          attempt_ref: Ecto.UUID.generate(),
          workspace_uri: connection.workspace_uri,
          backend_pair_id: "pair-task8-v1",
          authorization_ref: "authorization-#{System.unique_integer([:positive])}",
          connection_id: connection.connection_id,
          connection_version: connection.connection_version,
          purpose: purpose,
          reservation_digest: "reservation-#{System.unique_integer([:positive])}",
          requested_permission_digest: "permissions-v1",
          requested_execution_identity_class: "connected_user",
          redirect_uri_id: "task8-callback",
          callback_artifact_digest: "callback-artifact-digest",
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
