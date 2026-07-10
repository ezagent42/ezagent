defmodule EzagentPluginCc.McpConfigWriter do
  @moduledoc """
  Writes the `.mcp.json` Claude Code consumes via `--mcp-config` for
  the v2 CC channel bridge.

  Replaces the v1 prototype's MCP-config writer (HTTP/SSE wire)
  with a v2-shaped config that points Claude at the WebSocket Python
  client script + injects the WS URL, agent URI, and per-instance
  connect token.

  ## Output

  - **Primary:** `<system://plugins>/bridge.mcp.json` (configurable
    via `Application.get_env(:ezagent_plugin_cc, :mcp_config_dir)`).
    The default dir resolves through the post-Resource-unification
    `system://` seam (`Ezagent.System.FsResolver` — the sanctioned home
    resolver for node-global plugin artifacts, SPEC §10 OI-3), NOT a
    hardcoded tilde-expand of the home dir.
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
  token for `agent_uri` and RETURNS it (via `write_with_token!/1`). The
  token is NOT written into the mcp.json env block — that file is shared
  across agents (see `## Output`), so a per-agent token there would be
  clobbered by a later spawn (2026-06-02 bug). Instead the caller
  (`CcAgent.build_claude_cmd/3`) exports the agent URI + token into
  claude's PROCESS env (`cmd_env`); the Python bridge reads them from
  `os.environ` and every MCP server claude launches inherits them.

  ## Decision #131 preservation

  PtyServer (`apps/ezagent_plugin_cc/lib/esr/plugin_cc_pty/pty_server.ex`)
  passes `agent_uri: URI.to_string(state.agent_uri)` when calling this
  writer — the URI is known at spawn time, so it rides in mcp.json
  deterministically instead of leaking via the operator's shell env.
  """

  alias Ezagent.AgentBridge.TokenStore

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

  Minting is idempotent per `agent_uri` (`TokenStore.mint/1`), so the
  returned token is stable per agent — one credential, exported into
  `cmd_env` by the caller (NOT written into the shared esr-bridge config),
  no spoofing surface.

  ## Orchestrator second server (orchestrator agents only)

  When `:orchestrator` is `true`, a SECOND `mcpServers` entry
  (`"esr-orchestrator"`, running `orchestrator_bridge.py`) is written so a live
  orchestrator's `claude` launches the bridge that joins `orch:bridge:<uri>` —
  the join that flips orchestrator transport-readiness. The caller gates this on
  the agent's `role == "orchestrator"` (flavor-agnostic: cc AND cc-deepseek).
  Orchestrator opts:

  - `:orchestrator` — `true` to write the second server (default `false`).
  - `:orchestrator_ws_url` — the `/orchestrator_socket` WS URL for the entry's
    `EZAGENT_BRIDGE_WS_URL` (distinct from the esr-bridge `/agent_bridge` mount).
  - `:orchestrator_tools_path` — path to the exported 7-tool schema JSON, for
    `EZAGENT_ORCHESTRATOR_TOOLS_PATH` (omitted when nil → bridge uses its
    next-to-script default).
  - `:orchestrator_script_path` — override the bridge script path (tests).
  """
  @spec write_with_token!(keyword()) :: {:ok, String.t(), String.t()}
  def write_with_token!(opts) do
    agent_uri_str =
      Keyword.get(opts, :agent_uri) ||
        raise ArgumentError,
              "EzagentPluginCc.McpConfigWriter.write_with_token!/1 requires :agent_uri"

    {:ok, token} = mint_token!(agent_uri_str)

    dir =
      Keyword.get(
        opts,
        :dir,
        Application.get_env(:ezagent_plugin_cc, :mcp_config_dir, default_dir())
      )

    File.mkdir_p!(dir)

    script_path = Keyword.get(opts, :script_path, bridge_script_path())
    ws_url = Keyword.get(opts, :ws_url, resolve_ws_url())
    agent_cwd = Keyword.get(opts, :agent_cwd)

    # Per-agent identity (URI + token) is intentionally NOT written into this
    # env block. This config is written to THREE locations (the shared
    # `~/.ezagent` dir, the git toplevel, and the agent cwd — see below); a
    # later agent's write would clobber a per-agent token here, and claude
    # would then launch the esr-bridge MCP server under the WRONG agent's
    # identity → it joins `agent_bridge:cc:<wrong-uri>` → the real agent audits
    # `:no_bridge` and silently drops inbound (the 2026-06-02 clobber bug).
    # Identity instead flows via claude's PROCESS env (`cmd_env`, set per-agent
    # in `CcAgent.build_claude_cmd/3`), which every MCP server claude launches
    # inherits. Only the SHARED `ws_url` (identical for every agent) is safe to
    # bake into this shared file. The `token` is still minted above + returned
    # so `build_claude_cmd/3` can put it into `cmd_env`.
    env = %{"EZAGENT_BRIDGE_WS_URL" => ws_url}

    # PR #129: use `uv run --script <path>` so uv honors the PEP 723
    # inline metadata header (`# /// script` block) and provisions the
    # `websockets` dep on first run. Without `--script`, `uv run python3 <path>`
    # invokes Python directly and skips PEP 723 → `ModuleNotFoundError:
    # No module named 'websockets'` at startup (Allen 2026-05-19 03:12).
    mcp_servers = %{
      "esr-bridge" => %{
        "command" => "uv",
        "args" => ["run", "--script", script_path],
        "env" => env
      }
    }

    # ORCHESTRATOR-ONLY second server (transport #53 / Phase 7 PR-5). A live
    # orchestrator's readiness is gated on the `orch:bridge:<uri>` join
    # (`Ezagent.Agent.LiveJoinRegistry.mark_joined`, fired ONLY from
    # `Ezagent.Orchestrator.McpChannel.join/3`), which fires ONLY if claude
    # actually launches `orchestrator_bridge.py`. That bridge must therefore be
    # in the .mcp.json claude's PRIMARY `--mcp-config` points at (the per-agent
    # `config_dir/.mcp.json` this writer produces) — the previous seed path wrote
    # it into a SEPARATE `orchestrator.mcp.json` threaded as an ADDITIVE
    # `--mcp-config` appended LAST, which shadowed/raced the primary file and
    # did not reliably fire on a deployed node (live E2E). Only orchestrator
    # agents (gated by the caller on `role == "orchestrator"`, flavor-agnostic —
    # cc AND cc-deepseek) get this entry; normal cc agents never do.
    #
    # The script resolves at RUNTIME from installed `priv/` (reuse the
    # esr-bridge #1325 pattern), NOT a copied sandbox file. AGENT_URI + the
    # connect TOKEN are inherited from claude's process env (`cmd_env`, set for
    # every cc agent) — the SAME token minted above — so they are NOT baked into
    # this shared file. Only the orchestrator-socket WS URL + the exported
    # tool-schema path (both orchestrator-specific, caller-supplied) live here.
    mcp_servers =
      if Keyword.get(opts, :orchestrator, false) do
        orch_env =
          %{"EZAGENT_BRIDGE_WS_URL" => Keyword.get(opts, :orchestrator_ws_url)}
          |> maybe_put(
            "EZAGENT_ORCHESTRATOR_TOOLS_PATH",
            Keyword.get(opts, :orchestrator_tools_path)
          )

        Map.put(mcp_servers, "esr-orchestrator", %{
          "command" => "uv",
          "args" => [
            "run",
            "--script",
            Keyword.get(opts, :orchestrator_script_path, orchestrator_bridge_script_path())
          ],
          "env" => orch_env
        })
      else
        mcp_servers
      end

    config = %{"mcpServers" => mcp_servers}

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

    # PR-3 (domain.agent D2/DD-6): the AUTHORITATIVE per-agent .mcp.json lives in
    # the domain-allocated `config_dir` (the sandbox-owned per-agent config home)
    # — that is the file claude's `--mcp-config` points at (set in
    # `CcAgent.build_claude_cmd/3`). The cwd / git-toplevel / `~/.ezagent` copies
    # above remain only as compat surfaces for claude's dev-channel name-lookup
    # (content-identical, no per-agent identity). Routing the per-agent write
    # through the sandbox dir is the PR-3 "single owner" consolidation.
    case Keyword.get(opts, :config_dir) do
      d when is_binary(d) and d != "" ->
        File.mkdir_p!(d)
        File.write!(Path.join(d, ".mcp.json"), encoded)

      _ ->
        :ok
    end

    {:ok, path, token}
  end

  @doc """
  Absolute path of the v2 Python bridge script.

  Resolved at RUNTIME from the app's installed `priv/` directory via
  `Application.app_dir/2`, NOT a compile-time `__DIR__`-relative source
  path. The former resolves to the real packaged location in both a dev
  checkout AND a release; the latter points at `apps/.../python/...`,
  which is absent from a `mix release` (only `priv/` is packaged). That
  divergence meant the esr-bridge MCP sidecar was never present on a
  deployed node, so no cc agent ever bound. The script therefore lives
  under `priv/python/` alongside `ezagent_cc_sdk_worker.py`.
  """
  @spec bridge_script_path() :: String.t()
  def bridge_script_path do
    Application.app_dir(:ezagent_plugin_cc, "priv/python/ezagent_mcp_bridge.py")
  end

  @doc """
  Absolute path of the orchestrator MCP transport-bridge script
  (`orchestrator_bridge.py`), resolved at RUNTIME from the app's installed
  `priv/` directory — the SAME reliability property `bridge_script_path/0` gives
  the esr-bridge (#1325): the packaged `priv/` location exists in both a dev
  checkout and a `mix release`, and it never depends on a per-agent sandbox copy
  landing on disk. Only the orchestrator `.mcp.json` entry references it.
  """
  @spec orchestrator_bridge_script_path() :: String.t()
  def orchestrator_bridge_script_path do
    Application.app_dir(:ezagent_plugin_cc, "priv/orchestrator_bridge.py")
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

  # Default output dir for the shared bridge config. Resolves through the
  # post-Resource-unification `system://` seam (the same idiom
  # `EzagentPluginFeishu.Application` uses for its plugins dir) instead of a
  # hardcoded tilde-expand of the home dir — node-global plugin artifacts route
  # through `Ezagent.System.FsResolver`, the sanctioned single `Ezagent.Home`
  # chokepoint (SPEC §10 OI-3). Resolved at call time (not a compile-time module
  # attr) so `EZAGENT_HOME`/`EZAGENT_PROFILE` are honored per run.
  defp default_dir do
    Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("plugins"))
  end

  # Include a key only when its value is a non-empty binary. The orchestrator
  # bridge falls back to its own default tool-schema path when the env var is
  # absent, so an unresolved path must be omitted rather than written as `nil`.
  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value), do: map

  defp mint_token!(agent_uri_str) when is_binary(agent_uri_str) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    case TokenStore.mint(agent_uri) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> raise "TokenStore.mint failed for #{agent_uri_str}: #{inspect(reason)}"
    end
  end
end
