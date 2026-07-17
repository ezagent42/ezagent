defmodule Ezagent.Kind.Template.PreStart do
  @moduledoc """
  Registered generic gate for preparing transient template launch data.

  The implementation owns the opaque reference and completion claim. This
  module validates the returned working directory and wraps the implementation
  claim in a single-use token so completion can occur exactly once.
  """

  use GenServer

  @test_env Mix.env() == :test

  @callback prepare(reference :: term()) ::
              {:ok, %{required(:cwd) => String.t(), required(:claim) => term()}}
              | {:error, term()}
  @callback complete(claim :: term(), outcome :: term()) :: :ok | {:error, term()}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers the single downstream implementation idempotently."
  @spec register(module()) :: :ok | {:error, term()}
  def register(implementation), do: GenServer.call(__MODULE__, {:register, implementation})

  if @test_env do
    @doc false
    def replace_for_test(implementation),
      do: GenServer.call(__MODULE__, {:replace_for_test, implementation})
  end

  @doc "Prepares transient launch data and returns a single-use completion token."
  @spec prepare(term()) :: {:ok, %{cwd: String.t(), claim: reference()}} | {:error, term()}
  def prepare(reference) do
    with {:ok, implementation} <- GenServer.call(__MODULE__, :implementation),
         {:ok, %{cwd: cwd, claim: implementation_claim} = prepared}
         when is_binary(cwd) and cwd != "" <- invoke(implementation, :prepare, [reference]),
         token = make_ref(),
         :ok <-
           GenServer.call(
             __MODULE__,
             {:put_pending, token, implementation, implementation_claim, self()}
           ) do
      {:ok, prepared |> Map.put(:claim, token)}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_template_pre_start_result}
    end
  end

  @doc "Completes one prepared launch exactly once."
  @spec complete(term(), term()) :: :ok | {:error, term()}
  def complete(claim, outcome) when is_reference(claim) do
    case GenServer.call(__MODULE__, {:take_pending, claim}) do
      {:ok, {implementation, implementation_claim}} ->
        implementation
        |> invoke(:complete, [implementation_claim, outcome])
        |> normalize_complete()

      {:error, _reason} = error ->
        error
    end
  end

  def complete(_claim, _outcome), do: {:error, :invalid_template_pre_start_claim}

  @impl true
  def init(nil), do: {:ok, %{implementation: nil, pending: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, implementation}, _from, %{implementation: nil} = state) do
    case validate_implementation(implementation) do
      :ok -> {:reply, :ok, %{state | implementation: implementation}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:register, implementation}, _from, %{implementation: implementation} = state),
    do: {:reply, :ok, state}

  def handle_call({:register, _implementation}, _from, state),
    do: {:reply, {:error, :conflicting_template_pre_start}, state}

  if @test_env do
    def handle_call({:replace_for_test, nil}, _from, state) do
      {:reply, :ok, reset_pending(%{state | implementation: nil})}
    end

    def handle_call({:replace_for_test, implementation}, _from, state) do
      case validate_implementation(implementation) do
        :ok ->
          {:reply, :ok, reset_pending(%{state | implementation: implementation})}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(:implementation, _from, %{implementation: nil} = state),
    do: {:reply, {:error, :template_pre_start_not_registered}, state}

  def handle_call(:implementation, _from, state),
    do: {:reply, {:ok, state.implementation}, state}

  def handle_call(
        {:put_pending, token, implementation, implementation_claim, caller},
        _from,
        state
      ) do
    monitor = Process.monitor(caller)

    pending =
      Map.put(state.pending, token, %{
        implementation: implementation,
        claim: implementation_claim,
        monitor: monitor
      })

    monitors = Map.put(state.monitors, monitor, token)
    {:reply, :ok, %{state | pending: pending, monitors: monitors}}
  end

  def handle_call({:take_pending, claim}, _from, state) do
    case Map.pop(state.pending, claim) do
      {nil, _pending} ->
        {:reply, {:error, :invalid_template_pre_start_claim}, state}

      {%{implementation: implementation, claim: implementation_claim, monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        monitors = Map.delete(state.monitors, monitor)

        {:reply, {:ok, {implementation, implementation_claim}},
         %{state | pending: pending, monitors: monitors}}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {token, monitors} ->
        {:noreply, %{state | pending: Map.delete(state.pending, token), monitors: monitors}}
    end
  end

  defp validate_implementation(implementation) when is_atom(implementation) do
    with {:module, ^implementation} <- Code.ensure_loaded(implementation),
         true <- function_exported?(implementation, :prepare, 1),
         true <- function_exported?(implementation, :complete, 2) do
      :ok
    else
      _ -> {:error, :invalid_template_pre_start_implementation}
    end
  end

  defp validate_implementation(_implementation),
    do: {:error, :invalid_template_pre_start_implementation}

  defp invoke(implementation, function, arguments) do
    apply(implementation, function, arguments)
  rescue
    exception -> {:error, {:template_pre_start_callback_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:template_pre_start_callback_failed, kind, reason}}
  end

  defp normalize_complete(:ok), do: :ok
  defp normalize_complete({:error, _reason} = error), do: error
  defp normalize_complete(_other), do: {:error, :invalid_template_pre_start_complete_result}

  defp reset_pending(state) do
    Enum.each(state.monitors, fn {monitor, _token} -> Process.demonitor(monitor, [:flush]) end)
    %{state | pending: %{}, monitors: %{}}
  end
end
