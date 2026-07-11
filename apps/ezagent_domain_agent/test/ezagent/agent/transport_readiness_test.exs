defmodule Ezagent.Agent.TransportReadinessTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.{LiveJoinRegistry, TransportReadiness}
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  setup_all do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  setup do
    # The supervised timeout listener writes DLQ rows from its own process.
    # `setup_all` gives the non-async module one shared owner, so that process
    # never outlives a per-test checkout. Keep each assertion isolated here.
    EzagentCore.Repo.query!("DELETE FROM dlq WHERE reason = 'never_ready'")

    uri =
      Ezagent.URI.new!("entity://system/agent/bridge-ready-#{System.unique_integer([:positive])}")

    LiveJoinRegistry.init()
    :ok = LiveJoinRegistry.clear(uri)
    :ok = TransportReadiness.clear(uri)
    :ok = Ezagent.ReadyGate.put(uri, :unknown)

    on_exit(fn ->
      :ok = LiveJoinRegistry.clear(uri)
      :ok = TransportReadiness.clear(uri)
      :ok = Ezagent.ReadyGate.put(uri, :unknown)
      _ = Ezagent.PendingDelivery.flush(uri)
    end)

    %{uri: uri}
  end

  test "bridge-backed agents defer ReadyGate readiness until their transport joins", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

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
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

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
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

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
  test "an already-live join is settled atomically while the gate is armed", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = LiveJoinRegistry.mark_joined(uri)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)

    # No await Task and no listener turn are needed — require/arm closes the
    # record→gate→pre-existing-signal window itself.
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a LiveJoinRegistry mark after arming wakes readiness without an await task", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    # The orchestrator MCP transport records this durable signal after the
    # readiness generation is already armed. No caller invokes
    # await_transport_or_fail/1 or on_transport_joined/1 manually.
    :ok = LiveJoinRegistry.mark_joined(uri)

    assert eventually(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
    assert :ets.lookup(TransportReadiness.table(), URI.to_string(uri)) == []
  end

  test "a live-join event fails and drains when the armed Kind is already gone", %{uri: uri} do
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)
    :ok = Ezagent.PendingDelivery.buffer(uri, buffered_absorb(uri))
    :ok = LiveJoinRegistry.mark_joined(uri)

    assert eventually(fn -> Ezagent.ReadyGate.status(uri) == :failed end)
    assert Ezagent.PendingDelivery.buffer_size(uri) == 0

    assert [["never_ready", payload_json]] =
             EzagentCore.Repo.query!(
               "SELECT reason, payload FROM dlq WHERE reason = 'never_ready'"
             ).rows

    assert Jason.decode!(payload_json)["target"] =~ "action=identity.absorb_cap"
  end

  test "fresh-spawn ordering auto-fails and dead-letters without an await task", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30)
    :ok = Ezagent.PendingDelivery.buffer(uri, buffered_absorb(uri))

    assert eventually(fn -> Ezagent.ReadyGate.status(uri) == :failed end)
    assert Ezagent.PendingDelivery.buffer_size(uri) == 0

    assert [["never_ready"]] =
             EzagentCore.Repo.query!("SELECT reason FROM dlq WHERE reason = 'never_ready'").rows
  end

  test "a stale timeout generation cannot fail a re-armed URI", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30)
    Process.sleep(10)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)

    Process.sleep(60)
    assert Ezagent.ReadyGate.status(uri) == :not_ready
  end

  test "a delayed timeout notification cannot fail a generation re-armed after timeout commit", %{
    uri: uri
  } do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 20)
    assert {:error, :timeout} = TransportReadiness.await_transport_or_fail(uri)
    assert Ezagent.ReadyGate.status(uri) == :failed

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    :ok = Ezagent.PendingDelivery.buffer(uri, buffered_absorb(uri))
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    state = %{sentinel: true}

    assert {:noreply, ^state} =
             Ezagent.Kind.Server.handle_info(
               {:ezagent_external_ready_gate, URI.to_string(uri), {:error, :timeout}},
               state
             )

    assert Ezagent.ReadyGate.status(uri) == :not_ready
    assert Ezagent.PendingDelivery.buffer_size(uri) == 1
  end

  test "a stale arm cannot cancel the current generation's failure timer", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 80)

    :ok =
      Ezagent.Agent.TransportReadinessListener.arm_timeout(uri, 10, make_ref())

    assert eventually(fn -> Ezagent.ReadyGate.status(uri) == :failed end)
  end

  test "a parked await follows a same-incarnation re-arm", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    waiter = Task.async(fn -> TransportReadiness.await_transport_or_fail(uri) end)
    Process.sleep(20)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)

    assert nil == Task.yield(waiter, 50)
    assert Ezagent.ReadyGate.status(uri) == :not_ready

    :ok = LiveJoinRegistry.mark_joined(uri)
    assert :ok = Task.await(waiter, 1_000)
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a parked await cannot follow a replacement Kind's generation", %{uri: uri} do
    old_pid = register_fake_kind(uri)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    waiter = Task.async(fn -> TransportReadiness.await_transport_or_fail(uri) end)
    Process.sleep(20)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    replacement_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(replacement_pid, :kill) end)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)

    assert {:error, :superseded} = Task.await(waiter, 1_000)
    assert Ezagent.ReadyGate.status(uri) == :not_ready
  end

  test "a same-incarnation re-arm still runs Lifecycle activated after the join", %{uri: uri} do
    probe_key = {Ezagent.Agent.TransportRearmProbeBehavior, :test_pid}
    :persistent_term.put(probe_key, self())
    on_exit(fn -> :persistent_term.erase(probe_key) end)

    {:ok, kind_pid} =
      Ezagent.Kind.Server.start_link(
        {Ezagent.Agent.TransportRearmProbeKind, %{uri: uri}}
      )

    on_exit(fn ->
      :ok = TransportReadiness.clear(uri)
      if Process.alive?(kind_pid), do: GenServer.stop(kind_pid, :normal)
    end)

    assert eventually(fn ->
             Ezagent.ReadyGate.status(uri) == :not_ready and
               TransportReadiness.defer_ready?(uri) == {:defer, 30_000}
           end)

    # Supersede the generation installed by activate/2 while the Kind.Server's
    # original waiter is parked. The waiter must follow this same pid.
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 30_000)
    :ok = LiveJoinRegistry.mark_joined(uri)

    assert_receive {:transport_rearm_activated, ^uri}, 1_000
    assert Ezagent.ReadyGate.status(uri) == :ready
  end

  test "a stale queued join event cannot settle after the live signal vanished", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    # Seed then clear the durable truth without broadcasting: using
    # mark_joined/1 here races the real supervised listener, which may consume
    # the legitimate live edge before this test can model a stale queued event.
    true = :ets.insert(LiveJoinRegistry.table(), {URI.to_string(uri), true})
    :ok = LiveJoinRegistry.clear(uri)

    assert :ok = TransportReadiness.on_transport_joined(uri)
    assert Ezagent.ReadyGate.status(uri) == :not_ready
  end

  test "generation-scoped clear cannot erase a concurrent replacement arm", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    [{_, _, first_generation, _}] = :ets.lookup(TransportReadiness.table(), URI.to_string(uri))

    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 500)
    [{_, _, second_generation, _}] = :ets.lookup(TransportReadiness.table(), URI.to_string(uri))

    refute first_generation == second_generation
    :ok = TransportReadiness.clear_generation(uri, first_generation)

    assert TransportReadiness.generation_current?(uri, second_generation)
    assert Ezagent.ReadyGate.status(uri) == :not_ready
  end

  test "an old incarnation timer cannot fail a replacement Kind at the same URI", %{uri: uri} do
    old_pid = register_fake_kind(uri)
    :ok = TransportReadiness.require_transport_join(uri, timeout_ms: 40)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    new_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(new_pid, :kill) end)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    Process.sleep(80)
    assert Ezagent.ReadyGate.status(uri) == :not_ready
    assert TransportReadiness.defer_ready?(uri) == :ready
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
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

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

  defp buffered_absorb(uri) do
    artifact = %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: uri,
      workspace_uri: Ezagent.Capability.workspace_of(uri),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }

    %Ezagent.Invocation{
      target: Ezagent.URI.with_action(uri, :identity, :absorb_cap),
      mode: :cast,
      args: %{artifact: artifact},
      ctx: %{caller: :vm_internal, caps: MapSet.new(), reply: :ignore}
    }
  end
end
