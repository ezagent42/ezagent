defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionState do
  @moduledoc false

  alias Ezagent.Entity.Session

  @working_copy_key :agent_admissions
  @telemetry_prefix [:ezagent, :session, :agent_admission]
  @default_authentication_timeout_ms :timer.minutes(15)
  @lock_namespace :"Elixir.EzagentDomainInstanceMessage.SessionCreator.AgentAdmission"

  @doc false
  @spec admissions(URI.t()) :: map()
  def admissions(session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.get(@working_copy_key, %{})
  end

  @doc false
  @spec put_admission(URI.t(), map()) :: :ok | {:error, term()}
  def put_admission(session_uri, admission) do
    next = Map.put(admissions(session_uri), admission.role_name, admission)
    write_admissions(session_uri, next)
  end

  @doc false
  @spec delete_admission(URI.t(), String.t()) :: :ok | {:error, term()}
  def delete_admission(session_uri, role_name) do
    next = Map.delete(admissions(session_uri), role_name)
    write_admissions(session_uri, next)
  end

  @doc false
  @spec backfill_provider_under_lock(URI.t(), map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def backfill_provider_under_lock(session_uri, admission, declaration, revision) do
    role_name = field(admission, :role_name)
    current = Map.get(admissions(session_uri), role_name)

    cond do
      current != admission ->
        {:error, :stale_agent_admission_revalidation}

      field_present?(current, :provider) ->
        {:ok, current}

      field(current, :flavor) != field(declaration, :flavor) or
          field(current, :template_revision) != revision ->
        {:ok, current}

      true ->
        backfilled = Map.put(current, :provider, field(declaration, :provider))

        with :ok <- put_admission(session_uri, backfilled), do: {:ok, backfilled}
    end
  end

  @doc false
  @spec with_lock(URI.t(), (-> result)) :: result when result: term()
  def with_lock(session_uri, fun) do
    lock_id = {{@lock_namespace, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      fun.()
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  @doc false
  @spec authentication_deadline() :: String.t()
  def authentication_deadline do
    timeout_ms =
      Application.get_env(
        :ezagent_domain_session,
        :agent_admission_authentication_timeout_ms,
        @default_authentication_timeout_ms
      )

    DateTime.utc_now()
    |> DateTime.add(timeout_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  @doc false
  @spec transition_ok(atom(), URI.t(), map()) :: :ok
  def transition_ok(event, session_uri, admission) do
    :telemetry.execute(
      @telemetry_prefix ++ [:transition, :ok],
      %{count: 1},
      %{
        event: event,
        session_uri: session_uri,
        role_name: admission.role_name,
        status: admission.status
      }
    )
  end

  @doc false
  @spec transition_failed(atom(), URI.t(), String.t(), term()) :: :ok
  def transition_failed(event, session_uri, role_name, reason) do
    :telemetry.execute(
      @telemetry_prefix ++ [:transition, :failed],
      %{count: 1},
      %{
        event: event,
        session_uri: session_uri,
        role_name: role_name,
        reason: sanitize_reason(reason)
      }
    )
  end

  defp write_admissions(session_uri, value) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(@working_copy_key, value)

    try do
      case Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:agent_admission_write_failed, reason}}
        other -> {:error, {:agent_admission_write_failed, other}}
      end
    catch
      kind, reason -> {:error, {:agent_admission_write_failed, {kind, reason}}}
    end
  end

  defp sanitize_reason(reason)
       when reason in [
              :authentication_failed,
              :connection_cancelled,
              :connection_timed_out,
              :stale_agent_admission_attempt,
              :stale_agent_admission_declaration,
              :undeclared_agent_admission_role,
              :role_does_not_require_agent_admission,
              :agent_admission_not_owner
            ],
       do: reason

  defp sanitize_reason(_reason), do: :transition_failed

  defp field_present?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
