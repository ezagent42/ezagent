defmodule Ezagent.Agent.TransportReadinessListener do
  @moduledoc """
  Bridges AgentBridge connect events to `Ezagent.Agent.TransportReadiness` so a
  bridge-backed agent's ReadyGate flips to `:ready` on the REAL transport-join
  event regardless of spawn ordering (#505).

  `Ezagent.AgentBridge.Registry.bind/3` broadcasts `{:agent_bridge_connected,
  agent_uri, info}` on `Ezagent.AgentBridge.Registry.topic/0` whenever an agent's
  transport bridge channel JOINs end-to-end (PTY up → `claude` up → esr-bridge
  MCP connected → channel joined → bound). For a REGULAR (non-orchestrator) cc
  agent nothing marks `LiveJoinRegistry` (only the orchestrator MCP channel does),
  so this listener is what carries the regular-cc bind into readiness for the
  FRESH-spawn ordering — where the Agent Kind already announced `:ready` before
  `require_transport_join` armed the gate, so there is no `await_transport_or_fail`
  Task parked to observe the bind. `TransportReadiness.on_transport_joined/1` is a
  no-op for agents without an armed gate, so reacting to every bind is safe.
  """

  use GenServer

  require Logger

  alias Ezagent.Agent.TransportReadiness
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, BridgeRegistry.topic())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:agent_bridge_connected, %URI{} = agent_uri, _info}, state) do
    TransportReadiness.on_transport_joined(agent_uri)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
