defmodule Ezagent.AgentBridge.TransportClassTest do
  @moduledoc """
  PR-0 (transport-neutral adapter, OQ-5 + codex MED-2). The AgentBridge
  delivery layer branches on the adapter's `transport_class/0`:

    * `:subprocess_ws` (cc, codex) — Registry lookup → readiness gate →
      Channel pid → `deliver/2`. UNCHANGED status quo.
    * `:in_process_sync` (a future curl flavor) — NO Registry row, NO
      `ensure_ready` readiness gate, NO Channel pid. `deliver/2` is called
      INLINE with a `nil` channel ref and may return `{:ok, result}`.

  No production `:in_process_sync` adapter exists yet, so this dormant branch
  is exercised with a TEST-ONLY stub adapter.
  """
  use ExUnit.Case, async: false

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  # ── stub adapters ────────────────────────────────────────────────────────

  defmodule SyncAdapter do
    @moduledoc false
    @behaviour Ezagent.AgentBridge.Adapter

    # NO WS callbacks (handle_client_event/3, join_info/2, socket_path/0,
    # channel_topic_prefix/0) — an :in_process_sync flavor has no socket.

    @impl true
    def flavor, do: "synctest"

    @impl true
    def transport_class, do: :in_process_sync

    @impl true
    def deliver(%Payload{} = payload, channel_ref) do
      # The contract hands :in_process_sync a nil channel ref and expects a
      # synchronous {:ok, result} the owning Behavior will persist.
      send(self_test_pid(), {:sync_delivered, payload, channel_ref})
      {:ok, %{echo: payload.text, channel_ref: channel_ref}}
    end

    defp self_test_pid, do: Process.get(:transport_class_test_pid)
  end

  defmodule WsAdapter do
    @moduledoc false
    @behaviour Ezagent.AgentBridge.Adapter

    @impl true
    def flavor, do: "wstest"

    @impl true
    def transport_class, do: :subprocess_ws

    @impl true
    def deliver(%Payload{} = payload, channel_pid) do
      send(channel_pid, {:ws_delivered, payload})
      :ok
    end

    @impl true
    def handle_client_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    Registry.init()
    for {uri, _pid} <- Registry.list_all(), do: Registry.unbind(uri)

    :ok = AdapterRegistry.register("synctest", SyncAdapter)
    :ok = AdapterRegistry.register("wstest", WsAdapter)

    Ezagent.UriQuery.init()
    previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    # The SyncAdapter sends to the test pid; stash it where the stub can read it.
    Process.put(:transport_class_test_pid, self())

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)
      for entry <- previous, do: :ets.insert(Ezagent.UriQuery.table(), entry)
    end)

    :ok
  end

  defp put_flavor(agent_uri, flavor) do
    :ets.insert(Ezagent.UriQuery.table(), {:flavor, fn ^agent_uri -> {:ok, flavor} end})
  end

  defp payload(text \\ "hello") do
    %Payload{
      message_id: "m-#{System.unique_integer([:positive])}",
      session_uri: URI.new!("session://team-alpha/default/s"),
      sender_uri: URI.new!("entity://system/user/admin"),
      text: text,
      event_type: :chat_send,
      meta: %{}
    }
  end

  describe "AdapterRegistry.transport_class/1" do
    test "returns the adapter's declared class" do
      assert :in_process_sync = AdapterRegistry.transport_class("synctest")
      assert :subprocess_ws = AdapterRegistry.transport_class("wstest")
    end

    test "defaults to :subprocess_ws for an unregistered flavor" do
      assert :subprocess_ws = AdapterRegistry.transport_class("nope-#{System.unique_integer()}")
    end
  end

  describe ":in_process_sync delivery (no channel, no readiness gate)" do
    test "deliver/2 routes inline to the adapter with a nil channel ref and NO Registry row" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/sync_inline-#{System.unique_integer([:positive])}")

      put_flavor(agent_uri, "synctest")

      # Deliberately NOT bound — an :in_process_sync flavor has no Registry row.
      assert :error = Registry.lookup(agent_uri)

      p = payload("inline")

      assert {:ok, %{echo: "inline", channel_ref: nil}} =
               Ezagent.AgentBridge.deliver(agent_uri, p)

      assert_receive {:sync_delivered, ^p, nil}, 500
    end

    test "deliver_with_flavor/3 routes inline with a nil channel ref" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/sync_flavor-#{System.unique_integer([:positive])}")

      p = payload("flavor")

      assert {:ok, %{channel_ref: nil}} =
               Ezagent.AgentBridge.deliver_with_flavor(agent_uri, p, "synctest")

      assert_receive {:sync_delivered, ^p, nil}, 500
    end

    test "deliver_ensuring_with_flavor/4 SKIPS ensure_ready and delivers inline (MED-2)" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/sync_ensure-#{System.unique_integer([:positive])}")

      # A heal fn that, if called, would prove the readiness gate ran. For
      # :in_process_sync it must NEVER be invoked.
      test_pid = self()
      heal_fn = fn _uri -> send(test_pid, :heal_called) end

      p = payload("ensure")

      assert {:ok, %{channel_ref: nil}} =
               Ezagent.AgentBridge.deliver_ensuring_with_flavor(agent_uri, p, "synctest", heal_fn)

      assert_receive {:sync_delivered, ^p, nil}, 500
      refute_receive :heal_called, 100
    end

    test "deliver_ensuring/3 SKIPS ensure_ready for an :in_process_sync flavor" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/sync_ensure2-#{System.unique_integer([:positive])}")

      put_flavor(agent_uri, "synctest")

      test_pid = self()
      heal_fn = fn _uri -> send(test_pid, :heal_called) end

      p = payload("ensure2")
      assert {:ok, _result} = Ezagent.AgentBridge.deliver_ensuring(agent_uri, p, heal_fn)
      assert_receive {:sync_delivered, ^p, nil}, 500
      refute_receive :heal_called, 100
    end
  end

  describe ":subprocess_ws delivery (status quo, unchanged)" do
    test "deliver/2 uses the Registry channel pid and returns :ok" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/ws_inline-#{System.unique_integer([:positive])}")

      put_flavor(agent_uri, "wstest")
      :ok = Registry.bind(agent_uri, self())

      p = payload("ws")
      assert :ok = Ezagent.AgentBridge.deliver(agent_uri, p)
      assert_receive {:ws_delivered, ^p}, 500
    end

    test "deliver/2 :no_bridge-drops a :subprocess_ws flavor with no bound channel" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/ws_missing-#{System.unique_integer([:positive])}")

      put_flavor(agent_uri, "wstest")

      assert {:error, :no_bridge} = Ezagent.AgentBridge.deliver(agent_uri, payload())
    end
  end
end
