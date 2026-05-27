defmodule EzagentPluginCc.McpConfigWriterTest do
  use ExUnit.Case, async: false

  alias EzagentPluginCc.McpConfigWriter
  alias EzagentPluginCc.TokenStore

  setup do
    # Isolated $EZAGENT_HOME so TokenStore writes a real but throwaway
    # cc-channels.yaml during the test.
    tmp = Path.join(System.tmp_dir!(), "esr-mcp-writer-#{System.unique_integer([:positive])}")
    profile = "test"
    File.mkdir_p!(Path.join([tmp, profile, "credentials"]))

    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", profile)

    out_dir = Path.join(tmp, "mcp_out")
    File.mkdir_p!(out_dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("EZAGENT_HOME", prev_home), else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      _ = File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, out_dir: out_dir}
  end

  test "write!/1 emits mcp.json with token + agent_uri in env", %{out_dir: out_dir} do
    agent_uri = "entity://agent/team-alpha/test_writer-test-#{System.unique_integer([:positive])}"

    {:ok, path} =
      McpConfigWriter.write!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/fake/path/ezagent_mcp_bridge.py",
        ws_url: "ws://127.0.0.1:10042/agent_bridge/websocket"
      )

    assert File.exists?(path)
    config = path |> File.read!() |> Jason.decode!()

    assert config["mcpServers"]["esr-bridge"]["command"] == "uv"
    # PR #129: uv run --script <path> triggers PEP 723 metadata reading
    # so the websockets dep auto-installs on first run. `uv run python3 <path>`
    # invokes Python directly and skips PEP 723 → ModuleNotFoundError.
    assert config["mcpServers"]["esr-bridge"]["args"] ==
             ["run", "--script", "/fake/path/ezagent_mcp_bridge.py"]

    env = config["mcpServers"]["esr-bridge"]["env"]
    assert env["EZAGENT_AGENT_URI"] == agent_uri
    assert env["EZAGENT_BRIDGE_WS_URL"] == "ws://127.0.0.1:10042/agent_bridge/websocket"
    assert is_binary(env["EZAGENT_AGENT_TOKEN"])
    assert String.starts_with?(env["EZAGENT_AGENT_TOKEN"], "tok_")
  end

  test "write!/1 is token-idempotent — re-write returns the same token", %{out_dir: out_dir} do
    agent_uri = "entity://agent/team-alpha/test_writer-idempotent-#{System.unique_integer([:positive])}"

    {:ok, path1} =
      McpConfigWriter.write!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/x",
        ws_url: "ws://x"
      )

    token1 = path1 |> File.read!() |> Jason.decode!() |> get_in(["mcpServers", "esr-bridge", "env", "EZAGENT_AGENT_TOKEN"])

    {:ok, path2} =
      McpConfigWriter.write!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/x",
        ws_url: "ws://x"
      )

    token2 = path2 |> File.read!() |> Jason.decode!() |> get_in(["mcpServers", "esr-bridge", "env", "EZAGENT_AGENT_TOKEN"])

    assert token1 == token2
    assert path1 == path2

    # Verify TokenStore lookup also returns the same token.
    {:ok, lookup_uri} = TokenStore.lookup_by_token(token1)
    assert URI.to_string(lookup_uri) == agent_uri
  end

  test "write!/1 without :agent_uri raises", %{out_dir: out_dir} do
    assert_raise ArgumentError, ~r/:agent_uri/, fn ->
      McpConfigWriter.write!(dir: out_dir)
    end
  end

  test "resolve_ws_url/0 honors env override" do
    prev = System.get_env("EZAGENT_BRIDGE_WS_URL")
    System.put_env("EZAGENT_BRIDGE_WS_URL", "ws://elsewhere:9999/socket")

    try do
      assert McpConfigWriter.resolve_ws_url() == "ws://elsewhere:9999/socket"
    after
      if prev, do: System.put_env("EZAGENT_BRIDGE_WS_URL", prev), else: System.delete_env("EZAGENT_BRIDGE_WS_URL")
    end
  end

  test "bridge_script_path/0 points at v2 Python script that exists" do
    path = McpConfigWriter.bridge_script_path()
    assert File.exists?(path), "expected v2 bridge script at #{path}"
    assert Path.basename(path) == "ezagent_mcp_bridge.py"
  end

  # Allen 2026-05-21: claude's --dangerously-load-development-channels
  # looks up the server name in the cwd-level .mcp.json BEFORE
  # --mcp-config <abs>. Agents whose cwd ≠ ezagent repo root saw
  # "server:esr-bridge · no MCP server configured with that name".
  describe "agent_cwd option (regression — cwd-level .mcp.json)" do
    test "write!/1 with :agent_cwd ALSO writes .mcp.json to that dir", %{out_dir: out_dir} do
      agent_cwd = Path.join(System.tmp_dir!(), "esr-agent-cwd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(agent_cwd)
      on_exit(fn -> File.rm_rf(agent_cwd) end)

      {:ok, _path} =
        McpConfigWriter.write!(
          agent_uri: "entity://agent/team-alpha/cc_cwdtest",
          dir: out_dir,
          agent_cwd: agent_cwd
        )

      cwd_mcp = Path.join(agent_cwd, ".mcp.json")
      assert File.exists?(cwd_mcp), "expected .mcp.json written to agent cwd"

      decoded = cwd_mcp |> File.read!() |> Jason.decode!()
      assert get_in(decoded, ["mcpServers", "esr-bridge"]) != nil
    end

    test "write!/1 with non-existent :agent_cwd creates the dir + writes", %{out_dir: out_dir} do
      agent_cwd = Path.join(System.tmp_dir!(), "esr-agent-nocwd-#{System.unique_integer([:positive])}")
      refute File.exists?(agent_cwd)
      on_exit(fn -> File.rm_rf(agent_cwd) end)

      {:ok, _path} =
        McpConfigWriter.write!(
          agent_uri: "entity://agent/team-alpha/cc_mkdir",
          dir: out_dir,
          agent_cwd: agent_cwd
        )

      assert File.exists?(Path.join(agent_cwd, ".mcp.json"))
    end

    test "write!/1 without :agent_cwd skips the cwd write (back-compat)", %{out_dir: out_dir} do
      # No agent_cwd → only ~/.ezagent + git-root copies, no crash.
      {:ok, path} =
        McpConfigWriter.write!(
          agent_uri: "entity://agent/team-alpha/cc_nocwd",
          dir: out_dir
        )

      assert File.exists?(path)
    end
  end
end
