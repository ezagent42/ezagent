defmodule EzagentPluginCc.Integration.BridgeJoinE2ETest do
  @moduledoc """
  e2e tests for the cc-agent → esr-bridge → JOIN flow.

  ## Why this file exists

  The "0 JOINED agent_bridge" regression (2026-06-01) had no automated
  coverage. Any change to claude's startup sequence (theme picker, trust
  folder, dev-channels dialogs, OAuth screen, MCP init timing) silently
  broke the JOIN while all other tests stayed green.

  This file adds TWO levels of coverage:

  ### Level 1 — bridge subprocess only (@tag :slow + uv)

  Spawns `uv run --script ezagent_mcp_bridge.py` directly against a real
  AgentBridge endpoint in this process. No claude binary needed. Proves:
  - The bridge script can connect + authenticate
  - The `agent_bridge:cc:<uri>` channel JOIN succeeds
  - `Ezagent.AgentBridge.Registry.lookup/1` returns `{:ok, pid}`

  ### Level 2 — full PTY: real claude → JOINED (@tag :live + @tag :slow)

  Spawns a real `claude` binary via PtyServer (the same path production
  takes), handles startup dialogs via the auto-prompt scanner, calls
  `EagerBridge.ensure_bound!`, and asserts the bridge JOINs.

  Requires:
  - `claude` on PATH (claude >= 2.1.x)
  - `uv` on PATH
  - Valid Anthropic credentials in `~/.claude` (avoids the 2.1.92
    per-dir Keychain isolation issue — uses the host's ~/.claude so no
    OAuth screen appears)
  - A running AgentBridge endpoint in this test process

  Mark `:live` to exclude from default CI; run manually with:
    `mix test --include live apps/ezagent_plugin_cc/test/integration/bridge_join_e2e_test.exs`
  """

  use EzagentCore.DataCase, async: false

  require Logger

  alias Ezagent.AgentBridge.{Registry, TokenStore}
  alias EzagentPluginCc.{EagerBridge, McpConfigWriter}

  # --- module-level gating ------------------------------------------------

  @uv_path System.find_executable("uv")
  @claude_path System.find_executable("claude")

  @uv_skip if is_nil(@uv_path),
             do: "`uv` not on PATH — cannot run bridge subprocess",
             else: false

  @live_skip if is_nil(@uv_path) or is_nil(@claude_path),
               do: "`uv` and/or `claude` not on PATH — live PTY test requires both",
               else: false

  # --- test endpoint ------------------------------------------------------

  # A Phoenix endpoint with a REAL HTTP listener so the bridge subprocess
  # can open a WebSocket against `/agent_bridge`. Defined at top level
  # (not nested in the test module) so the `socket/3` macro is unambiguous.
  defmodule AgentBridgeEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ezagent_plugin_cc

    socket("/agent_bridge", Ezagent.AgentBridge.Socket,
      websocket: [check_origin: false],
      longpoll: false
    )
  end

  # --- helpers ------------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  defp free_tcp_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp bridge_script_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.dirname()
    |> Path.join("python/ezagent_mcp_bridge.py")
  end

  # Run the bridge as a subprocess via Port. Feed MCP JSON-RPC stdin,
  # wait until `expected` reply lines appear or timeout.
  defp run_bridge_subprocess(ws_url, agent_uri, token, expected_join_ms \\ 10_000) do
    script = bridge_script_path()

    env_list = [
      {~c"EZAGENT_BRIDGE_WS_URL", String.to_charlist(ws_url)},
      {~c"EZAGENT_AGENT_URI", String.to_charlist(URI.to_string(agent_uri))},
      {~c"EZAGENT_AGENT_TOKEN", String.to_charlist(token)},
      {~c"EZAGENT_HOME", String.to_charlist(System.tmp_dir!())},
      {~c"EZAGENT_PROFILE", ~c"bridge-e2e-test"}
    ]

    port =
      Port.open(
        {:spawn_executable, @uv_path},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["run", "--script", script],
          env: env_list
        ]
      )

    on_exit(fn -> if Process.alive?(self()), do: catch_exit(Port.close(port)) end)

    # Feed MCP initialize so the bridge responds and enters its loop
    Port.command(
      port,
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}) <>
        "\n"
    )

    {port, expected_join_ms}
  end

  defp wait_for_registry(agent_uri, deadline_ms) do
    t0 = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      case Registry.lookup(agent_uri) do
        {:ok, pid} -> {:done, pid}
        :error -> :waiting
      end
    end)
    |> Stream.each(fn r ->
      if r == :waiting, do: Process.sleep(100)
    end)
    |> Stream.take_while(fn
      {:done, _} -> false
      :waiting -> System.monotonic_time(:millisecond) - t0 < deadline_ms
    end)
    |> Enum.to_list()

    Registry.lookup(agent_uri)
  end

  # ==========================================================================
  # Level 1 — bridge subprocess
  # ==========================================================================

  describe "bridge subprocess: uv run --script ezagent_mcp_bridge.py → JOINs" do
    @tag :slow
    @tag skip: @uv_skip
    @tag timeout: 60_000
    test "bridge subprocess authenticates and JOINs agent_bridge:cc:<uri>" do
      port = free_tcp_port()

      Application.put_env(:ezagent_plugin_cc, AgentBridgeEndpoint,
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: port],
        secret_key_base: String.duplicate("c", 64),
        pubsub_server: EzagentCore.PubSub,
        server: true
      )

      start_supervised!(AgentBridgeEndpoint)

      # Give the endpoint a moment to bind
      Process.sleep(100)

      agent_uri = URI.new!("entity://agent/test-ws/cc_bridge_e2e_#{uniq()}")
      {:ok, token} = TokenStore.mint(agent_uri)

      ws_url = "ws://127.0.0.1:#{port}/agent_bridge/websocket"
      {_port, _} = run_bridge_subprocess(ws_url, agent_uri, token)

      case wait_for_registry(agent_uri, 15_000) do
        {:ok, _pid} ->
          :ok

        :error ->
          flunk(
            "bridge subprocess did NOT JOIN agent_bridge:cc:#{agent_uri} within 15s. " <>
              "Check ~/.ezagent/bridge-e2e-test/logs/ for bridge subprocess stderr."
          )
      end
    end
  end

  # ==========================================================================
  # Level 2 — full PTY: real claude spawned via PtyServer → bridge JOINs
  # ==========================================================================

  describe "full PTY: real claude startup → esr-bridge MCP → JOINED" do
    @tag :live
    @tag :slow
    @tag skip: @live_skip
    @tag timeout: 120_000
    test "spawn real claude (no per-agent CLAUDE_CONFIG_DIR) → ensure_bound! → :ok" do
      # Uses the host's ~/.claude so Keychain-based credentials work in
      # claude 2.1.92. A per-agent CLAUDE_CONFIG_DIR would need a separate
      # Keychain entry (none exists for a fresh dir → OAuth screen).
      port = free_tcp_port()

      Application.put_env(:ezagent_plugin_cc, AgentBridgeEndpoint,
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: port],
        secret_key_base: String.duplicate("d", 64),
        pubsub_server: EzagentCore.PubSub,
        server: true
      )

      start_supervised!(AgentBridgeEndpoint)
      Process.sleep(100)

      agent_uri = URI.new!("entity://agent/test-ws/cc_pty_live_#{uniq()}")
      agent_cwd = Path.join(System.tmp_dir!(), "cc-live-e2e-#{uniq()}")
      File.mkdir_p!(agent_cwd)
      on_exit(fn -> File.rm_rf(agent_cwd) end)

      ws_url = "ws://127.0.0.1:#{port}/agent_bridge/websocket"

      # Write the per-agent .mcp.json pointing at our test endpoint
      {:ok, _path, token} =
        McpConfigWriter.write_with_token!(
          agent_uri: URI.to_string(agent_uri),
          agent_cwd: agent_cwd,
          ws_url: ws_url
        )

      argv = [
        @claude_path,
        "--dangerously-skip-permissions",
        "--dangerously-load-development-channels",
        "server:esr-bridge",
        "--settings",
        mandatory_settings_path(),
        "--mcp-config",
        Path.join(agent_cwd, ".mcp.json")
      ]

      cmd_env = %{
        "EZAGENT_AGENT_URI" => URI.to_string(agent_uri),
        "EZAGENT_AGENT_TOKEN" => token
      }

      # Intentionally NO CLAUDE_CONFIG_DIR in cmd_env: the spawned claude
      # inherits ~/.claude via normal env inheritance, which has the
      # Keychain-based credentials for claude 2.1.92 → no OAuth screen.

      # Start the PtyServer via Pty.start so it registers under the
      # DynamicSupervisor (required for Pty.lookup → EagerBridge).
      # test_mode: false overrides Mix.env() == :test default.
      Process.flag(:trap_exit, true)

      {:ok, _pty_pid} =
        Ezagent.Domain.Pty.start(agent_uri, %{
          cwd: agent_cwd,
          cmd_override: argv,
          cmd_env: cmd_env,
          test_mode: false,
          auto_prompts: Ezagent.Domain.Pty.Server.default_auto_prompts()
        })

      result = EagerBridge.ensure_bound!(agent_uri, 90_000)

      assert result == :ok,
             "EagerBridge.ensure_bound! returned #{inspect(result)} instead of :ok. " <>
               "Check logs for OAuth screen or bridge MCP init failure."

      assert {:ok, _bridge_pid} = Registry.lookup(agent_uri),
             "bridge was not in AgentBridge.Registry after ensure_bound! returned :ok"
    end
  end

  # ==========================================================================
  # Helper — mandatory settings path for argv construction
  # ==========================================================================

  defp mandatory_settings_path do
    :code.priv_dir(:ezagent_plugin_cc) |> Path.join("claude-pty-settings.json")
  end
end
