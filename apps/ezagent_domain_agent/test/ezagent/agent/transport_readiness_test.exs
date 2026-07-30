defmodule Ezagent.Agent.TransportReadinessTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.{LiveJoinRegistry, TransportReadiness}
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  setup do
    uri =
      Ezagent.URI.new!("entity://system/agent/bridge-ready-#{System.unique_integer([:positive])}")

    LiveJoinRegistry.init()
    :ok = LiveJoinRegistry.clear(uri)
    :ok = BridgeRegistry.unbind(uri)
    :ok = TransportReadiness.clear(uri)
    :ok = Ezagent.ReadyGate.put(uri, :unknown)

    on_exit(fn ->
      :ok = LiveJoinRegistry.clear(uri)
      :ok = BridgeRegistry.unbind(uri)
      :ok = TransportReadiness.clear(uri)
      :ok = Ezagent.ReadyGate.put(uri, :unknown)
    end)

    %{uri: uri}
  end

  test "arming an unjoined transport leaves a ready Kind ready", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 1_000)

    assert Ezagent.ReadyGate.status(uri) == :ready
    refute TransportReadiness.transport_joined?(uri)
    assert :ready = TransportReadiness.defer_ready?(uri)
  end

  test "an unjoined transport timeout clears its record without failing a ready Kind", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30)

    assert :ok = TransportReadiness.await_transport_or_fail(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
    assert transport_records(uri) == []
  end

  test "an AgentBridge binding clears the matching transport record without changing readiness",
       %{
         uri: uri
       } do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 1_000)

    bridge = start_bridge(uri)
    on_exit(fn -> stop_bridge(uri, bridge) end)

    :ok = BridgeRegistry.bind(uri, bridge, %{})

    assert eventually(fn -> transport_records(uri) == [] end)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "an orchestrator live join clears the matching transport record", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 1_000)
    :ok = LiveJoinRegistry.mark_joined(uri)

    assert eventually(fn -> transport_records(uri) == [] end)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a dead bridge binding does not satisfy transport status", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000
    :ok = BridgeRegistry.bind(uri, dead, %{})

    assert :ok = TransportReadiness.await_transport_or_fail(uri)
    refute TransportReadiness.transport_joined?(uri)
    assert transport_records(uri) == []
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "an already-live transport clears its record while it is armed", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = LiveJoinRegistry.mark_joined(uri)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)

    assert transport_records(uri) == []
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a stale queued join event leaves an unjoined record armed", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)

    true = :ets.insert(LiveJoinRegistry.table(), {URI.to_string(uri), true})
    :ok = LiveJoinRegistry.clear(uri)

    assert :ok = TransportReadiness.on_transport_joined(uri)
    assert [_record] = transport_records(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a stale timeout generation cannot clear a re-armed transport record", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    first_generation = current_generation(uri)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    second_generation = current_generation(uri)

    refute first_generation == second_generation
    :ok = TransportReadiness.timeout_generation(uri, first_generation)

    assert TransportReadiness.generation_current?(uri, second_generation)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "generation-scoped clear cannot erase a concurrent replacement arm", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    first_generation = current_generation(uri)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    second_generation = current_generation(uri)

    :ok = TransportReadiness.clear_generation(uri, first_generation)

    assert TransportReadiness.generation_current?(uri, second_generation)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "an old incarnation timeout cannot clear a replacement Kind's transport record", %{
    uri: uri
  } do
    old_pid = register_fake_kind(uri)
    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    old_generation = current_generation(uri)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    replacement_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(replacement_pid, :kill) end)
    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    replacement_generation = current_generation(uri)

    :ok = TransportReadiness.timeout_generation(uri, old_generation)

    assert TransportReadiness.generation_current?(uri, replacement_generation)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a parked transport observer follows a same-incarnation re-arm", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    waiter = Task.async(fn -> TransportReadiness.await_transport_or_fail(uri) end)
    Process.sleep(20)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    assert nil == Task.yield(waiter, 50)

    :ok = LiveJoinRegistry.mark_joined(uri)

    assert :ok = Task.await(waiter, 1_000)
    assert eventually(fn -> transport_records(uri) == [] end)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a parked transport observer stops when its Kind incarnation is replaced", %{uri: uri} do
    old_pid = register_fake_kind(uri)
    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    waiter = Task.async(fn -> TransportReadiness.await_transport_or_fail(uri) end)
    Process.sleep(20)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    replacement_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(replacement_pid, :kill) end)
    :ok = Ezagent.ReadyGate.put(uri, :ready)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)

    assert :ok = Task.await(waiter, 1_000)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "on_transport_joined does not alter Kind readiness without a transport record", %{uri: uri} do
    :ok = Ezagent.ReadyGate.put(uri, :ready)

    assert :ok = TransportReadiness.on_transport_joined(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  defp transport_records(uri), do: :ets.lookup(TransportReadiness.table(), URI.to_string(uri))

  defp current_generation(uri) do
    [{_, _timeout_ms, generation, _incarnation}] = transport_records(uri)
    generation
  end

  defp start_bridge(_uri), do: spawn(fn -> Process.sleep(:infinity) end)

  defp stop_bridge(uri, bridge) do
    if Process.alive?(bridge), do: Process.exit(bridge, :kill)
    :ok = BridgeRegistry.unbind(uri)
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

  defp register_fake_kind(uri) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Ezagent.KindRegistry.put_new(uri)
        send(parent, {:fake_kind_registered, self()})
        fake_kind_loop()
      end)

    assert_receive {:fake_kind_registered, ^pid}, 1_000
    pid
  end

  defp fake_kind_loop do
    receive do
      :stop -> :ok
      _message -> fake_kind_loop()
    end
  end
end
