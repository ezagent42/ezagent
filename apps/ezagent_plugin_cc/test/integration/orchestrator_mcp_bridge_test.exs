defmodule EzagentDomainInstanceMessage.Integration.OrchestratorMcpBridgeTest.BridgeEndpoint do
  @moduledoc """
  A Phoenix endpoint with a REAL HTTP listener for the authenticated
  subprocess test — the Python bridge must actually open a WebSocket
  against `/orchestrator_socket`, which the `server: false` ChannelTest
  endpoint cannot serve. It mounts `McpSocket` (the production Socket,
  incl. its `connect/3` token-auth path) so the round-trip exercises
  the real transport, not a `ChannelTest` shortcut.

  Defined at top level (not nested in the test module) so the
  `socket/3` endpoint macro is unambiguous — `Phoenix.ChannelTest`,
  imported inside the test module, also exports a `socket/3`.
  """
  use Phoenix.Endpoint, otp_app: :ezagent_domain_session

  socket("/orchestrator_socket", Ezagent.Orchestrator.McpSocket,
    websocket: [check_origin: false],
    longpoll: false
  )
end

defmodule EzagentDomainInstanceMessage.Integration.OrchestratorMcpBridgeTest do
  @moduledoc """
  Phase 7 completion PR-5 — the orchestrator MCP TRANSPORT bridge.

  codex review of PR-5 found the CRITICAL gap: the cc-orchestrator seed
  wrote an MCP config whose command runs `orchestrator_bridge.py`, but
  no code shipped that script and `McpServer` had no live MCP stdio
  transport. PR-5's e2e called `McpServer.handle_tool_call/3` directly,
  bypassing the actual transport a live `claude` uses.

  This test proves the gap is closed — THREE ways:

  ## 1. The configured command starts a working MCP server

  `test "executing the seed-configured `uv run --script` command
  returns 7 tools on tools/list"` does EXACTLY codex's explicit ask:

  - it runs `Ezagent.Orchestrator.CcOrchestratorSeed.install_orchestrator_bridge/1`
    to ship the real script + exported schema file into a temp dir,
  - reads the `uv run --script …` command from the seed's
    `orchestrator_mcp_json/1` — the CONFIGURED command a real
    orchestrator's `claude` would run,
  - EXECUTES that command as a subprocess, speaks MCP JSON-RPC to its
    stdin (`initialize` + `tools/list`),
  - and asserts the 7 orchestrator tool schemas come back over stdout.

  If `orchestrator_bridge.py` were still missing (the codex CRITICAL
  finding), this test cannot pass — the configured command would not
  resolve.

  ## 2. tools/call reaches the per-orchestrator McpServer (Channel)

  `test "a registered orchestrator's bridge join + mcp_tools_call
  routes to ITS McpServer"` drives the BEAM-side transport: it joins
  `Ezagent.Orchestrator.McpChannel` (the bridge's BEAM endpoint) and
  pushes `mcp_tools_call`, asserting it routes to the RIGHT
  per-orchestrator `McpServer`.

  ## 3. tools/call through the REAL stdio + McpSocket auth path

  codex MEDIUM-3 — test 2 above joins the Channel directly with
  pre-populated `socket` assigns, so it never exercises the real stdio
  transport or `McpSocket.connect/3` token auth. `test "an
  authenticated bridge subprocess round-trips a tools/call through
  /orchestrator_socket"` closes that gap: it starts a real HTTP
  listener hosting `McpSocket`, mints a connect token, spawns the
  configured bridge as a subprocess with that token + agent URI, and
  drives a `tools/call` end-to-end — stdio → WebSocket → `McpSocket`
  token auth → `McpChannel` → `McpServer`.

  ## `uv` gating (codex MEDIUM-3)

  All three subprocess tests need `uv` on PATH (the configured command
  is `uv run --script …`). When `uv` is absent the tests are a REAL
  `ExUnit` skip (`@tag skip:` resolved at module-eval) — NOT a printed
  `SKIP` that lets the gate pass green without the command ever
  running.
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{ActionSet, Capability}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.{CcOrchestratorSeed, McpChannel, McpRegistry, McpServer}
  alias Ezagent.AgentBridge.TokenStore
  alias Ezagent.Session.SessionManager

  # `uv` presence is resolved ONCE at module eval. The three subprocess
  # tests below tag themselves `skip:` when it is absent — a real
  # ExUnit skip (the suite reports the test as skipped), never a
  # printed "SKIP" that would let CI pass the gate without ever
  # executing the configured `uv run --script` command.
  @uv_path System.find_executable("uv")
  @uv_skip if is_nil(@uv_path),
             do: "`uv` not on PATH — cannot execute the configured bridge command",
             else: false

  # --- a minimal endpoint so Phoenix.ChannelTest can drive the Channel --

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ezagent_domain_session
  end

  # The top-level endpoint with a REAL HTTP listener — see its own
  # moduledoc. Aliased here so the test body reads cleanly.
  alias EzagentDomainInstanceMessage.Integration.OrchestratorMcpBridgeTest.BridgeEndpoint

  @endpoint TestEndpoint

  @workspace_uri URI.new!("workspace://team-alpha")

  setup_all do
    # ChannelTest needs the endpoint configured + alive (no HTTP
    # listener required — `socket/2` / `subscribe_and_join/3` only need
    # the endpoint process + a PubSub server). Reuse the already-running
    # `EzagentCore.PubSub` so we don't start a second one.
    Application.put_env(:ezagent_domain_session, TestEndpoint,
      secret_key_base: String.duplicate("a", 64),
      pubsub_server: EzagentCore.PubSub,
      server: false
    )

    start_supervised!(TestEndpoint)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  # --- the four delegated caps (mirrors orchestrator_mcp_e2e_test) -------

  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: ActionSet.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # Spawn an orchestrator Agent Kind whose `:identity` slice carries
  # `caps` — `McpServer.from_orchestrator_uri/1` loads caps from there
  # (the agent's own slice), never from the wire.
  defp spawn_orchestrator_with_caps(caps) do
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-bridge-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  defp spawn_session do
    # SPEC v3 per-tenant authority is workspace-first: session://<ws>/<class>/<name>.
    # (The orchestrator agent is in workspace `team-alpha`; the session MUST
    # share it or the session-action dispatch trips workspace isolation — O-4.)
    session_uri = Ezagent.URI.session("team-alpha", "generic", "orch-bridge-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  # ======================================================================
  # 1. The CONFIGURED command starts a working MCP server (codex's ask)
  # ======================================================================

  describe "the configured bridge command serves the 7 tool schemas over MCP" do
    @tag :slow
    @tag skip: @uv_skip
    test "executing the seed-configured `uv run --script` command returns 7 tools on tools/list" do
      base = Path.join(System.tmp_dir!(), "orch-bridge-test-#{uniq()}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      # Ship the real bridge script + exported schema file exactly as
      # the seed does on a dev/prod boot.
      :ok = CcOrchestratorSeed.install_orchestrator_bridge(base)

      script = Path.join(base, "orchestrator_bridge.py")
      tools_json = Path.join(base, "orchestrator_tools.json")

      assert File.exists?(script),
             "the seed must SHIP orchestrator_bridge.py — codex CRITICAL: " <>
               "the pre-PR-5 config referenced a script that was never written"

      assert File.exists?(tools_json),
             "the seed must export the 7 tool schemas beside the script"

      # The seed's MCP config — the CONFIGURED command a live
      # orchestrator's `claude` runs.
      mcp_config = Jason.decode!(CcOrchestratorSeed.orchestrator_mcp_json_for_test(base))
      server = mcp_config["mcpServers"]["esr-orchestrator"]

      assert server["command"] == "uv"
      assert "run" in server["args"] and "--script" in server["args"]
      configured_script = List.last(server["args"])

      assert configured_script == script,
             "the MCP config must point at the shipped script path"

      env = server["env"]
      # The schema-file path the bridge reads tools/list from.
      tools_env = env["EZAGENT_ORCHESTRATOR_TOOLS_PATH"]
      assert tools_env == tools_json

      # EXECUTE the configured command — exactly `uv run --script
      # <script>` with the configured env — and speak MCP over stdio.
      out =
        run_bridge_stdio(
          server["command"],
          server["args"],
          %{"EZAGENT_ORCHESTRATOR_TOOLS_PATH" => tools_env},
          [
            ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}),
            ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
          ],
          2
        )

      responses = parse_jsonrpc_lines(out)

      init = Enum.find(responses, &(&1["id"] == 1))

      assert init["result"]["serverInfo"]["name"] == "esr-orchestrator",
             "the configured command must start a working MCP server. Got: #{inspect(out)}"

      list = Enum.find(responses, &(&1["id"] == 2))
      tools = list["result"]["tools"]

      expected_names = MapSet.new(Enum.map(McpServer.tool_schemas(), & &1["name"]))

      assert length(tools) == MapSet.size(expected_names),
             "the configured command's tools/list must return McpServer.tool_schemas/0's " <>
               "tools. Got #{inspect(tools)}"

      names = tools |> Enum.map(& &1["name"]) |> MapSet.new()

      # tools/list must serve EXACTLY McpServer.tool_schemas/0 — the single
      # source of truth (§3.8 rewrote this to the member/rule-set surface).
      assert names == expected_names
    end

    test "the orchestrator MCP config writes a resolved orchestrator-socket WS URL (codex C-r2-P2)" do
      base = Path.join(System.tmp_dir!(), "orch-wsurl-#{uniq()}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      # Default: no override → canonical localhost orchestrator-socket URL is
      # written explicitly (not left to the bridge's implicit fallback).
      env = Jason.decode!(CcOrchestratorSeed.orchestrator_mcp_json_for_test(base))
      server = env["mcpServers"]["esr-orchestrator"]

      assert server["env"]["EZAGENT_BRIDGE_WS_URL"] ==
               "ws://127.0.0.1:10042/orchestrator_socket/websocket"

      # A custom deployment (env override on host:port/TLS) is honored, with the
      # path swapped to the orchestrator-socket mount.
      prev = System.get_env("EZAGENT_BRIDGE_WS_URL")

      System.put_env(
        "EZAGENT_BRIDGE_WS_URL",
        "wss://orch.example.com:9443/agent_bridge/websocket"
      )

      on_exit(fn ->
        if prev,
          do: System.put_env("EZAGENT_BRIDGE_WS_URL", prev),
          else: System.delete_env("EZAGENT_BRIDGE_WS_URL")
      end)

      env2 = Jason.decode!(CcOrchestratorSeed.orchestrator_mcp_json_for_test(base))

      assert env2["mcpServers"]["esr-orchestrator"]["env"]["EZAGENT_BRIDGE_WS_URL"] ==
               "wss://orch.example.com:9443/orchestrator_socket/websocket",
             "a custom WS deployment must be honored (host/port/TLS preserved), " <>
               "pointed at the /orchestrator_socket mount — not the localhost fallback."
    end
  end

  # ======================================================================
  # 2. tools/call over the Channel reaches the per-orchestrator McpServer
  # ======================================================================

  describe "mcp_tools_call over the Channel reaches the per-orchestrator McpServer" do
    # Transport #53 Decision C — the Channel forwards the bridge token to the
    # session-domain SessionManager. These tests mint real tokens, so isolate
    # TokenStore in a sandboxed EZAGENT_HOME.
    setup do
      home = Path.join(System.tmp_dir!(), "orch-chan-home-#{uniq()}")
      File.mkdir_p!(home)
      prev_home = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", home)

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        File.rm_rf(home)
      end)

      :ok
    end

    test "a registered orchestrator's bridge join + mcp_tools_call routes to ITS McpServer" do
      session_uri = spawn_session()

      # The orchestrator's `:identity` slice carries ONLY the
      # :agent_template cap — `list_templates` (the tool exercised
      # below) needs only that. The cap is workspace-scoped, so it does
      # not need the orchestrator URI to be known at spawn time.
      caps = MapSet.new([template_cap(:agent_template, @workspace_uri)])
      orchestrator_uri = spawn_orchestrator_with_caps(caps)
      binding_epoch = Ecto.UUID.generate()

      # The Generator's registration step — bind the server-derived
      # context the bridge's Channel will look up.
      :ok =
        McpRegistry.register(orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri(),
          binding_epoch: binding_epoch
        )

      # Decision C: the SessionManager (session domain) authorizes the
      # forwarded `tools/call` by verifying the bridge token + the STRUCTURAL
      # check `binding.orchestrator_uri == working_copy.orchestrator_uri`. Wire
      # the durable field + start the SessionManager exactly as create's step-7
      # materialization does, so this end-to-end wire test exercises the real
      # session-side token gate + cap reconstruction.
      {:ok, _} =
        Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
          orchestrator_uri: %{
            uri: orchestrator_uri,
            epoch: binding_epoch,
            status: :active
          },
          orchestrator_materialization_epoch: binding_epoch
        })

      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri()
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      # Join the Channel exactly as the bridge does: the Socket has already
      # token-authenticated `agent_uri` AND stashed the connection token (the
      # bridge token) in assigns; the topic is keyed to the agent URI.
      {:ok, _join_reply, socket} =
        TestEndpoint
        |> socket("orchestrator_socket:#{URI.to_string(orchestrator_uri)}", %{
          agent_uri: orchestrator_uri,
          bridge_token: token
        })
        |> subscribe_and_join(
          McpChannel,
          "orch:bridge:#{URI.to_string(orchestrator_uri)}"
        )

      # tools/list over the Channel — the BEAM-served redundancy path.
      ref = push(socket, "mcp_tools_list", %{})
      assert_reply(ref, :ok, %{"tools" => tools})
      assert length(tools) == length(McpServer.tool_schemas())

      # tools/call — list_templates. The orchestrator holds the
      # :agent_template cap → agent_templates returned, session_templates
      # gated out (cap not held). This proves the call reached the real
      # McpServer with the orchestrator's OWN caps.
      ref = push(socket, "mcp_tools_call", %{"tool" => "list_templates", "arguments" => %{}})
      assert_reply(ref, :ok, result)

      refute result["isError"],
             "list_templates over the transport must succeed with the orchestrator's " <>
               "agent_template cap. Got: #{inspect(result)}"

      structured = result["structuredContent"]
      assert is_list(structured["agent_templates"])

      assert structured["session_templates"] == [],
             "the orchestrator holds only the :agent_template cap — session_templates " <>
               "must be gated out (the call ran with the orchestrator's OWN caps, " <>
               "not ambient admin_caps)"
    end

    test "an authenticated agent that is NOT a registered orchestrator is denied the join" do
      # An agent with a valid URI + a connection token but no McpRegistry row —
      # fail-closed.
      orphan = Ezagent.URI.new!("entity://team-alpha/agent/cc_not-an-orch-#{uniq()}")
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orphan})
      {:ok, token} = TokenStore.mint(orphan)

      result =
        TestEndpoint
        |> socket("orchestrator_socket:#{URI.to_string(orphan)}", %{
          agent_uri: orphan,
          bridge_token: token
        })
        |> subscribe_and_join(McpChannel, "orch:bridge:#{URI.to_string(orphan)}")

      assert {:error, %{reason: reason}} = result
      assert reason =~ "not a registered orchestrator"
    end

    test "the bridge cannot join a topic for an orchestrator whose token it lacks" do
      # The Socket authenticated agent A; a join for B's topic must fail
      # — no orchestrator-identity spoofing across the transport.
      session_uri = spawn_session()
      orch_a = spawn_orchestrator_with_caps(MapSet.new())
      orch_b = spawn_orchestrator_with_caps(MapSet.new())
      {:ok, token_a} = TokenStore.mint(orch_a)

      :ok =
        McpRegistry.register(orch_b,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          binding_epoch: Ecto.UUID.generate()
        )

      result =
        TestEndpoint
        # Socket authenticated as A …
        |> socket("orchestrator_socket:#{URI.to_string(orch_a)}", %{
          agent_uri: orch_a,
          bridge_token: token_a
        })
        # … but the join targets B's topic.
        |> subscribe_and_join(McpChannel, "orch:bridge:#{URI.to_string(orch_b)}")

      assert {:error, %{reason: reason}} = result
      assert reason =~ "does not match authenticated agent"
    end
  end

  # ======================================================================
  # 3. tools/call through the REAL stdio + McpSocket auth path (codex MED-3)
  # ======================================================================

  describe "an authenticated bridge subprocess round-trips a tools/call" do
    @tag :slow
    @tag skip: @uv_skip
    @tag timeout: 90_000
    test "stdio -> /orchestrator_socket -> McpSocket auth -> McpChannel -> McpServer" do
      # --- 1. an isolated EZAGENT_HOME so TokenStore.mint is sandboxed ---
      home = Path.join(System.tmp_dir!(), "orch-bridge-home-#{uniq()}")
      File.mkdir_p!(home)
      prev_home = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", home)

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        File.rm_rf(home)
      end)

      # --- 2. a REAL HTTP listener hosting McpSocket on a free port ----
      port = free_tcp_port()

      Application.put_env(:ezagent_domain_session, BridgeEndpoint,
        # Bandit — the project's adapter (config/config.exs sets it for
        # EzagentWeb.Endpoint; this ad-hoc test endpoint must opt in
        # explicitly or Phoenix defaults to the unavailable Cowboy).
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: port],
        secret_key_base: String.duplicate("b", 64),
        pubsub_server: EzagentCore.PubSub,
        server: true
      )

      start_supervised!(BridgeEndpoint)

      # --- 3. a registered orchestrator with a minted connect token ----
      session_uri = spawn_session()
      caps = MapSet.new([template_cap(:agent_template, @workspace_uri)])
      orchestrator_uri = spawn_orchestrator_with_caps(caps)
      binding_epoch = Ecto.UUID.generate()

      :ok =
        McpRegistry.register(orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri(),
          binding_epoch: binding_epoch
        )

      # Decision C: wire the durable orchestrator_uri + start the SessionManager
      # so the session-side token gate + structural caller-is-our-orchestrator
      # gate pass for the forwarded tools/call.
      {:ok, _} =
        Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
          orchestrator_uri: %{
            uri: orchestrator_uri,
            epoch: binding_epoch,
            status: :active
          },
          orchestrator_materialization_epoch: binding_epoch
        })

      # The token `McpSocket.connect/3` will verify — minted by the same
      # TokenStore the cc Template Class uses for a cc-flavored agent. It is the
      # SAME secret the SessionManager verifies on each forwarded tools/call.
      {:ok, token} = TokenStore.mint(orchestrator_uri)

      {:ok, _sm} =
        SessionManager.ensure_started(
          orchestrator_uri: orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri()
        )

      on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

      # --- 4. ship the configured bridge into a temp dir --------------
      base = Path.join(System.tmp_dir!(), "orch-bridge-auth-#{uniq()}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      :ok = CcOrchestratorSeed.install_orchestrator_bridge(base)

      mcp_config = Jason.decode!(CcOrchestratorSeed.orchestrator_mcp_json_for_test(base))
      server = mcp_config["mcpServers"]["esr-orchestrator"]
      tools_env = server["env"]["EZAGENT_ORCHESTRATOR_TOOLS_PATH"]

      ws_url = "ws://127.0.0.1:#{port}/orchestrator_socket/websocket"

      # --- 5. EXECUTE the configured command with the auth env -------
      # The bridge connects to the real /orchestrator_socket, presents
      # the token, joins orch:bridge:<uri>, then forwards tools/call.
      out =
        run_bridge_stdio(
          server["command"],
          server["args"],
          %{
            "EZAGENT_ORCHESTRATOR_TOOLS_PATH" => tools_env,
            "EZAGENT_BRIDGE_WS_URL" => ws_url,
            "EZAGENT_AGENT_URI" => URI.to_string(orchestrator_uri),
            "EZAGENT_AGENT_TOKEN" => token,
            "EZAGENT_HOME" => home
          },
          [
            ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}),
            ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_templates","arguments":{}}})
          ],
          2
        )

      responses = parse_jsonrpc_lines(out)

      init = Enum.find(responses, &(&1["id"] == 1))

      assert init["result"]["serverInfo"]["name"] == "esr-orchestrator",
             "the configured command must start a working MCP server. Got: #{inspect(out)}"

      call = Enum.find(responses, &(&1["id"] == 2))

      assert call,
             "no tools/call reply — the bridge did not round-trip through " <>
               "/orchestrator_socket. Got: #{inspect(out)}"

      result = call["result"]

      refute result["isError"],
             "list_templates over the REAL stdio + McpSocket auth transport must " <>
               "succeed with the orchestrator's agent_template cap. Got: #{inspect(result)}"

      structured = result["structuredContent"]

      assert is_list(structured["agent_templates"]),
             "the tools/call must reach the per-orchestrator McpServer and return " <>
               "structured content. Got: #{inspect(result)}"

      assert structured["session_templates"] == [],
             "session_templates must be gated out — the call ran through the real " <>
               "McpSocket-authenticated transport with the orchestrator's OWN caps"
    end
  end

  # --- Decision C §6 (3a): the cc → SessionManager hop carries NO caps -----

  describe "the cc transport hop is caps-free (Decision C §6 3a)" do
    test "handle_tool_call forwards {:run_tool, tool, args, bridge_token} with NO caps" do
      orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_nocaps-#{uniq()}")
      token = "tok_cc-hop-#{uniq()}"

      # Stand in for the per-orchestrator SessionManager: register a plain test
      # process under the SAME Registry name + key the cc transport looks up, so
      # we capture the EXACT message the cc hop sends.
      {:ok, _} =
        Registry.register(
          Ezagent.Session.SessionManagerRegistry,
          URI.to_string(orchestrator_uri),
          nil
        )

      {:ok, ctx} =
        McpServer.new(orchestrator_uri: orchestrator_uri, bridge_token: token)

      parent = self()

      # handle_tool_call does a blocking GenServer.call; run it in a task and
      # reply from this process (which is the registered "SessionManager").
      task =
        Task.async(fn ->
          McpServer.handle_tool_call(ctx, "list_templates", %{"name_filter" => "x"})
        end)

      assert_receive {:"$gen_call", from, message}, 1_000
      GenServer.reply(from, {:ok, %{ok: true}})
      _ = Task.await(task)
      _ = parent

      assert {:run_tool, "list_templates", %{"name_filter" => "x"}, ^token} = message,
             "the cc → SessionManager message MUST be {:run_tool, tool, args, bridge_token} — " <>
               "tool/args + the connection credential ONLY, NEVER caps."

      # Belt-and-suspenders: NOTHING in the message resembles a capability set.
      refute Enum.any?(Tuple.to_list(message), &match?(%MapSet{}, &1)),
             "the cc hop must carry NO MapSet (caps) — caps are reconstructed session-side."
    end
  end

  # --- McpRegistry round-trip -------------------------------------------

  describe "McpRegistry binds the server-derived orchestrator context" do
    test "register/lookup round-trips the (session, workspace, owner, parent) context" do
      orch = Ezagent.URI.new!("entity://team-alpha/agent/cc_reg-#{uniq()}")
      session_uri = Ezagent.URI.new!("session://generic/team-alpha/reg-#{uniq()}")
      parent = Ezagent.URI.new!("template://team-alpha/session/reg-parent@abc123")

      :ok =
        McpRegistry.register(orch,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri(),
          parent_template_uri: parent,
          binding_epoch: "epoch-registry-round-trip"
        )

      assert {:ok, ctx} = McpRegistry.lookup(orch)
      assert ctx.session_uri == session_uri
      assert ctx.workspace_uri == @workspace_uri
      assert ctx.owner_uri == User.admin_uri()
      assert ctx.parent_template_uri == parent
      assert ctx.binding_epoch == "epoch-registry-round-trip"

      :ok = McpRegistry.unregister(orch)
      assert McpRegistry.lookup(orch) == :error
    end

    test "from_orchestrator_uri/1 fails closed for an unregistered orchestrator" do
      orch = Ezagent.URI.new!("entity://team-alpha/agent/cc_unreg-#{uniq()}")
      assert {:error, :orchestrator_not_registered} = McpServer.from_orchestrator_uri(orch)
    end
  end

  # --- subprocess + JSON-RPC helpers ------------------------------------

  # Pick a free TCP port by binding one momentarily and reading the
  # OS-assigned port. A tiny race window remains between close and the
  # endpoint re-binding it; acceptable for a test helper.
  defp free_tcp_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  # Run the bridge command as a subprocess, feed `lines` on stdin,
  # collect stdout until `expected` JSON-RPC replies arrive, then close
  # the port (which terminates the bridge — a Port has no
  # stdin-only-close primitive).
  defp run_bridge_stdio(command, args, extra_env, lines, expected) do
    port_env =
      Enum.map(extra_env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, System.find_executable(command)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: port_env
      ])

    Enum.each(lines, fn line -> Port.command(port, line <> "\n") end)
    collect_until(port, expected, "")
  end

  # Collect stdout until `expected` JSON-RPC reply lines are seen, or a
  # generous timeout. The bridge answers tools/list synchronously and a
  # tools/call within a couple of seconds once joined; the 75s ceiling
  # absorbs uv's first-run dep provisioning.
  defp collect_until(port, expected, acc) do
    receive do
      {^port, {:data, chunk}} ->
        acc = acc <> chunk

        if count_jsonrpc_replies(acc) >= expected do
          Port.close(port)
          acc
        else
          collect_until(port, expected, acc)
        end

      {^port, {:exit_status, _}} ->
        acc
    after
      75_000 ->
        Port.close(port)
        flunk("bridge did not produce #{expected} JSON-RPC replies in 75s. Got: #{acc}")
    end
  end

  defp count_jsonrpc_replies(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => _, "result" => _}} -> true
        {:ok, %{"id" => _, "error" => _}} -> true
        _ -> false
      end
    end)
  end

  defp parse_jsonrpc_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => _} = m} -> [m]
        _ -> []
      end
    end)
  end
end
