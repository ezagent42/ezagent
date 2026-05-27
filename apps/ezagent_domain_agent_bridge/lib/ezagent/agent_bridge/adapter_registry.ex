defmodule Ezagent.AgentBridge.AdapterRegistry do
  @moduledoc """
  Runtime registry of agent bridge adapters keyed by agent flavor.
  """

  use GenServer

  require Logger

  alias Ezagent.AgentBridge.Payload

  @pending_ttl_ms 5_000
  @max_pending_per_flavor 100

  @type flavor :: String.t()
  @type adapter :: module()

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{adapters: %{}, pending: %{}}, name: __MODULE__)
  end

  @spec register(flavor(), adapter()) :: :ok | {:error, term()}
  def register(flavor, adapter) when is_binary(flavor) and is_atom(adapter) do
    with :ok <- validate_adapter(flavor, adapter) do
      GenServer.call(__MODULE__, {:register, flavor, adapter})
    end
  end

  @spec lookup(flavor()) :: {:ok, adapter()} | :error
  def lookup(flavor) when is_binary(flavor) do
    GenServer.call(__MODULE__, {:lookup, flavor})
  end

  @spec deliver_or_buffer(flavor(), Payload.t(), pid()) :: :ok | {:error, term()}
  def deliver_or_buffer(flavor, %Payload{} = payload, channel_pid)
      when is_binary(flavor) and is_pid(channel_pid) do
    GenServer.call(__MODULE__, {:deliver_or_buffer, flavor, payload, channel_pid})
  end

  @spec list_all() :: [{flavor(), adapter()}]
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:register, flavor, adapter}, _from, %{adapters: adapters} = state) do
    case Map.fetch(adapters, flavor) do
      {:ok, ^adapter} ->
        {:reply, :ok, state}

      {:ok, existing} ->
        {:reply, {:error, {:already_registered, existing}}, state}

      :error ->
        state =
          state
          |> put_in([:adapters, flavor], adapter)
          |> drain_pending(flavor, adapter)

        {:reply, :ok, state}
    end
  end

  def handle_call({:lookup, flavor}, _from, %{adapters: adapters} = state) do
    {:reply, Map.fetch(adapters, flavor), state}
  end

  def handle_call({:deliver_or_buffer, flavor, payload, channel_pid}, _from, state) do
    case Map.fetch(state.adapters, flavor) do
      {:ok, adapter} ->
        {:reply, adapter.deliver(payload, channel_pid), state}

      :error ->
        {state, entry} = buffer_pending(state, flavor, payload, channel_pid)
        Process.send_after(self(), {:expire_pending, flavor, entry.id}, @pending_ttl_ms)
        {:reply, :ok, state}
    end
  end

  def handle_call(:list_all, _from, %{adapters: adapters} = state) do
    {:reply, Map.to_list(adapters), state}
  end

  @impl GenServer
  def handle_info({:expire_pending, flavor, id}, state) do
    {expired, state} = pop_pending(state, flavor, id)

    if expired do
      emit_pending_drop(flavor, expired.payload, :adapter_registration_timeout)
    end

    {:noreply, state}
  end

  defp validate_adapter(flavor, adapter) do
    cond do
      not Code.ensure_loaded?(adapter) ->
        {:error, {:adapter_not_loaded, adapter}}

      not implements_adapter?(adapter) ->
        {:error, {:invalid_adapter, adapter}}

      adapter.flavor() != flavor ->
        {:error, {:flavor_mismatch, adapter.flavor(), flavor}}

      true ->
        :ok
    end
  end

  defp implements_adapter?(adapter) do
    behaviours = adapter.module_info(:attributes) |> Keyword.get(:behaviour, [])
    Ezagent.AgentBridge.Adapter in behaviours
  end

  defp buffer_pending(state, flavor, payload, channel_pid) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      payload: payload,
      channel_pid: channel_pid
    }

    existing = Map.get(state.pending, flavor, [])
    {kept, dropped} = [entry | existing] |> Enum.split(@max_pending_per_flavor)

    Enum.each(dropped, fn old ->
      emit_pending_drop(flavor, old.payload, :adapter_pending_queue_full)
    end)

    {put_in(state, [:pending, flavor], kept), entry}
  end

  defp drain_pending(state, flavor, adapter) do
    pending = Map.get(state.pending, flavor, [])

    Enum.each(Enum.reverse(pending), fn %{payload: payload, channel_pid: channel_pid} ->
      case adapter.deliver(payload, channel_pid) do
        :ok -> :ok
        {:error, reason} -> emit_pending_drop(flavor, payload, reason)
      end
    end)

    update_in(state.pending, &Map.delete(&1, flavor))
  end

  defp pop_pending(state, flavor, id) do
    pending = Map.get(state.pending, flavor, [])
    {matched, remaining} = Enum.split_with(pending, &(&1.id == id))

    expired =
      case matched do
        [entry | _] -> entry
        [] -> nil
      end

    state =
      if remaining == [] do
        update_in(state.pending, &Map.delete(&1, flavor))
      else
        put_in(state, [:pending, flavor], remaining)
      end

    {expired, state}
  end

  defp emit_pending_drop(flavor, %Payload{} = payload, reason) do
    Logger.warning(
      "AgentBridge pending deliver dropped for flavor #{inspect(flavor)}: #{inspect(reason)}. " <>
        "Message from #{URI.to_string(payload.sender_uri)}: " <>
        String.slice(payload.text || "", 0, 80)
    )

    :telemetry.execute(
      [:ezagent, :agent_bridge, :deliver, :dropped],
      %{count: 1},
      %{
        flavor: flavor,
        sender: payload.sender_uri,
        event_type: payload.event_type,
        reason: reason
      }
    )
  end
end
