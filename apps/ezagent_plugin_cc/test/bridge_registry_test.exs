defmodule EzagentPluginCc.BridgeRegistryTest do
  use ExUnit.Case, async: false

  alias EzagentPluginCc.BridgeRegistry

  setup do
    BridgeRegistry.init()

    for {uri, _pid} <- BridgeRegistry.list_all() do
      BridgeRegistry.unbind(uri)
    end

    :ok
  end

  test "bind / lookup / unbind roundtrip" do
    uri = URI.new!("entity://team-alpha/agent/test_test-bridge-#{System.unique_integer([:positive])}")
    pid = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = BridgeRegistry.bind(uri, pid)
    assert {:ok, ^pid} = BridgeRegistry.lookup(uri)
    assert :ok = BridgeRegistry.unbind(uri)
    assert :error = BridgeRegistry.lookup(uri)
  end

  test "deprecated shim bind/3 result matches promoted registry bind/3" do
    uri = URI.new!("entity://team-alpha/agent/test_shim-bind-#{System.unique_integer([:positive])}")
    pid = spawn(fn -> Process.sleep(:infinity) end)
    info = %{bridge_flavor: "cc", tools: ["reply"]}

    promoted_result = Ezagent.AgentBridge.Registry.bind(uri, pid, info)
    shim_result = BridgeRegistry.bind(uri, pid, info)

    assert shim_result == promoted_result
  end

  test "double-bind same pid is idempotent" do
    uri = URI.new!("entity://team-alpha/agent/test_test-bridge-double")
    pid = spawn(fn -> Process.sleep(:infinity) end)

    :ok = BridgeRegistry.bind(uri, pid)
    assert :ok = BridgeRegistry.bind(uri, pid)
  end

  test "bind on top of live pid returns :already_bound" do
    uri = URI.new!("entity://team-alpha/agent/test_test-bridge-conflict")
    p1 = spawn(fn -> Process.sleep(:infinity) end)
    p2 = spawn(fn -> Process.sleep(:infinity) end)

    :ok = BridgeRegistry.bind(uri, p1)
    assert {:error, :already_bound} = BridgeRegistry.bind(uri, p2)
  end

  test "bind replaces a dead pid silently" do
    uri = URI.new!("entity://team-alpha/agent/test_test-bridge-replace")
    p1 = spawn(fn -> :ok end)
    Process.sleep(20)
    refute Process.alive?(p1)

    :ok = BridgeRegistry.bind(uri, p1)
    p2 = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = BridgeRegistry.bind(uri, p2)
    assert {:ok, ^p2} = BridgeRegistry.lookup(uri)
  end

  describe "PR 32a — observability surface" do
    test "count/0 reflects current bindings" do
      assert BridgeRegistry.count() == 0

      a = URI.new!("entity://team-alpha/agent/test_count-a")
      b = URI.new!("entity://team-alpha/agent/test_count-b")
      pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = BridgeRegistry.bind(a, pid)
      assert BridgeRegistry.count() == 1

      :ok = BridgeRegistry.bind(b, spawn(fn -> Process.sleep(:infinity) end))
      assert BridgeRegistry.count() == 2

      :ok = BridgeRegistry.unbind(a)
      assert BridgeRegistry.count() == 1
    end

    test "status/0 reports :no_bridges or {:connected, n}" do
      assert BridgeRegistry.status() == :no_bridges

      uri = URI.new!("entity://team-alpha/agent/test_status-1")
      :ok = BridgeRegistry.bind(uri, spawn(fn -> Process.sleep(:infinity) end))
      assert BridgeRegistry.status() == {:connected, 1}
    end

    test "list_connected/0 carries info + connected_at" do
      uri = URI.new!("entity://team-alpha/agent/test_info-bridge")
      pid = spawn(fn -> Process.sleep(:infinity) end)
      info = %{claude_info: %{"version" => "2.1.143"}, tools: ["reply"]}

      :ok = BridgeRegistry.bind(uri, pid, info)

      [{found_uri, row}] = BridgeRegistry.list_connected()
      assert URI.to_string(found_uri) == "entity://team-alpha/agent/test_info-bridge"
      assert row.pid == pid
      assert %DateTime{} = row.connected_at
      assert row.info == info
    end

    test "list_all/0 keeps {uri, pid} back-compat shape" do
      uri = URI.new!("entity://team-alpha/agent/test_list-all-bc")
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = BridgeRegistry.bind(uri, pid)

      matched =
        BridgeRegistry.list_all()
        |> Enum.find(fn {u, _} -> URI.to_string(u) == "entity://team-alpha/agent/test_list-all-bc" end)

      assert {%URI{}, ^pid} = matched
    end

    test "bind/unbind broadcast on topic/0" do
      uri = URI.new!("entity://team-alpha/agent/test_broadcast-bridge")
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, BridgeRegistry.topic())

      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = BridgeRegistry.bind(uri, pid, %{tools: ["reply"]})

      assert_receive {:cc_connected, ^uri, %{tools: ["reply"]}}, 500

      :ok = BridgeRegistry.unbind(uri)
      assert_receive {:cc_disconnected, ^uri}, 500
    end

    test "unbind on absent uri is :ok and silent" do
      uri = URI.new!("entity://team-alpha/agent/test_never-bound")
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, BridgeRegistry.topic())

      assert :ok = BridgeRegistry.unbind(uri)
      refute_receive {:cc_disconnected, ^uri}, 200
    end
  end
end
