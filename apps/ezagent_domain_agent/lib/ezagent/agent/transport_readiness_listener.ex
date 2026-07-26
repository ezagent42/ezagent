defmodule Ezagent.Agent.TransportReadinessListener do
  @moduledoc """
  Bridges AgentBridge connect events and node-local durable-live-join edges to
  `Ezagent.Agent.TransportReadiness` so a bridge-backed agent's ReadyGate flips
  to `:ready` on the REAL transport-join event regardless of spawn ordering
  (#505). `LiveJoinRegistry.mark_joined/1` sends its edge directly to this
  process after committing the durable ETS row; it is not an inbound PubSub
  command path.

  `Ezagent.AgentBridge.Registry.bind/3` broadcasts `{:agent_bridge_connected,
  agent_uri, info}` on `Ezagent.AgentBridge.Registry.topic/0` whenever an agent's
  transport bridge channel JOINs end-to-end (PTY up → `claude` up → esr-bridge
  MCP connected → channel joined → bound). V5 use-side H3: the broadcast rides
  the sealed transport, so it arrives here as a
  `%EzagentActor.Signal{kind: :broadcast}` envelope. For a REGULAR (non-orchestrator) cc
  agent nothing marks `LiveJoinRegistry` (only the orchestrator MCP channel does),
  so this listener is what carries the regular-cc bind into readiness for the
  FRESH-spawn ordering — where the Agent Kind already announced `:ready` before
  `require_transport_join` armed the gate, so there is no `await_transport_or_fail`
  Task parked to observe the bind. `TransportReadiness.on_transport_joined/1` is a
  no-op for agents without an armed gate, so reacting to every bind is safe.
  """

  use GenServer

  alias Ezagent.Agent.TransportReadiness
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc false
  @spec arm_timeout(URI.t(), pos_integer(), reference()) :: :ok
  def arm_timeout(%URI{} = agent_uri, timeout_ms, generation)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_reference(generation) do
    case Process.whereis(__MODULE__) do
      nil ->
        # Defensive boot/test fallback. In the normal application tree this
        # listener is supervised before any plugin can arm transport readiness.
        {:ok, _pid} =
          Task.start(fn ->
            Process.sleep(timeout_ms)
            Ezagent.Agent.TransportReadiness.timeout_generation(agent_uri, generation)
          end)

        :ok

      _pid ->
        GenServer.cast(__MODULE__, {:arm_timeout, agent_uri, timeout_ms, generation})
    end
  end

  @doc false
  @spec cancel_timeout(URI.t(), reference() | :any) :: :ok
  def cancel_timeout(%URI{} = agent_uri, generation \\ :any) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:cancel_timeout, agent_uri, generation})
    end

    :ok
  end

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, BridgeRegistry.topic())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:live_joined, %URI{} = agent_uri}, state) do
    TransportReadiness.on_transport_joined(agent_uri)
    {:noreply, state}
  end

  def handle_cast({:arm_timeout, %URI{} = agent_uri, timeout_ms, generation}, state) do
    uri_str = URI.to_string(agent_uri)

    if TransportReadiness.generation_current?(agent_uri, generation) do
      state = cancel_current(state, uri_str)

      timer_ref =
        Process.send_after(self(), {:transport_join_timeout, agent_uri, generation}, timeout_ms)

      {:noreply, Map.put(state, uri_str, {generation, timer_ref})}
    else
      # Concurrent re-arm/clear won before this cast reached the listener. A
      # stale arm must not cancel the current generation's only failure timer.
      {:noreply, state}
    end
  end

  def handle_cast({:cancel_timeout, %URI{} = agent_uri, generation}, state) do
    uri_str = URI.to_string(agent_uri)

    state =
      case Map.get(state, uri_str) do
        {current_generation, _timer_ref}
        when generation == :any or generation == current_generation ->
          cancel_current(state, uri_str)

        _ ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %EzagentActor.Signal{
          kind: :broadcast,
          payload: {:agent_bridge_connected, %URI{} = agent_uri, _info}
        },
        state
      ) do
    TransportReadiness.on_transport_joined(agent_uri)
    {:noreply, state}
  end

  def handle_info({:transport_join_timeout, %URI{} = agent_uri, generation}, state) do
    uri_str = URI.to_string(agent_uri)

    case Map.get(state, uri_str) do
      {^generation, _timer_ref} ->
        TransportReadiness.timeout_generation(agent_uri, generation)
        {:noreply, Map.delete(state, uri_str)}

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cancel_current(state, uri_str) do
    case Map.pop(state, uri_str) do
      {{_generation, timer_ref}, state} ->
        _ = Process.cancel_timer(timer_ref, async: false, info: false)
        state

      {nil, state} ->
        state
    end
  end
end
