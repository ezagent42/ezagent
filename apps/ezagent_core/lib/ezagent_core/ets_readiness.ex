defmodule EzagentCore.EtsReadiness do
  @moduledoc false

  use GenServer

  @type state :: %{
          owner_pid: pid() | nil,
          owner_ref: reference() | nil,
          generation: non_neg_integer(),
          subscribers: %{pid() => reference()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc false
  @spec subscribe(pid()) :: {:ok, pid() | nil, non_neg_integer()}
  def subscribe(pid \\ self()) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc false
  @spec ready(pid()) :: :ok
  def ready(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:ready, pid})

  @impl true
  def init(_) do
    {:ok, %{owner_pid: nil, owner_ref: nil, generation: 0, subscribers: %{}}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        put_in(state.subscribers[pid], Process.monitor(pid))
      end

    {:reply, {:ok, state.owner_pid, state.generation}, state}
  end

  def handle_call({:ready, pid}, _from, state) do
    state = state |> replace_owner_monitor(pid) |> Map.update!(:generation, &(&1 + 1))

    Enum.each(
      Map.keys(state.subscribers),
      &send(&1, {:ets_owner_ready, pid, state.generation})
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:noreply, %{state | owner_pid: nil, owner_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.fetch(state.subscribers, pid) do
        {:ok, ^ref} -> Map.delete(state.subscribers, pid)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp replace_owner_monitor(%{owner_pid: pid} = state, pid), do: state

  defp replace_owner_monitor(state, pid) do
    demonitor(state.owner_ref)
    %{state | owner_pid: pid, owner_ref: Process.monitor(pid)}
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])
end
