defmodule EzagentPluginCc.EagerBridgeTest do
  @moduledoc """
  Unit tests for `EzagentPluginCc.EagerBridge` focused on the contract
  surface (already-bound short-circuit, missing-PtyServer error, timeout
  behavior). The "real" trigger semantics (write `\\r` → bridge binds
  ~500ms later) is integration-only and lives in
  `test/integration/eager_bridge_integration_test.exs` (not added here
  because it requires a running claude binary).
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCc.EagerBridge

  @agent_uri URI.parse("entity://agent/test-ws/cc_eager_test")

  describe "ensure_bound!/2" do
    test "returns {:error, :no_pty} when PtyServer not alive" do
      # No agent was spawned; Domain.Pty.lookup → :error
      assert {:error, :no_pty} = EagerBridge.ensure_bound!(@agent_uri, 200)
    end

    test "returns :ok immediately when binding already exists (no PTY interaction)" do
      # Plant a fake binding in the registry so lookup returns {:ok, _}
      :ok = Ezagent.AgentBridge.Registry.init()
      pid = self()
      :ok = Ezagent.AgentBridge.Registry.bind(@agent_uri, pid, %{test: true})

      try do
        assert :ok = EagerBridge.ensure_bound!(@agent_uri, 5_000)
      after
        Ezagent.AgentBridge.Registry.unbind(@agent_uri)
      end
    end
  end

  describe "status/1" do
    test "returns :no_pty when no PtyServer for agent" do
      uri = URI.parse("entity://agent/test-ws/cc_status_test_a")
      assert :no_pty = EagerBridge.status(uri)
    end

    test "returns :bound when registry has an entry" do
      uri = URI.parse("entity://agent/test-ws/cc_status_test_b")
      :ok = Ezagent.AgentBridge.Registry.init()
      :ok = Ezagent.AgentBridge.Registry.bind(uri, self(), %{})

      try do
        assert :bound = EagerBridge.status(uri)
      after
        Ezagent.AgentBridge.Registry.unbind(uri)
      end
    end
  end
end
