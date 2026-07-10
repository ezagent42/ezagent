defmodule EzagentPluginCc.McpConfigWriterTest do
  use ExUnit.Case, async: false

  alias EzagentPluginCc.McpConfigWriter
  alias Ezagent.AgentBridge.TokenStore

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
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      _ = File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, out_dir: out_dir}
  end

  test "write!/1 emits mcp.json whose env carries NO per-agent identity (clobber-safe)", %{
    out_dir: out_dir
  } do
    # Regression for the 2026-06-02 bridge-token clobber: this .mcp.json is
    # written to SHARED locations (~/.ezagent, git toplevel, cwd), so it must
    # NOT carry per-agent identity — that flows via claude's process env
    # (cmd_env) instead. See docs/superpowers/specs/2026-06-02-domain-agent-design.md.
    agent_uri = "entity://team-alpha/agent/test_writer-test-#{System.unique_integer([:positive])}"

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
    # Only the SHARED ws_url is written (identical for every agent → clobber-safe).
    assert env["EZAGENT_BRIDGE_WS_URL"] == "ws://127.0.0.1:10042/agent_bridge/websocket"
    # Per-agent identity must NOT be in the (shared) file:
    refute Map.has_key?(env, "EZAGENT_AGENT_URI")
    refute Map.has_key?(env, "EZAGENT_AGENT_TOKEN")
  end

  test "write_with_token!/1 is token-idempotent — re-write returns the same token", %{
    out_dir: out_dir
  } do
    agent_uri =
      "entity://team-alpha/agent/test_writer-idempotent-#{System.unique_integer([:positive])}"

    # The token is no longer written into the .mcp.json env block (clobber-safe);
    # read it from the RETURN value instead (which `build_claude_cmd/3` uses for
    # cmd_env).
    {:ok, path1, token1} =
      McpConfigWriter.write_with_token!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/x",
        ws_url: "ws://x"
      )

    {:ok, path2, token2} =
      McpConfigWriter.write_with_token!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/x",
        ws_url: "ws://x"
      )

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
      if prev,
        do: System.put_env("EZAGENT_BRIDGE_WS_URL", prev),
        else: System.delete_env("EZAGENT_BRIDGE_WS_URL")
    end
  end

  # Regression guard for the dev/prod divergence that left cc agents
  # unable to bind: bridge_script_path/0 must resolve to the SHIPPED
  # priv location (packaged into the release), not a compile-time
  # __DIR__-relative source path that only exists in a dev checkout.
  # The path must be (a) under :code.priv_dir(:ezagent_plugin_cc) and
  # (b) actually present on disk — the exact invariant that was missing.
  test "bridge_script_path/0 resolves under priv and the script is packaged" do
    path = McpConfigWriter.bridge_script_path()
    priv_dir = Application.app_dir(:ezagent_plugin_cc, "priv")

    assert String.starts_with?(path, priv_dir),
           "expected bridge script under priv (#{priv_dir}), got #{path} — " <>
             "a __DIR__-relative source path is absent from releases"

    assert File.exists?(path),
           "expected v2 bridge script to be packaged and present at #{path}"

    assert Path.basename(path) == "ezagent_mcp_bridge.py"
  end

  # Allen 2026-05-21: claude's --dangerously-load-development-channels
  # looks up the server name in the cwd-level .mcp.json BEFORE
  # --mcp-config <abs>. Agents whose cwd ≠ ezagent repo root saw
  # "server:esr-bridge · no MCP server configured with that name".
  describe "agent_cwd option (regression — cwd-level .mcp.json)" do
    test "write!/1 with :agent_cwd ALSO writes .mcp.json to that dir", %{out_dir: out_dir} do
      agent_cwd =
        Path.join(System.tmp_dir!(), "esr-agent-cwd-#{System.unique_integer([:positive])}")

      File.mkdir_p!(agent_cwd)
      on_exit(fn -> File.rm_rf(agent_cwd) end)

      {:ok, _path} =
        McpConfigWriter.write!(
          agent_uri: "entity://team-alpha/agent/cc_cwdtest",
          dir: out_dir,
          agent_cwd: agent_cwd
        )

      cwd_mcp = Path.join(agent_cwd, ".mcp.json")
      assert File.exists?(cwd_mcp), "expected .mcp.json written to agent cwd"

      decoded = cwd_mcp |> File.read!() |> Jason.decode!()
      assert get_in(decoded, ["mcpServers", "esr-bridge"]) != nil
    end

    test "write!/1 with non-existent :agent_cwd creates the dir + writes", %{out_dir: out_dir} do
      agent_cwd =
        Path.join(System.tmp_dir!(), "esr-agent-nocwd-#{System.unique_integer([:positive])}")

      refute File.exists?(agent_cwd)
      on_exit(fn -> File.rm_rf(agent_cwd) end)

      {:ok, _path} =
        McpConfigWriter.write!(
          agent_uri: "entity://team-alpha/agent/cc_mkdir",
          dir: out_dir,
          agent_cwd: agent_cwd
        )

      assert File.exists?(Path.join(agent_cwd, ".mcp.json"))
    end

    test "write_with_token!/1 with :config_dir writes the AUTHORITATIVE per-agent .mcp.json there (PR-3 DD-6)", %{
      out_dir: out_dir
    } do
      # PR-3: the per-agent .mcp.json the domain-allocated config_dir owns is the
      # one claude's `--mcp-config` points at. The cwd copy remains as compat.
      config_dir =
        Path.join(System.tmp_dir!(), "esr-cfgdir-mcp-#{System.unique_integer([:positive])}")

      agent_cwd =
        Path.join(System.tmp_dir!(), "esr-cwd-mcp-#{System.unique_integer([:positive])}")

      File.mkdir_p!(config_dir)
      File.mkdir_p!(agent_cwd)
      on_exit(fn -> File.rm_rf(config_dir); File.rm_rf(agent_cwd) end)

      {:ok, _path, _token} =
        McpConfigWriter.write_with_token!(
          agent_uri: "entity://team-alpha/agent/cc_cfgdir",
          dir: out_dir,
          agent_cwd: agent_cwd,
          config_dir: config_dir
        )

      cfg_mcp = Path.join(config_dir, ".mcp.json")
      assert File.exists?(cfg_mcp), "expected the authoritative .mcp.json in config_dir"
      # the cwd compat copy is still written
      assert File.exists?(Path.join(agent_cwd, ".mcp.json"))

      env = cfg_mcp |> File.read!() |> Jason.decode!() |> get_in(["mcpServers", "esr-bridge", "env"])
      assert Map.keys(env) == ["EZAGENT_BRIDGE_WS_URL"]
    end

    test "write!/1 without :agent_cwd skips the cwd write (back-compat)", %{out_dir: out_dir} do
      # No agent_cwd → only ~/.ezagent + git-root copies, no crash.
      {:ok, path} =
        McpConfigWriter.write!(
          agent_uri: "entity://team-alpha/agent/cc_nocwd",
          dir: out_dir
        )

      assert File.exists?(path)
    end
  end
end
