defmodule Ezagent.AgentBridge.DeliverTest do
  use ExUnit.Case, async: false

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  defmodule TestAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "test"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(%Payload{} = payload, channel_pid) do
      send(channel_pid, {:agent_bridge_delivered, payload})
      :ok
    end

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  defmodule OtherTestAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "test"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(%Payload{}, _channel_pid), do: :ok

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  defmodule LateAdapter do
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "late"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(%Payload{} = payload, channel_pid) do
      send(channel_pid, {:late_agent_bridge_delivered, payload})
      :ok
    end

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    Registry.init()

    for {uri, _pid} <- Registry.list_all() do
      Registry.unbind(uri)
    end

    :ok = AdapterRegistry.register("test", TestAdapter)
    :ok
  end

  setup do
    Ezagent.UriQuery.init()
    previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for entry <- previous do
        :ets.insert(Ezagent.UriQuery.table(), entry)
      end
    end)

    :ok
  end

  test "deliver/2 resolves adapter by agent flavor and sends to bound channel pid" do
    agent_uri =
      URI.new!("entity://team-alpha/agent/test_bridge-#{System.unique_integer([:positive])}")

    sender_uri = URI.new!("entity://system/user/admin")

    session_uri =
      URI.new!("session://team-alpha/default/test-#{System.unique_integer([:positive])}")

    put_flavor(agent_uri, "test")

    payload = %Payload{
      message_id: "m1",
      session_uri: session_uri,
      sender_uri: sender_uri,
      text: "hello",
      event_type: :chat_send,
      meta: %{"sender" => URI.to_string(sender_uri)}
    }

    :ok = Registry.bind(agent_uri, self())

    assert :ok = Ezagent.AgentBridge.deliver(agent_uri, payload)
    assert_receive {:agent_bridge_delivered, ^payload}, 500
  end

  test "deliver/2 resolves adapter flavor through UriQuery for prefixless agent URIs" do
    agent_uri = URI.new!("entity://team-alpha/agent/bridge-#{System.unique_integer([:positive])}")
    sender_uri = URI.new!("entity://system/user/admin")
    put_flavor(agent_uri, "test")

    payload = %Payload{
      message_id: "m1-prefixless",
      session_uri: URI.new!("session://team-alpha/default/test-prefixless"),
      sender_uri: sender_uri,
      text: "hello",
      event_type: :chat_send,
      meta: %{"sender" => URI.to_string(sender_uri)}
    }

    :ok = Registry.bind(agent_uri, self())

    assert :ok = Ezagent.AgentBridge.deliver(agent_uri, payload)
    assert_receive {:agent_bridge_delivered, ^payload}, 500
  end

  test "deliver/2 reports no bridge without raising" do
    agent_uri =
      URI.new!("entity://team-alpha/agent/test_missing-#{System.unique_integer([:positive])}")

    put_flavor(agent_uri, "test")

    payload = %Payload{
      message_id: "m2",
      session_uri: URI.new!("session://team-alpha/default/missing"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: "hello",
      event_type: :chat_send,
      meta: %{}
    }

    assert {:error, :no_bridge} = Ezagent.AgentBridge.deliver(agent_uri, payload)
  end

  test "deliver/2 buffers when no adapter is registered yet" do
    agent_uri =
      URI.new!("entity://team-alpha/agent/missing_bridge-#{System.unique_integer([:positive])}")

    put_flavor(agent_uri, "missing")

    payload = %Payload{
      message_id: "m3",
      session_uri: URI.new!("session://team-alpha/default/no-adapter"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: "hello",
      event_type: :chat_send,
      meta: %{}
    }

    :ok = Registry.bind(agent_uri, self())

    assert :ok = Ezagent.AgentBridge.deliver(agent_uri, payload)
    refute_receive {:agent_bridge_delivered, ^payload}, 50
  end

  test "deliver/2 drains buffered payloads when adapter registers" do
    agent_uri =
      URI.new!("entity://team-alpha/agent/late_bridge-#{System.unique_integer([:positive])}")

    put_flavor(agent_uri, "late")

    payload = %Payload{
      message_id: "m4",
      session_uri: URI.new!("session://team-alpha/default/late"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: "hello late",
      event_type: :chat_send,
      meta: %{}
    }

    :ok = Registry.bind(agent_uri, self())

    assert :ok = Ezagent.AgentBridge.deliver(agent_uri, payload)
    refute_receive {:late_agent_bridge_delivered, ^payload}, 50

    assert :ok = AdapterRegistry.register("late", LateAdapter)
    assert_receive {:late_agent_bridge_delivered, ^payload}, 500
  end

  test "adapter registration is idempotent without losing existing state" do
    assert :ok = AdapterRegistry.register("test", TestAdapter)
    assert {:ok, TestAdapter} = AdapterRegistry.lookup("test")

    assert {:error, {:already_registered, TestAdapter}} =
             AdapterRegistry.register("test", OtherTestAdapter)

    assert {:ok, TestAdapter} = AdapterRegistry.lookup("test")
  end

  defp put_flavor(agent_uri, flavor) do
    :ets.insert(Ezagent.UriQuery.table(), {:flavor, fn ^agent_uri -> {:ok, flavor} end})
  end
end
