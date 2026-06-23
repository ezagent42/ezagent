defmodule Ezagent.Agent.TransportReadinessTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.{LiveJoinRegistry, TransportReadiness}

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
end
