defmodule Ezagent.Agent.TransportReadinessTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.{LiveJoinRegistry, TransportReadiness}
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  setup do
    uri = Ezagent.URI.new!("entity://system/agent/bridge-ready-#{System.unique_integer([:positive])}")

    LiveJoinRegistry.init()
    :ok = LiveJoinRegistry.clear(uri)
    :ok = TransportReadiness.clear(uri)
    :ok = Ezagent.ReadyGate.put(uri, :unknown)

    on_exit(fn ->
      :ok = LiveJoinRegistry.clear(uri)
      :ok = TransportReadiness.clear(uri)
      :ok = Ezagent.ReadyGate.put(uri, :unknown)
    end)

    %{uri: uri}
  end

  test "bridge-backed agents defer ReadyGate readiness until their transport joins", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 1_000)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    assert {:defer, 1_000} = TransportReadiness.defer_ready?(uri)
    refute LiveJoinRegistry.joined?(uri)

    waiter =
      Task.async(fn ->
        TransportReadiness.await_transport_or_fail(uri)
      end)

    Process.sleep(20)
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    :ok = LiveJoinRegistry.mark_joined(uri)

    assert :ok = Task.await(waiter, 1_000)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "bridge-backed agent readiness wait times out to failed", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    assert {:error, :timeout} = TransportReadiness.await_transport_or_fail(uri)
    assert Ezagent.ReadyGate.status(uri) == :failed
  end

  # #505 regression — a REGULAR (non-orchestrator) cc agent's chat transport
  # bridge binds in AgentBridge.Registry but NOTHING marks LiveJoinRegistry
  # (only the orchestrator MCP channel does). Pre-fix, that left the gate
  # deferring until timeout -> :failed even though the PTY/claude/bridge came
  # up fine. The fix resolves readiness on the actual bridge-bind event.
  test "a live AgentBridge.Registry binding satisfies readiness without a LiveJoinRegistry mark",
       %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 1_000)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    # Neither signal yet -> defer.
    assert {:defer, 1_000} = TransportReadiness.defer_ready?(uri)
    refute LiveJoinRegistry.joined?(uri)

    # The chat bridge channel joins -> BridgeRegistry.bind (no LiveJoinRegistry).
    bridge = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :kill)
      BridgeRegistry.unbind(uri)
    end)

    :ok = BridgeRegistry.bind(uri, bridge, %{})

    assert :ready = TransportReadiness.defer_ready?(uri)
    assert :ok = TransportReadiness.await_transport_or_fail(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  # The bind can land WHILE the await loop is parked (cold spawn: gate armed,
  # then claude boots ~seconds later and the bridge joins) — the poll must pick
  # it up and flip to :ready, not time out.
  test "await resolves to :ready when the chat bridge binds during the wait", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 2_000)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    bridge = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :kill)
      BridgeRegistry.unbind(uri)
    end)

    waiter = Task.async(fn -> TransportReadiness.await_transport_or_fail(uri) end)

    Process.sleep(50)
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    :ok = BridgeRegistry.bind(uri, bridge, %{})

    assert :ok = Task.await(waiter, 2_000)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  # A STALE row from a dead channel incarnation must NOT satisfy readiness.
  test "a dead AgentBridge.Registry binding does not satisfy readiness", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 40)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    :ok = BridgeRegistry.bind(uri, dead, %{})
    on_exit(fn -> BridgeRegistry.unbind(uri) end)

    assert {:defer, 40} = TransportReadiness.defer_ready?(uri)
    assert {:error, :timeout} = TransportReadiness.await_transport_or_fail(uri)
    assert Ezagent.ReadyGate.status(uri) == :failed
  end

  # #505 FRESH-spawn ordering — the Kind announced :ready BEFORE the gate was
  # armed (spawn_for_local_pty starts the Kind, then require_transport_join sets
  # :not_ready), so NO await Task is parked. The bridge-bind EVENT must still flip
  # the gate. (`on_transport_joined/1` is what TransportReadinessListener calls.)
  test "on_transport_joined flips an armed :not_ready gate to :ready", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)
    # No await Task running — mirrors the fresh-spawn ordering.
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    :ok = TransportReadiness.on_transport_joined(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "on_transport_joined is a no-op for an agent with no armed gate", %{uri: uri} do
    # No require_transport_join -> not a transport-gated agent.
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)
    :ok = TransportReadiness.on_transport_joined(uri)
    # Untouched (the listener must not mark arbitrary agents ready).
    assert Ezagent.ReadyGate.status(uri) == :not_ready
  end

  # End-to-end: the live TransportReadinessListener (running in the app tree)
  # observes the real AgentBridge connect broadcast and flips the gate, even with
  # no await Task and no LiveJoinRegistry mark.
  test "TransportReadinessListener flips the gate on the real bridge-connect broadcast",
       %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    bridge = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :kill)
      BridgeRegistry.unbind(uri)
    end)

    # bind/3 broadcasts {:agent_bridge_connected, uri, info} on Registry.topic().
    :ok = BridgeRegistry.bind(uri, bridge, %{bridge_flavor: "cc"})

    # The listener reacts asynchronously; poll briefly.
    assert eventually(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false
  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
