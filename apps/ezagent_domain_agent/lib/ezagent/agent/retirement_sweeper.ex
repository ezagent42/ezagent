defmodule Ezagent.Agent.RetirementSweeper do
  @moduledoc "Periodically retries durable Agent retirement cleanup obligations."

  use GenServer

  require Logger

  alias Ezagent.Agent.RetirementObligations
  alias Ezagent.Invocation

  @default_interval :timer.minutes(1)
  @default_batch_size 25

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec run_due(pos_integer()) :: [{pos_integer(), {:ok, :resolved} | {:error, term()}}]
  def run_due(limit \\ @default_batch_size) do
    limit
    |> RetirementObligations.list_due()
    |> Enum.map(fn obligation -> {obligation.id, retry(obligation.id)} end)
  end

  @doc false
  @spec retry(pos_integer(), keyword()) :: {:ok, :resolved} | {:error, term()}
  def retry(id, opts \\ []) do
    case RetirementObligations.claim(id, allow_failed: Keyword.get(opts, :operator, false)) do
      {:ok, :already_resolved} ->
        {:ok, :resolved}

      {:ok, obligation} ->
        execute_claimed_safely(obligation)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_claimed_safely(obligation) do
    execute_claimed(obligation)
  rescue
    exception ->
      reason = {:rescue, exception}
      _ = RetirementObligations.record_failure(obligation.id, reason, obligation.claim_token)
      {:error, reason}
  catch
    kind, value ->
      reason = {kind, value}
      _ = RetirementObligations.record_failure(obligation.id, reason, obligation.claim_token)
      {:error, reason}
  end

  defp execute_claimed(obligation) do
    with :ok <- execute_steps(obligation),
         {:ok, _resolved} <-
           RetirementObligations.resolve(obligation.id, obligation.claim_token) do
      {:ok, :resolved}
    else
      {:error, reason} ->
        _ = RetirementObligations.record_failure(obligation.id, reason, obligation.claim_token)
        {:error, reason}
    end
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
    with :ok <- execute_termination(agent_uri, pending_steps),
         :ok <- execute_cleanup(agent_uri, pending_steps) do
      :ok
    end
  end

  defp execute_termination(agent_uri, %{
         "sandbox_destroy" => %{"caller_uri" => caller_uri}
       }) do
    target = Ezagent.URI.new!(agent_uri)
    caller = Ezagent.URI.new!(caller_uri)

    case Ezagent.KindRegistry.lookup(target) do
      {:ok, _pid} ->
        action_target = Ezagent.URI.with_action(target, :sandbox, :destroy)
        admin = Ezagent.Entity.User.admin_uri()

        with {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, caller, action_target) do
          Invocation.dispatch(%Invocation{
            target: action_target,
            mode: :call,
            args: %{},
            ctx: %{
              caller: caller,
              authenticated_principal: caller,
              caps: MapSet.new([cap]),
              reply: {:caller_inbox, self()}
            },
            origin: :trusted_internal
          })
          |> normalize_termination_result()
        else
          {:error, reason} -> {:error, {:termination_retry_failed, reason}}
        end

      :error ->
        :ok
    end
  end

  defp execute_termination(_agent_uri, _pending_steps), do: :ok

  defp normalize_termination_result({:ok, %{destroyed: true}}), do: :ok
  defp normalize_termination_result({:error, :no_such_actor}), do: :ok

  defp normalize_termination_result({:error, reason}),
    do: {:error, {:termination_retry_failed, reason}}

  defp normalize_termination_result(other),
    do: {:error, {:unexpected_termination_retry_result, other}}

  defp execute_cleanup(agent_uri, pending_steps) do
    case pending_steps do
      %{
        "sandbox_cleanup" => %{
          "config_dir_path" => config_dir,
          "template_class" => template_class
        }
      } ->
        with {:ok, module} <- existing_module(template_class),
             true <- function_exported?(module, :destroy_config_dir, 2),
             :ok <- module.destroy_config_dir(Ezagent.URI.new!(agent_uri), config_dir) do
          :ok
        else
          false -> {:error, {:cleanup_callback_missing, template_class}}
          {:error, _reason} = error -> error
          other -> {:error, {:cleanup_failed, other}}
        end

      %{"sandbox_destroy" => _} ->
        :ok

      %{} = steps when map_size(steps) == 0 ->
        :ok

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
