defmodule Ezagent.AgentBridge.DeliverEnsuringTest do
  @moduledoc """
  PR-DR (delivery readiness, blocker #1). A routed message to a bridge agent
  whose Registry row has vanished (its subprocess/WS bridge exited →
  `Channel.terminate/2` unbound it) must SELF-HEAL: ensure the subprocess is
  (re)alive, await the rebind (bounded), and deliver — NOT silently drop.

  The self-heal step is injected via `:bridge_heal_fn` (DI seam) so these unit
  tests exercise the readiness/retry logic without a real claude subprocess.
  """
  use ExUnit.Case, async: false

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  defmodule TestAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "test"

    @impl true
    def agent_uri_prefix, do: "test_"

    @impl true
    def deliver(%Payload{} = payload, channel_pid) do
      send(channel_pid, {:agent_bridge_delivered, payload})
      :ok
    end

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    Registry.init()
    for {uri, _pid} <- Registry.list_all(), do: Registry.unbind(uri)
    _ = AdapterRegistry.register("test", TestAdapter)

    prev = Application.get_env(:ezagent_domain_agent_bridge, :bridge_heal_fn)
    prev_t = Application.get_env(:ezagent_domain_agent_bridge, :bridge_ready_timeout_ms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, prev),
        else: Application.delete_env(:ezagent_domain_agent_bridge, :bridge_heal_fn)

      if prev_t,
        do: Application.put_env(:ezagent_domain_agent_bridge, :bridge_ready_timeout_ms, prev_t),
        else: Application.delete_env(:ezagent_domain_agent_bridge, :bridge_ready_timeout_ms)
    end)

    :ok
  end

  defp uri(name),
    do: URI.new!("entity://agent/team-alpha/test_#{name}-#{System.unique_integer([:positive])}")

  defp payload(),
    do: %Payload{
      message_id: "m-#{System.unique_integer([:positive])}",
      session_uri: URI.new!("session://default/team-alpha/s"),
      sender_uri: URI.new!("entity://user/system/admin"),
      text: "hello",
      event_type: :chat_send,
      meta: %{}
    }

  test "ensure_ready/1 returns :ok immediately when already bound" do
    u = uri("bound")
    :ok = Registry.bind(u, self())
    assert :ok = Ezagent.AgentBridge.ensure_ready(u)
  end

  test "ensure_ready/1 invokes the heal fn and returns :ok once it (re)binds" do
    u = uri("heal")
    test_pid = self()

    # heal fn simulates the relaunched bridge re-joining: bind a fresh channel pid.
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, fn agent_uri ->
      chan = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.bind(agent_uri, chan)
      send(test_pid, {:healed, agent_uri, chan})
      :ok
    end)

    assert :ok = Ezagent.AgentBridge.ensure_ready(u)
    assert_receive {:healed, ^u, _chan}, 500
    assert {:ok, _pid} = Registry.lookup(u)
  end

  test "ensure_ready/1 returns {:error, :timeout} when heal does not rebind" do
    u = uri("noheal")
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_ready_timeout_ms, 120)
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, fn _ -> :ok end)

    assert {:error, :timeout} = Ezagent.AgentBridge.ensure_ready(u)
  end

  test "ensure_ready/1 surfaces a heal failure as {:error, reason}" do
    u = uri("healfail")

    Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, fn _ ->
      {:error, :subprocess_unhealthy}
    end)

    assert {:error, :subprocess_unhealthy} = Ezagent.AgentBridge.ensure_ready(u)
  end

  test "deliver_ensuring/2 delivers immediately when the bridge is already bound" do
    u = uri("direct")
    :ok = Registry.bind(u, self())
    p = payload()

    assert :ok = Ezagent.AgentBridge.deliver_ensuring(u, p)
    assert_receive {:agent_bridge_delivered, ^p}, 500
  end

  test "deliver_ensuring/2 self-heals a vanished bridge and delivers (blocker #1 regression)" do
    u = uri("vanished")
    test_pid = self()

    # Simulate the blocker: the row is ABSENT (subprocess exited → terminate
    # unbound it). The heal fn rebinds a live channel pid (relaunched bridge
    # re-joined). deliver_ensuring must recover and deliver — not :no_bridge-drop.
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, fn agent_uri ->
      chan =
        spawn(fn ->
          receive do
            {:agent_bridge_delivered, p} -> send(test_pid, {:delivered_to_chan, p})
          end
        end)

      :ok = Registry.bind(agent_uri, chan)
      :ok
    end)

    p = payload()
    assert Registry.lookup(u) == :error

    assert :ok = Ezagent.AgentBridge.deliver_ensuring(u, p)
    assert_receive {:delivered_to_chan, ^p}, 500
  end

  test "deliver_ensuring/2 drops (as today) when self-heal cannot restore the bridge" do
    u = uri("unrecoverable")
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_ready_timeout_ms, 120)
    Application.put_env(:ezagent_domain_agent_bridge, :bridge_heal_fn, fn _ -> :ok end)

    assert {:error, reason} = Ezagent.AgentBridge.deliver_ensuring(u, payload())
    assert reason in [:timeout, :no_bridge]
  end
end
