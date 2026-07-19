defmodule Ezagent.ProviderConnection.CallbackIngress do
  @moduledoc "Secret-minimizing callback transport boundary for provider authorization."

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    Connection,
    LocalAuthorizationBackend,
    Operation
  }

  alias EzagentCore.Repo

  @doc "Stages a raw callback privately, then dispatches only durable coordinates."
  @spec consume(String.t(), String.t(), map()) :: term()
  def consume(redirect_id, raw_state, provider_envelope)
      when is_binary(redirect_id) and is_binary(raw_state) and is_map(provider_envelope) do
    with {:ok, pair_id} <- registered_pair(redirect_id),
         {:ok, digest} <- LocalAuthorizationBackend.state_digest(raw_state),
         %AuthorizationAttempt{} = attempt <- resolve_attempt(pair_id, digest),
         %Connection{} = connection <- Repo.get(Connection, attempt.connection_id),
         true <- connection.workspace_uri == attempt.workspace_uri,
         :ok <- callback_source_status(connection.status),
         {:ok, owner} <- parse_owner(connection.owner_uri),
         %Ezagent.Capability{} = artifact <-
           Ezagent.Capability.from_map(attempt.callback_artifact),
         :ok <- validate_artifact(artifact, owner),
         cmd <- callback_command(owner, artifact, attempt),
         :ok <- stage_if_required(attempt, pair_id, raw_state, provider_envelope) do
      Ezagent.Router.dispatch(cmd)
    else
      reason -> reject(redirect_id, reason)
    end
  rescue
    _error -> reject(redirect_id, :exception)
  end

  def consume(_redirect_id, _raw_state, _provider_envelope), do: {:error, :callback_invalid}

  defp callback_command(owner, artifact, attempt) do
    owner
    |> Ezagent.Cmd.new(
      :consume_callback,
      %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
      %{
        caller: owner,
        caps: MapSet.new([artifact]),
        mode: :call,
        reply: :ignore
      }
    )
  end

  defp registered_pair(redirect_id) do
    :ezagent_domain_provider_connection
    |> Application.get_env(:callback_redirect_pairs, %{})
    |> Map.fetch(redirect_id)
    |> case do
      {:ok, pair_id} when is_binary(pair_id) -> {:ok, pair_id}
      _reason -> {:error, :callback_invalid}
    end
  end

  defp resolve_attempt(pair_id, digest) do
    Repo.one(
      from(attempt in AuthorizationAttempt,
        where: attempt.backend_pair_id == ^pair_id and attempt.state_digest == ^digest
      )
    )
  end

  defp parse_owner(owner_uri) do
    owner = Ezagent.URI.new!(owner_uri)

    if Ezagent.URI.scheme?(owner, :entity) and Ezagent.URI.type?(owner, :user),
      do: {:ok, owner},
      else: {:error, :callback_invalid}
  end

  defp validate_artifact(artifact, owner) do
    workspace = Ezagent.Capability.workspace_of(owner)

    with :ok <- Ezagent.Cap.validate_for_current_target(artifact, owner),
         true <- artifact.kind == :user,
         true <- artifact.behavior == Ezagent.ActionSet.ProviderConnection,
         true <- artifact.action == :consume_callback,
         true <- artifact.instance == Ezagent.URI.instance(owner),
         true <- artifact.workspace_uri == workspace,
         true <- artifact.grantee_uri == owner do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_artifact_coordinates}
    end
  end

  defp callback_source_status(status)
       when status in ["pending_authorization", "active", "refresh_required", "degraded"],
       do: :ok

  defp callback_source_status(_status), do: {:error, :connection_terminal}

  defp stage_if_required(attempt, pair_id, raw_state, provider_envelope) do
    case Repo.get_by(Operation,
           backend_pair_id: attempt.backend_pair_id,
           operation_class: "store",
           correlation_id: "store:#{attempt.correlation_id}"
         ) do
      %Operation{status: status}
      when status in ["prepared", "backend_committed", "cleanup_pending"] ->
        :ok

      nil ->
        LocalAuthorizationBackend.stage_callback(
          pair_id,
          attempt.authorization_ref,
          attempt.correlation_id,
          raw_state,
          provider_envelope
        )

      %Operation{} ->
        {:error, :callback_invalid}
    end
  end

  defp reject(redirect_id, reason) do
    :telemetry.execute(
      [:ezagent, :provider_connection, :callback_ingress, :rejected],
      %{count: 1},
      %{redirect_id: telemetry_redirect_id(redirect_id), reason: reason_class(reason)}
    )

    {:error, :callback_invalid}
  end

  defp telemetry_redirect_id(redirect_id) do
    redirects =
      Application.get_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{})

    if Map.has_key?(redirects, redirect_id), do: redirect_id, else: :unknown
  end

  defp reason_class({:error, reason}) when is_atom(reason), do: reason_class(reason)

  defp reason_class(reason)
       when reason in [
              :callback_invalid,
              :connection_terminal,
              :invalid_artifact_coordinates,
              :invalid_cap_signature,
              :wrong_grantee,
              :exception
            ],
       do: reason

  defp reason_class(nil), do: :coordinate_not_found
  defp reason_class(false), do: :coordinate_mismatch
  defp reason_class(_reason), do: :rejected
end
