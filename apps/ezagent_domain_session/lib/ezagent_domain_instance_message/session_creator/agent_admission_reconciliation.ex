defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionReconciliation do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionState
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @invalid_statuses [:expired, :missing]

  @doc false
  @spec reconcile_auth_failure(URI.t()) :: :ok | {:error, term()}
  def reconcile_auth_failure(%URI{scheme: "entity"} = agent_uri) do
    with {:ok, session_uris} <- EzagentDomainInstanceMessage.agent_live_sessions(agent_uri) do
      session_uris
      |> Enum.reduce([], fn session_uri, failures ->
        case reconcile_session(session_uri, agent_uri) do
          :ok -> failures
          {:error, reason} -> [{session_uri, reason} | failures]
        end
      end)
      |> reconciliation_result(agent_uri)
    end
  end

  def reconcile_auth_failure(_agent_uri), do: {:error, :invalid_agent_uri}

  @doc false
  @spec revalidate_joined(URI.t(), map()) :: :ok | {:error, term()}
  def revalidate_joined(%URI{} = session_uri, %{status: :joined} = admission) do
    with {:ok, admission} <- admission_with_provider(session_uri, admission),
         {:ok, owner_uri} <- Session.owner(session_uri),
         agent_uri when is_binary(agent_uri) <- field(admission, :provisional_agent_uri),
         {:ok, agent_uri} <- Ezagent.URI.parse(agent_uri),
         caps <-
           EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri),
         {:ok, credential_status} <-
           Ezagent.Domain.Agent.read_credential_status(
             agent_uri,
             actor_ctx(owner_uri, caps),
             backend_profile: field(admission, :provider)
           ) do
      if credential_status.status in @invalid_statuses,
        do: reconcile_session(session_uri, agent_uri),
        else: :ok
    else
      nil -> {:error, :missing_joined_agent_uri}
      {:error, _reason} = error -> error
      other -> {:error, {:joined_credential_revalidation_failed, other}}
    end
  end

  def revalidate_joined(
        %URI{} = session_uri,
        %{
          status: :pending_auth,
          failure_code: :authentication_failed,
          provisional_agent_uri: agent_uri
        }
      )
      when is_binary(agent_uri) do
    with {:ok, agent_uri} <- Ezagent.URI.parse(agent_uri) do
      reconcile_session(session_uri, agent_uri)
    end
  end

  def revalidate_joined(_session_uri, _admission), do: :ok

  defp admission_with_provider(session_uri, admission) do
    if field_present?(admission, :provider) do
      {:ok, admission}
    else
      AgentAdmissionState.with_lock(session_uri, fn ->
        working_copy = Session.read_template_working_copy(session_uri)
        role_name = field(admission, :role_name)

        with %{} = declaration <-
               Enum.find(
                 Map.get(working_copy, :member_declarations, []),
                 &(field(&1, :role_name) == role_name)
               ),
             %URI{} = revision_uri <- Map.get(working_copy, :session_template_uri) do
          with {:ok, current} <-
                 AgentAdmissionState.backfill_provider_under_lock(
                   session_uri,
                   admission,
                   declaration,
                   URI.to_string(revision_uri)
                 ),
               true <- field_present?(current, :provider) do
            {:ok, current}
          else
            false -> {:error, :stale_agent_admission_declaration}
            {:error, _reason} = error -> error
          end
        else
          nil -> {:error, :undeclared_agent_admission_role}
          _other -> {:error, :missing_session_template_revision}
        end
      end)
    end
  end

  defp reconcile_session(session_uri, agent_uri) do
    AgentAdmissionState.with_lock(session_uri, fn ->
      case joined_admission(session_uri, agent_uri) do
        nil ->
          :ok

        admission ->
          retire_joined_admission(session_uri, agent_uri, admission)
      end
    end)
  end

  defp retire_joined_admission(session_uri, agent_uri, admission) do
    reconciling =
      admission
      |> Map.put(:status, :pending_auth)
      |> Map.put(:expires_at, nil)
      |> Map.put(:failure_code, :authentication_failed)

    with :ok <- AgentAdmissionState.put_admission(session_uri, reconciling),
         {:ok, owner_uri} <- Session.owner(session_uri),
         attempt_id when is_binary(attempt_id) <- field(admission, :attempt_id),
         caps <-
           EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri),
         :ok <-
           DefinitionAgents.cleanup_provisional(
             session_uri,
             owner_uri,
             agent_uri,
             attempt_id,
             actor_ctx(owner_uri, caps),
             :credential_auth_failed
           ) do
      pending =
        reconciling
        |> Map.put(:attempt_id, nil)
        |> Map.put(:provisional_agent_uri, nil)

      AgentAdmissionState.put_admission(session_uri, pending)
    else
      nil -> {:error, :missing_agent_admission_attempt}
      {:error, _reason} = error -> error
      other -> {:error, {:joined_agent_reconciliation_failed, other}}
    end
  end

  defp joined_admission(session_uri, agent_uri) do
    agent_uri_string = URI.to_string(agent_uri)

    session_uri
    |> AgentAdmissionState.admissions()
    |> Map.values()
    |> Enum.find(fn admission ->
      (field(admission, :status) == :joined or
         (field(admission, :status) == :pending_auth and
            field(admission, :failure_code) == :authentication_failed)) and
        field(admission, :provisional_agent_uri) == agent_uri_string
    end)
  end

  defp actor_ctx(actor_uri, caps) do
    %{
      caller: actor_uri,
      authenticated_principal: actor_uri,
      caps: MapSet.new(caps)
    }
  end

  defp field_present?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp reconciliation_result([], _agent_uri), do: :ok

  defp reconciliation_result(failures, agent_uri) do
    {:error,
     {:agent_admission_reconciliation_failed, URI.to_string(agent_uri), Enum.reverse(failures)}}
  end
end
