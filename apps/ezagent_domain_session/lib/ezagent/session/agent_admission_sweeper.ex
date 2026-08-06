defmodule Ezagent.Session.AgentAdmissionSweeper do
  @moduledoc "Expires credential-gated agent admissions whose login window elapsed."

  use GenServer

  require Logger

  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionReconciliation

  @default_interval :timer.seconds(1)

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec run_due(DateTime.t()) :: [{URI.t(), String.t(), {:ok, map()} | {:error, term()}}]
  def run_due(%DateTime{} = now \\ DateTime.utc_now()) do
    sessions = SessionCreator.list_sessions()
    run_due(now, sessions)
  end

  @impl GenServer
  def init(opts) do
    schedule(0)

    {:ok,
     %{
       interval: Keyword.get(opts, :interval, configured_interval()),
       now: Keyword.get(opts, :now, &DateTime.utc_now/0)
     }}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sessions = SessionCreator.list_sessions()

    state.now.()
    |> run_due(sessions)
    |> Enum.each(fn
      {_session_uri, _attempt_id, {:ok, _expired}} ->
        :ok

      {session_uri, attempt_id, {:error, reason}} ->
        Logger.error(
          "agent admission #{attempt_id} for #{URI.to_string(session_uri)} " <>
            "could not be expired: #{inspect(reason)}"
        )
    end)

    schedule(state.interval)
    {:noreply, state}
  end

  defp run_due(now, sessions), do: Enum.flat_map(sessions, &sweep_session(&1, now))

  defp sweep_session(session_uri, now) do
    log_reconciliation_result(session_uri, AgentAdmission.reconcile(session_uri))
    expired = expire_due(session_uri, now)
    reconcile_due(session_uri)
    expired
  end

  defp log_reconciliation_result(_session_uri, :ok), do: :ok

  defp log_reconciliation_result(session_uri, {:error, failures}) do
    Enum.each(failures, fn {role_name, attempt_id, reason} ->
      Logger.error(
        "active agent admission #{attempt_id} for #{URI.to_string(session_uri)} " <>
          "role #{role_name} could not be reconciled: #{inspect(reason)}"
      )
    end)
  end

  defp reconcile_due(session_uri) do
    session_uri
    |> AgentAdmission.list()
    |> Enum.filter(&reconciliation_due?/1)
    |> Enum.each(fn admission ->
      case AgentAdmissionReconciliation.revalidate_joined(session_uri, admission) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "joined agent admission #{admission.attempt_id} for #{URI.to_string(session_uri)} " <>
              "could not be revalidated: #{inspect(reason)}"
          )
      end
    end)
  rescue
    exception ->
      Logger.error(
        "agent admission reconciliation failed for #{URI.to_string(session_uri)}: " <>
          Exception.message(exception)
      )
  end

  defp reconciliation_due?(%{status: :joined}), do: true

  defp reconciliation_due?(%{
         status: :pending_auth,
         failure_code: :authentication_failed,
         provisional_agent_uri: agent_uri
       })
       when is_binary(agent_uri),
       do: true

  defp reconciliation_due?(_admission), do: false

  defp expire_due(session_uri, now) do
    session_uri
    |> AgentAdmission.list()
    |> Enum.filter(&due?(&1, now))
    |> Enum.map(fn admission ->
      {session_uri, admission.attempt_id,
       AgentAdmission.expire(session_uri, admission.attempt_id)}
    end)
  rescue
    exception ->
      Logger.error(
        "agent admission sweep failed for #{URI.to_string(session_uri)}: " <>
          Exception.message(exception)
      )

      []
  end

  defp due?(%{status: :authenticating, attempt_id: attempt_id, expires_at: expires_at}, now)
       when is_binary(attempt_id) and is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, deadline, _offset} -> DateTime.compare(deadline, now) in [:lt, :eq]
      {:error, _reason} -> false
    end
  end

  defp due?(_admission, _now), do: false

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp configured_interval do
    Application.get_env(
      :ezagent_domain_session,
      :agent_admission_sweep_interval_ms,
      @default_interval
    )
  end
end
