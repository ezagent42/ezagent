defmodule Ezagent.ProviderConnection.RegistryReadiness do
  @moduledoc false

  use GenServer

  @kinds [:driver, :backend_pair]
  @subscriber_tag {__MODULE__, :subscriber}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def subscribe(pid \\ self()) do
    :ok = register_subscriber(pid)
    GenServer.call(__MODULE__, :generations)
  end

  @doc false
  def ready(kind, pid) when kind in @kinds and is_pid(pid),
    do: GenServer.call(__MODULE__, {:ready, kind, pid})

  @impl true
  def init(_opts) do
    {:ok,
     %{
       registries: %{driver: {nil, 0}, backend_pair: {nil, 0}},
       registry_refs: %{}
     }}
  end

  @impl true
  def handle_call(:generations, _from, state) do
    {:reply, {:ok, generations(state)}, state}
  end

  def handle_call({:ready, kind, pid}, _from, state) do
    {old_pid, _generation} = Map.fetch!(state.registries, kind)
    state = demonitor_registry(state, old_pid)
    ref = Process.monitor(pid)
    generation = System.unique_integer([:monotonic, :positive])

    state = %{
      state
      | registries: Map.put(state.registries, kind, {pid, generation}),
        registry_refs: Map.put(state.registry_refs, ref, {kind, pid})
    }

    notify_subscribers_if_complete(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.registry_refs, ref) do
      {{kind, ^pid}, registry_refs} ->
        {_old_pid, generation} = Map.fetch!(state.registries, kind)

        {:noreply,
         %{
           state
           | registries: Map.put(state.registries, kind, {nil, generation}),
             registry_refs: registry_refs
         }}

      {nil, _registry_refs} ->
        {:noreply, state}
    end
  end

  defp notify_subscribers_if_complete(state) do
    if Enum.all?(state.registries, fn {kind, {pid, _generation}} ->
         live_registry?(kind, pid)
       end) do
      Enum.each(subscribers(), fn subscriber ->
        Enum.each(state.registries, fn {kind, {pid, generation}} ->
          send(subscriber, {:provider_registry_ready, kind, pid, generation})
        end)
      end)
    end
  end

  defp register_subscriber(pid) do
    name = {@subscriber_tag, pid}

    case :global.register_name(name, pid) do
      :yes -> :ok
      :no -> if :global.whereis_name(name) == pid, do: :ok, else: {:error, :name_conflict}
    end
  end

  defp subscribers do
    :global.registered_names()
    |> Enum.filter(&match?({@subscriber_tag, _pid}, &1))
    |> Enum.map(&:global.whereis_name/1)
    |> Enum.filter(&is_pid/1)
  end

  defp live_registry?(:driver, pid),
    do:
      is_pid(pid) and Process.alive?(pid) and
        Process.whereis(Ezagent.ProviderConnection.DriverRegistry) == pid

  defp live_registry?(:backend_pair, pid),
    do:
      is_pid(pid) and Process.alive?(pid) and
        Process.whereis(Ezagent.ProviderConnection.BackendPairRegistry) == pid

  defp generations(state) do
    Map.new(state.registries, fn {kind, {_pid, generation}} -> {kind, generation} end)
  end

  defp demonitor_registry(state, nil), do: state

  defp demonitor_registry(state, pid) do
    case Enum.find(state.registry_refs, fn {_ref, {_kind, registered_pid}} ->
           registered_pid == pid
         end) do
      {ref, _entry} ->
        Process.demonitor(ref, [:flush])
        %{state | registry_refs: Map.delete(state.registry_refs, ref)}

      nil ->
        state
    end
  end
end
