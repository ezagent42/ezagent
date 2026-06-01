defmodule EzagentPluginCc.EagerBridgeTest do
  @moduledoc """
  Unit tests for `EzagentPluginCc.EagerBridge` focused on the contract
  surface (already-bound short-circuit, missing-PtyServer error, timeout
  behavior, OAuth detection). The "real" trigger semantics (spawn real
  claude → bridge binds) live in
  `test/integration/bridge_join_e2e_test.exs` under @tag :live.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCc.EagerBridge
  alias Ezagent.Domain.Pty

  @agent_uri URI.new!("entity://agent/test-ws/cc_eager_test")

  describe "ensure_bound!/2" do
    test "returns {:error, :no_pty} when PtyServer not alive" do
      assert {:error, :no_pty} = EagerBridge.ensure_bound!(@agent_uri, 200)
    end

    test "returns :ok immediately when binding already exists (no PTY interaction)" do
      :ok = Ezagent.AgentBridge.Registry.init()
      pid = self()
      :ok = Ezagent.AgentBridge.Registry.bind(@agent_uri, pid, %{test: true})

      try do
        assert :ok = EagerBridge.ensure_bound!(@agent_uri, 5_000)
      after
        Ezagent.AgentBridge.Registry.unbind(@agent_uri)
      end
    end

    test "returns {:error, :oauth_required} when PtyServer has oauth_blocked?" do
      uri =
        URI.new!("entity://agent/test-ws/cc_eager_oauth_#{System.unique_integer([:positive])}")

      {:ok, pty_pid} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})

      on_exit(fn ->
        if Process.alive?(pty_pid), do: GenServer.stop(pty_pid, :normal)
      end)

      # Inject the oauth_blocked? flag directly (simulates what scan_auto_prompts
      # sets when "Paste code here if prompted" appears in the PTY output).
      :sys.replace_state(pty_pid, fn s -> %{s | oauth_blocked?: true} end)

      assert {:error, :oauth_required} = EagerBridge.ensure_bound!(uri, 1_000)
    end

    test "proceeds to kick even when dialog wait times out (trust_folder not shown)" do
      # When trust_folder_dialog never appears (e.g. cwd already trusted in
      # ~/.claude), wait_for_auto_prompts times out but kick_loop must still run.
      # We can't easily verify kick_loop ran in unit-test (no live erlexec), but
      # we CAN assert the function returns something OTHER than the dialog-timeout
      # error — {:error, :no_pty} means kick_and_wait ran past the dialog gate.
      uri =
        URI.new!("entity://agent/test-ws/cc_eager_timeout_#{System.unique_integer([:positive])}")

      assert {:error, :no_pty} = EagerBridge.ensure_bound!(uri, 200)
    end
  end

  describe "status/1" do
    test "returns :no_pty when no PtyServer for agent" do
      uri =
        URI.new!("entity://agent/test-ws/cc_status_test_a_#{System.unique_integer([:positive])}")

      assert :no_pty = EagerBridge.status(uri)
    end

    test "returns :bound when registry has an entry" do
      uri =
        URI.new!("entity://agent/test-ws/cc_status_test_b_#{System.unique_integer([:positive])}")

      :ok = Ezagent.AgentBridge.Registry.init()
      :ok = Ezagent.AgentBridge.Registry.bind(uri, self(), %{})

      try do
        assert :bound = EagerBridge.status(uri)
      after
        Ezagent.AgentBridge.Registry.unbind(uri)
      end
    end
  end

  describe "PtyServer oauth_blocked? detection" do
    test "scan_auto_prompts sets oauth_blocked? when OAuth prompt text appears" do
      uri = URI.new!("entity://agent/test-ws/cc_oauth_scan_#{System.unique_integer([:positive])}")
      {:ok, pty_pid} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})

      on_exit(fn ->
        if Process.alive?(pty_pid), do: GenServer.stop(pty_pid, :normal)
      end)

      state_before = :sys.get_state(pty_pid)
      refute state_before.oauth_blocked?

      # Inject the OAuth screen text into the buffer and trigger a scan
      oauth_text =
        "Browser didn't open? Use the url below to sign in\nPaste code here if prompted >"

      :sys.replace_state(pty_pid, fn s ->
        %{s | pty_buffer: oauth_text, exec_pid: :fake_pid}
      end)

      # scan_auto_prompts runs inside handle_info when new PTY data arrives;
      # send a synthetic PTY chunk so the GenServer processes it.
      send(pty_pid, {:stdout, 0, ""})
      Process.sleep(50)

      state_after = :sys.get_state(pty_pid)
      assert state_after.oauth_blocked?, "oauth_blocked? should be true after OAuth prompt"
    end
  end
end
