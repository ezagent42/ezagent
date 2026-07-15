defmodule Ezagent.Agent.RetirementSweeper do
  @moduledoc "Periodically retries durable Agent retirement cleanup obligations."

  use GenServer

  require Logger

  alias Ezagent.Agent.RetirementObligations

  @default_interval :timer.minutes(1)
  @default_batch_size 25

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec run_due(pos_integer()) :: [{pos_integer(), {:ok, :resolved} | {:error, term()}}]
  def run_due(limit \\ @default_batch_size) do
    limit
    |> RetirementObligations.list_due()
    |> Enum.map(fn obligation -> {obligation.id, retry(obligation.id)} end)
  end

  @spec retry(pos_integer()) :: {:ok, :resolved} | {:error, term()}
  def retry(id) do
    with {:ok, obligation} <- RetirementObligations.mark_running(id),
         :ok <- execute_steps(obligation),
         {:ok, _resolved} <- RetirementObligations.resolve(id) do
      {:ok, :resolved}
    else
      {:error, reason} ->
        _ = RetirementObligations.record_failure(id, reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = {:rescue, exception}
      _ = RetirementObligations.record_failure(id, reason)
      {:error, reason}
  catch
    kind, value ->
      reason = {kind, value}
      _ = RetirementObligations.record_failure(id, reason)
      {:error, reason}
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, configured_interval())
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    run_due()
    |> Enum.each(fn
      {_id, {:ok, :resolved}} ->
        :ok

      {id, {:error, reason}} ->
        Logger.warning("retirement obligation #{id} retry failed: #{inspect(reason)}")
    end)

    schedule(state.interval)
    {:noreply, state}
  end

  defp execute_steps(%{agent_uri: agent_uri, pending_steps: pending_steps}) do
    case pending_steps do
      %{
        "sandbox_cleanup" => %{
          "config_dir_path" => config_dir,
          "template_class" => template_class
        }
      } ->
        with {:ok, module} <- existing_module(template_class),
             true <- function_exported?(module, :destroy_config_dir, 2),
             :ok <- module.destroy_config_dir(URI.new!(agent_uri), config_dir) do
          :ok
        else
          false -> {:error, {:cleanup_callback_missing, template_class}}
          {:error, _reason} = error -> error
          other -> {:error, {:cleanup_failed, other}}
        end

      other ->
        {:error, {:unsupported_pending_steps, other}}
    end
  end

  defp existing_module("Elixir." <> _ = name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, {:cleanup_module_not_loaded, name}}
  end

  defp existing_module(name) when is_binary(name) do
    existing_module("Elixir." <> name)
  end

  defp existing_module(name), do: {:error, {:invalid_cleanup_module, name}}

  defp configured_interval do
    Application.get_env(:ezagent_domain_agent, :retirement_sweep_interval, @default_interval)
  end

  defp schedule(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end
end
