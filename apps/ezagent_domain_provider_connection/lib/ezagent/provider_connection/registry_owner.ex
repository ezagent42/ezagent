defmodule Ezagent.ProviderConnection.RegistryOwner do
  @moduledoc false

  use GenServer

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.User

  @retry_ms 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ok = EzagentCore.EtsOwner.subscribe_lifecycle()

    case reconcile() do
      {:ok, _acquired} -> {:ok, monitor_owner(ProviderConnection.actions())}
      {:error, reason, owned} -> rollback(owned) && {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    rollback(state.owned)
    :ok
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    send(self(), :reconcile)
    {:noreply, %{state | owner_pid: nil, owner_ref: nil, owned: []}}
  end

  def handle_info(:reconcile, state) do
    case Process.whereis(EzagentCore.EtsOwner) do
      nil ->
        Process.send_after(self(), :reconcile, @retry_ms)
        {:noreply, state}

      owner ->
        case reconcile() do
          {:ok, _acquired} ->
            {:noreply, monitor_owner(ProviderConnection.actions(), owner)}

          {:error, reason, owned} ->
            rollback(owned) && {:stop, reason, state}
        end
    end
  end

  def handle_info(:ets_owner_recreated, state) do
    send(self(), :reconcile)
    {:noreply, %{state | owned: []}}
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

  defp monitor_owner(owned, owner \\ Process.whereis(EzagentCore.EtsOwner)) do
    %{owned: owned, owner_pid: owner, owner_ref: Process.monitor(owner)}
  end

  defp rollback(actions) do
    Enum.each(actions, fn action ->
      CapabilityRegistry.unregister(User, action, ProviderConnection)
    end)

    true
  end
end
