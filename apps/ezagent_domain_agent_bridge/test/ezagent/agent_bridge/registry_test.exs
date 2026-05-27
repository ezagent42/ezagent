defmodule Ezagent.AgentBridge.RegistryTest do
  use ExUnit.Case, async: false

  alias Ezagent.AgentBridge.Registry

  setup do
    Registry.init()

    for {uri, _pid} <- Registry.list_all() do
      Registry.unbind(uri)
    end

    :ok
  end

  test "bind / lookup / unbind roundtrip" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-#{System.unique_integer([:positive])}")
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = Registry.bind(uri, pid)
    assert {:ok, ^pid} = Registry.lookup(uri)
    assert :ok = Registry.unbind(uri)
    assert :error = Registry.lookup(uri)
  end

  test "double-bind same pid is idempotent" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-double")
    pid = spawn(fn -> Process.sleep(:infinity) end)

    :ok = Registry.bind(uri, pid)
    assert :ok = Registry.bind(uri, pid)
  end

  test "bind on top of live pid returns :already_bound" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-conflict")
    p1 = spawn(fn -> Process.sleep(:infinity) end)
    p2 = spawn(fn -> Process.sleep(:infinity) end)

    :ok = Registry.bind(uri, p1)
    assert {:error, :already_bound} = Registry.bind(uri, p2)
  end

  test "bind replaces a dead pid" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-replace")
    p1 = spawn(fn -> :ok end)
    Process.sleep(20)
    refute Process.alive?(p1)

    :ok = Registry.bind(uri, p1)
    p2 = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Registry.bind(uri, p2)
    assert {:ok, ^p2} = Registry.lookup(uri)
  end

  test "list_connected/0 carries info + connected_at" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-info")
    pid = spawn(fn -> Process.sleep(:infinity) end)
    info = %{agent_info: %{"version" => "2.1.143"}, tools: ["reply"]}

    :ok = Registry.bind(uri, pid, info)

    [{found_uri, row}] = Registry.list_connected()
    assert URI.to_string(found_uri) == "entity://agent/team-alpha/test_bridge-info"
    assert row.pid == pid
    assert %DateTime{} = row.connected_at
    assert row.info == info
  end

  test "count/0 and status/0 reflect current bindings" do
    assert Registry.count() == 0
    assert Registry.status() == :no_bridges

    uri = URI.new!("entity://agent/team-alpha/test_bridge-count")
    :ok = Registry.bind(uri, spawn(fn -> Process.sleep(:infinity) end))

    assert Registry.count() == 1
    assert Registry.status() == {:connected, 1}
  end

  test "bind/unbind broadcast generic and legacy events" do
    uri = URI.new!("entity://agent/team-alpha/test_bridge-broadcast")
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Registry.topic())
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Registry.legacy_topic())

    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Registry.bind(uri, pid, %{tools: ["reply"]})

    assert_receive {:agent_bridge_connected, ^uri, %{tools: ["reply"]}}, 500
    assert_receive {:cc_connected, ^uri, %{tools: ["reply"]}}, 500

    :ok = Registry.unbind(uri)

    assert_receive {:agent_bridge_disconnected, ^uri}, 500
    assert_receive {:cc_disconnected, ^uri}, 500
  end
end
