defmodule Ezagent.ProviderConnection.RegistryOwner do
  @moduledoc false

  use GenServer

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.User

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def await_generation(generation) when is_integer(generation) and generation >= 0 do
    GenServer.call(__MODULE__, {:await_generation, generation}, :infinity)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, owner, generation} = EzagentCore.EtsReadiness.subscribe()

    case reconcile() do
      {:ok, _acquired} ->
        state = %{
          owned: ProviderConnection.actions(),
          owner_pid: nil,
          owner_ref: nil,
          generation: generation,
          waiters: []
        }

        {:ok, monitor_owner(state, owner)}

      {:error, reason, owned} ->
        rollback(owned) && {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    demonitor(state.owner_ref)
    rollback(state.owned)
    :ok
  end

  @impl true
  def handle_call({:await_generation, generation}, _from, state)
      when state.generation >= generation do
    {:reply, :ok, state}
  end

  def handle_call({:await_generation, generation}, from, state) do
    {:noreply, %{state | waiters: [{generation, from} | state.waiters]}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:noreply, %{state | owner_pid: nil, owner_ref: nil, owned: []}}
  end

  def handle_info({:ets_owner_ready, owner, generation}, state) do
    case reconcile() do
      {:ok, _acquired} ->
        state =
          state
          |> Map.put(:owned, ProviderConnection.actions())
          |> Map.put(:generation, generation)
          |> monitor_owner(owner)
          |> reply_ready_waiters()

        {:noreply, state}

      {:error, reason, owned} ->
        rollback(owned) && {:stop, reason, state}
    end
  end

  defp reconcile do
    Enum.reduce_while(ProviderConnection.actions(), {:ok, []}, fn action, {:ok, owned} ->
      case CapabilityRegistry.register_owned(User, action, ProviderConnection) do
        :existing_identical -> {:cont, {:ok, owned}}
        :acquired -> {:cont, {:ok, [action | owned]}}
        {:error, reason} -> {:halt, {:error, reason, owned}}
      end
    end)
  rescue
    ArgumentError -> {:error, :registry_not_ready, []}
  end

  defp monitor_owner(%{owner_pid: owner} = state, owner), do: state

  defp monitor_owner(state, owner) when is_pid(owner) do
    demonitor(state.owner_ref)
    %{state | owner_pid: owner, owner_ref: Process.monitor(owner)}
  end

  defp monitor_owner(state, nil), do: state

  defp rollback(actions) do
    Enum.each(actions, fn action ->
      safe_unregister(action)
    end)

    true
  end

  defp safe_unregister(action) do
    CapabilityRegistry.unregister(User, action, ProviderConnection)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp reply_ready_waiters(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {generation, _from} ->
        generation <= state.generation
      end)

    Enum.each(ready, fn {_generation, from} -> GenServer.reply(from, :ok) end)
    %{state | waiters: waiting}
  end
end
