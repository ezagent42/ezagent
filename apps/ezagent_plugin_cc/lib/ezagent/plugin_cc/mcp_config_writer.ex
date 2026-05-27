defmodule EzagentPluginCc.McpConfigWriter do
  @moduledoc """
  Writes the `.mcp.json` Claude Code consumes via `--mcp-config` for
  the v2 CC channel bridge.

  Replaces the v1 prototype's MCP-config writer (HTTP/SSE wire)
  with a v2-shaped config that points Claude at the WebSocket Python
  client script + injects the WS URL, agent URI, and per-instance
  connect token.

  ## Output

  - **Primary:** `~/.ezagent/bridge.mcp.json` (configurable
    via `Application.get_env(:ezagent_plugin_cc, :mcp_config_dir)`).
  - **Project root copy:** `<git toplevel>/.mcp.json` — Claude's
    `--dangerously-load-development-channels` flag looks up the server
    name in project/user MCP configs **before** reading
    `--mcp-config <abs>`. Without the project-level file, Claude
    prints `server:esr-bridge · no MCP server configured`. The
    project-level copy suppresses that warning; `--mcp-config <abs>`
    remains for explicit pathing.

  ## Why a token

  v1 had no auth — any process that could reach the HTTP port could
  announce as any agent_uri. v2 gates the WS join via
  `Ezagent.AgentBridge.TokenStore`. `write!/1` mints (idempotent) a
  token for `agent_uri` and bakes it into the mcp.json env block so
  the Python bridge can present it on join.

  ## Decision #131 preservation

  PtyServer (`apps/ezagent_plugin_cc/lib/esr/plugin_cc_pty/pty_server.ex`)
  passes `agent_uri: URI.to_string(state.agent_uri)` when calling this
  writer — the URI is known at spawn time, so it rides in mcp.json
  deterministically instead of leaking via the operator's shell env.
  """

  alias Ezagent.AgentBridge.TokenStore

  @default_dir Path.expand("~/.ezagent")
  @config_filename "bridge.mcp.json"

  @doc """
  Write the v2 bridge mcp.json. Returns `{:ok, abs_path}`.

  See `write_with_token!/1` for the variant that also returns the
  minted connect token — needed when the caller wants to export the
  agent URI + token into the `claude` process env so OTHER MCP
  servers `claude` launches (e.g. the orchestrator MCP transport
  bridge) can authenticate to the same per-instance identity.

  Required opt:
  - `:agent_uri` — string. Used both as the WS join target and the
    TokenStore key.

  Optional opts:
  - `:dir` — override output directory.
  - `:script_path` — override Python WS-client script path (for tests).
  - `:ws_url` — override the WebSocket endpoint URL (defaults to
    `EZAGENT_BRIDGE_WS_URL` env / `:ws_url` app config /
    `ws://127.0.0.1:10042/agent_bridge/websocket`).
  - `:agent_cwd` — agent's working directory. When provided, ALSO
    writes `.mcp.json` to that directory. Without this, Claude
    launched with cwd=<agent_cwd> can't find the project-level
    `.mcp.json` and prints "server:esr-bridge · no MCP server
    configured with that name" warning (Allen 2026-05-21).
  """
  @spec write!(keyword()) :: {:ok, String.t()}
  def write!(opts) do
    {:ok, path, _token} = write_with_token!(opts)
    {:ok, path}
  end

  @doc """
  Like `write!/1`, but ALSO returns the per-instance connect token:
  `{:ok, abs_path, token}`.

  The token is what gates the WS bridge join
  (`Ezagent.AgentBridge.Socket` / `Ezagent.Orchestrator.McpSocket`).
  A caller that wants `claude`'s
  OTHER MCP servers to authenticate as the same agent (the
  orchestrator MCP transport bridge does — it joins
  `orch:bridge:<orchestrator_uri>` with this exact token) exports the
  agent URI + token into the `claude` process env so every MCP-server
  subprocess `claude` launches inherits them.

  Minting is idempotent per `agent_uri` (`TokenStore.mint/1`), so this
  returns the SAME token `write!/1` baked into the esr-bridge config —
  no second credential, no spoofing surface.
  """
  @spec write_with_token!(keyword()) :: {:ok, String.t(), String.t()}
  def write_with_token!(opts) do
    agent_uri_str =
      Keyword.get(opts, :agent_uri) ||
        raise ArgumentError,
              "EzagentPluginCc.McpConfigWriter.write_with_token!/1 requires :agent_uri"

    {:ok, token} = mint_token!(agent_uri_str)

    dir = Keyword.get(opts, :dir, Application.get_env(:ezagent_plugin_cc, :mcp_config_dir, @default_dir))
    File.mkdir_p!(dir)

    script_path = Keyword.get(opts, :script_path, bridge_script_path())
    ws_url = Keyword.get(opts, :ws_url, resolve_ws_url())
    agent_cwd = Keyword.get(opts, :agent_cwd)

    env = %{
      "EZAGENT_BRIDGE_WS_URL" => ws_url,
      "EZAGENT_AGENT_URI" => agent_uri_str,
      "EZAGENT_AGENT_TOKEN" => token
    }

    # PR #129: use `uv run --script <path>` so uv honors the PEP 723
    # inline metadata header (`# /// script` block) and provisions the
    # `websockets` dep on first run. Without `--script`, `uv run python3 <path>`
    # invokes Python directly and skips PEP 723 → `ModuleNotFoundError:
    # No module named 'websockets'` at startup (Allen 2026-05-19 03:12).
    config = %{
      "mcpServers" => %{
        "esr-bridge" => %{
          "command" => "uv",
          "args" => ["run", "--script", script_path],
          "env" => env
        }
      }
    }

    encoded = Jason.encode!(config, pretty: true)

    path = Path.join(dir, @config_filename)
    File.write!(path, encoded)

    # Also write to project root so Claude's startup name lookup hits
    # the same config. Anchored on git toplevel so this works
    # regardless of cwd.
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} ->
        root = String.trim(root)
        project_mcp = Path.join(root, ".mcp.json")
        File.write!(project_mcp, encoded)

      _ ->
        :ok
    end

    # Allen 2026-05-21: also write to the agent's actual working
    # directory. Claude's `--dangerously-load-development-channels`
    # flag triggers a name lookup in the cwd-level `.mcp.json` BEFORE
    # `--mcp-config <abs>` is consulted. Without this third write,
    # any agent whose cwd ≠ the ezagent repo root sees the warning
    # "server:esr-bridge · no MCP server configured with that name".
    # Messages still flow via the WS bridge (channel ≠ MCP server)
    # but the warning is real diagnostic noise.
    case agent_cwd do
      cwd when is_binary(cwd) and cwd != "" ->
        if File.dir?(cwd) do
          agent_mcp = Path.join(cwd, ".mcp.json")
          File.write!(agent_mcp, encoded)
        else
          # cwd doesn't exist yet; agent template will create it.
          # Try once with mkdir_p; tolerate failure (cosmetic warning
          # only — bridge still works via WS).
          try do
            File.mkdir_p!(cwd)
            File.write!(Path.join(cwd, ".mcp.json"), encoded)
          rescue
            _ -> :ok
          end
        end

      _ ->
        :ok
    end

    {:ok, path, token}
  end

  @doc "Absolute path of the v2 Python bridge script."
  @spec bridge_script_path() :: String.t()
  def bridge_script_path do
    Path.expand("../../../python/ezagent_mcp_bridge.py", __DIR__)
  end

  @doc """
  Resolved WebSocket URL for the bridge.

  Lookup order:
  1. `EZAGENT_BRIDGE_WS_URL` environment variable
  2. `Application.get_env(:ezagent_plugin_cc, :ws_url)`
  3. `ws://127.0.0.1:10042/agent_bridge/websocket` (canonical PR-C mount)
  """
  @spec resolve_ws_url() :: String.t()
  def resolve_ws_url do
    System.get_env("EZAGENT_BRIDGE_WS_URL") ||
      Application.get_env(:ezagent_plugin_cc, :ws_url) ||
      "ws://127.0.0.1:10042/agent_bridge/websocket"
  end

  defp mint_token!(agent_uri_str) when is_binary(agent_uri_str) do
    agent_uri = Ezagent.URI.parse!(agent_uri_str)

    case TokenStore.mint(agent_uri) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> raise "TokenStore.mint failed for #{agent_uri_str}: #{inspect(reason)}"
    end
  end
end
