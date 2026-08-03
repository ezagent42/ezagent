defmodule Ezagent.Session.SocialwareInstallSweeper do
  @moduledoc "Retries durable Session socialware-install obligations."

  use GenServer

  require Logger

  alias Ezagent.Session.SocialwareInstallObligations
  alias EzagentDomainInstanceMessage.SessionCreator

  @default_interval :timer.seconds(1)
  @default_batch_size 25
  @install_telemetry [:ezagent, :session, :socialware_install]

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec run_due(pos_integer()) :: [{pos_integer(), {:ok, :resolved} | {:error, term()}}]
  def run_due(limit \\ @default_batch_size) do
    run_due(limit, [])
  end

  @doc false
  @spec run_due(pos_integer(), keyword()) ::
          [{pos_integer(), {:ok, :resolved} | {:error, term()}}]
  def run_due(limit, retry_opts) when is_integer(limit) and limit > 0 and is_list(retry_opts) do
    limit
    |> SocialwareInstallObligations.list_due()
    |> Enum.map(fn obligation -> {obligation.id, retry(obligation.id, retry_opts)} end)
  end

  @doc false
  @spec retry(pos_integer(), keyword()) :: {:ok, :resolved} | {:error, term()}
  def retry(id, opts \\ []) do
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)

    case SocialwareInstallObligations.claim(
           id,
           allow_failed: Keyword.get(opts, :operator, false),
           lease_seconds: lease_seconds
         ) do
      {:ok, :already_resolved} ->
        {:ok, :resolved}

      {:ok, obligation} ->
        install_fun =
          Keyword.get(
            opts,
            :install_fun,
            &SessionCreator.install_session_socialware/2
          )

        execute_claimed_safely(obligation, install_fun, lease_seconds)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, configured_interval())
    schedule(0)
    {:ok, %{interval: interval, retry_opts: Keyword.get(opts, :retry_opts, [])}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    run_due(@default_batch_size, state.retry_opts)
    |> Enum.each(fn
      {_id, {:ok, :resolved}} ->
        :ok

      {id, {:error, reason}} ->
        Logger.error(
          "session socialware-install obligation #{id} failed; retry state persisted: " <>
            inspect(reason)
        )
    end)

    schedule(state.interval)
    {:noreply, state}
  end

  defp execute_claimed_safely(obligation, install_fun, lease_seconds) do
    heartbeat = start_lease_heartbeat(obligation, lease_seconds)

    try do
      execute_claimed(obligation, install_fun)
    rescue
      exception ->
        reason = {:rescue, exception}
        persist_failure(obligation, reason)
    catch
      kind, value ->
        reason = {kind, value}
        persist_failure(obligation, reason)
    after
      stop_lease_heartbeat(heartbeat)
    end
  end

  defp start_lease_heartbeat(obligation, lease_seconds) do
    stop_ref = make_ref()
    interval_ms = max(div(lease_seconds * 1_000, 3), 100)

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          renew_lease_until_stopped(
            obligation.id,
            obligation.claim_token,
            lease_seconds,
            interval_ms,
            stop_ref
          )
        end,
        [:link, :monitor]
      )

    {pid, monitor_ref, stop_ref}
  end

  defp stop_lease_heartbeat({pid, monitor_ref, stop_ref}) do
    send(pid, {:stop, stop_ref})

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp renew_lease_until_stopped(id, claim_token, lease_seconds, interval_ms, stop_ref) do
    receive do
      {:stop, ^stop_ref} ->
        :ok
    after
      interval_ms ->
        case SocialwareInstallObligations.renew_claim(id, claim_token, lease_seconds) do
          {:ok, _obligation} ->
            renew_lease_until_stopped(id, claim_token, lease_seconds, interval_ms, stop_ref)

          {:error, :stale_claim} ->
            :ok
        end
    end
  end

  defp execute_claimed(obligation, install_fun) do
    session_uri = Ezagent.URI.new!(obligation.session_uri)
    workspace_uri = Ezagent.URI.new!(obligation.workspace_uri)
    actor_uri = obligation.actor_uri && Ezagent.URI.new!(obligation.actor_uri)

    case install_fun.(session_uri, {workspace_uri, actor_uri}) do
      {:ok, summary} ->
        case SocialwareInstallObligations.resolve(obligation.id, obligation.claim_token) do
          {:ok, _resolved} ->
            emit_success(session_uri, summary)
            {:ok, :resolved}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        persist_failure(obligation, reason, session_uri)

      {:error, reason, partial} when is_map(partial) ->
        _ =
          SessionCreator.record_unfilled_role_slots(
            session_uri,
            Map.get(partial, :skipped, [])
          )

        persist_failure(obligation, reason, session_uri)

      other ->
        persist_failure(obligation, {:unexpected_install_result, other}, session_uri)
    end
  end

  defp persist_failure(obligation, reason) do
    session_uri = Ezagent.URI.new!(obligation.session_uri)
    persist_failure(obligation, reason, session_uri)
  end

  defp persist_failure(obligation, reason, session_uri) do
    _ =
      SocialwareInstallObligations.record_failure(
        obligation.id,
        reason,
        obligation.claim_token
      )

    Logger.error(
      "session socialware install failed for #{URI.to_string(session_uri)}: " <>
        "#{inspect(reason)}; durable obligation #{obligation.id} will retry"
    )

    :telemetry.execute(
      @install_telemetry ++ [:failed],
      %{count: 1},
      %{session_uri: session_uri, obligation_id: obligation.id, reason: reason}
    )

    {:error, reason}
  end

  defp emit_success(session_uri, summary) do
    skipped = Map.get(summary, :skipped, [])
    event = if skipped == [], do: :ok, else: :partial

    :telemetry.execute(
      @install_telemetry ++ [event],
      %{count: 1},
      %{
        session_uri: session_uri,
        installed: Map.get(summary, :satisfied, []),
        skipped: skipped
      }
    )
  end

  defp configured_interval do
    Application.get_env(
      :ezagent_domain_session,
      :socialware_install_sweep_interval_ms,
      @default_interval
    )
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
