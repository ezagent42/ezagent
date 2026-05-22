defmodule EzagentDomainChat.Integration.OrchestratorMcpBridgeTest do
  @moduledoc """
  Phase 7 completion PR-5 — the orchestrator MCP TRANSPORT bridge.

  codex review of PR-5 found the CRITICAL gap: the cc-orchestrator seed
  wrote an MCP config whose command runs `orchestrator_bridge.py`, but
  no code shipped that script and `McpServer` had no live MCP stdio
  transport. PR-5's e2e called `McpServer.handle_tool_call/3` directly,
  bypassing the actual transport a live `claude` uses.

  This test proves the gap is closed — TWO ways:

  ## 1. The configured command starts a working MCP server

  `test "the seed-configured bridge command serves the 7 tool schemas
  over MCP tools/list"` does EXACTLY codex's explicit ask:

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

  ## 2. tools/call reaches the per-orchestrator McpServer

  `test "mcp_tools_call over the Channel reaches the per-orchestrator
  McpServer"` drives the BEAM-side transport: it joins
  `Ezagent.Orchestrator.McpChannel` (the bridge's BEAM endpoint) and
  pushes `mcp_tools_call`, asserting it routes to the RIGHT
  per-orchestrator `McpServer` with server-derived caller/cap/session
  context — and that a `claude`/bridge cannot spoof another
  orchestrator's identity (the Channel resolves context from the
  token-authenticated agent URI via `McpRegistry`, never from the
  payload).
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{Behavior, Capability}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Orchestrator.{CcOrchestratorSeed, McpChannel, McpRegistry, McpServer}

  # --- a minimal endpoint so Phoenix.ChannelTest can drive the Channel --

  defmodule TestEndpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :ezagent_domain_chat
  end

  @endpoint TestEndpoint

  @workspace_uri URI.new!("workspace://default")

  setup_all do
    # ChannelTest needs the endpoint configured + alive (no HTTP
    # listener required — `socket/2` / `subscribe_and_join/3` only need
    # the endpoint process + a PubSub server). Reuse the already-running
    # `EzagentCore.PubSub` so we don't start a second one.
    Application.put_env(:ezagent_domain_chat, TestEndpoint,
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
      behavior: Behavior.Template,
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
    orchestrator_uri = URI.parse("entity://agent/default/cc_orch-bridge-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  defp spawn_session do
    session_uri = URI.parse("session://generic/default/orch-bridge-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  # ======================================================================
  # 1. The CONFIGURED command starts a working MCP server (codex's ask)
  # ======================================================================

  describe "the configured bridge command serves the 7 tool schemas over MCP" do
    @tag :slow
    test "executing the seed-configured `uv run --script` command returns 7 tools on tools/list" do
      uv = System.find_executable("uv")

      if is_nil(uv) do
        # `uv` is the runtime the seed-configured command uses; without
        # it on PATH there is nothing to execute. Skip rather than
        # silently pass.
        IO.puts("SKIP — `uv` not on PATH; cannot execute the configured bridge command")
      else
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
            ]
          )

        responses = parse_jsonrpc_lines(out)

        init = Enum.find(responses, &(&1["id"] == 1))
        assert init["result"]["serverInfo"]["name"] == "esr-orchestrator",
               "the configured command must start a working MCP server. Got: #{inspect(out)}"

        list = Enum.find(responses, &(&1["id"] == 2))
        tools = list["result"]["tools"]

        assert length(tools) == 7,
               "the configured command's tools/list must return the 7 orchestrator " <>
                 "tool schemas. Got #{inspect(tools)}"

        names = tools |> Enum.map(& &1["name"]) |> MapSet.new()

        assert names ==
                 MapSet.new(~w(add_agent_slot remove_agent_slot update_agent_template
                               write_matcher update_template save_template_as list_templates)),
               "tools/list must serve exactly McpServer.tool_schemas/0's 7 tools"

        # The schemas must be the SAME ones McpServer owns — single source.
        assert names == MapSet.new(Enum.map(McpServer.tool_schemas(), & &1["name"]))
      end
    end
  end

  # ======================================================================
  # 2. tools/call over the Channel reaches the per-orchestrator McpServer
  # ======================================================================

  describe "mcp_tools_call over the Channel reaches the per-orchestrator McpServer" do
    test "a registered orchestrator's bridge join + mcp_tools_call routes to ITS McpServer" do
      session_uri = spawn_session()

      # The orchestrator's `:identity` slice carries ONLY the
      # :agent_template cap — `list_templates` (the tool exercised
      # below) needs only that. The cap is workspace-scoped, so it does
      # not need the orchestrator URI to be known at spawn time.
      caps = MapSet.new([template_cap(:agent_template, @workspace_uri)])
      orchestrator_uri = spawn_orchestrator_with_caps(caps)

      # The Generator's registration step — bind the server-derived
      # context the bridge's Channel will look up.
      :ok =
        McpRegistry.register(orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri()
        )

      # Join the Channel exactly as the bridge does: the Socket has
      # already token-authenticated `agent_uri`; the topic is keyed to it.
      {:ok, _join_reply, socket} =
        TestEndpoint
        |> socket("orchestrator_socket:#{URI.to_string(orchestrator_uri)}", %{
          agent_uri: orchestrator_uri
        })
        |> subscribe_and_join(
          McpChannel,
          "orch:bridge:#{URI.to_string(orchestrator_uri)}"
        )

      # tools/list over the Channel — the BEAM-served redundancy path.
      ref = push(socket, "mcp_tools_list", %{})
      assert_reply ref, :ok, %{"tools" => tools}
      assert length(tools) == 7

      # tools/call — list_templates. The orchestrator holds the
      # :agent_template cap → agent_templates returned, session_templates
      # gated out (cap not held). This proves the call reached the real
      # McpServer with the orchestrator's OWN caps.
      ref = push(socket, "mcp_tools_call", %{"tool" => "list_templates", "arguments" => %{}})
      assert_reply ref, :ok, result

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
      # An agent with a valid URI but no McpRegistry row — fail-closed.
      orphan = URI.parse("entity://agent/default/cc_not-an-orch-#{uniq()}")
      {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orphan})

      result =
        TestEndpoint
        |> socket("orchestrator_socket:#{URI.to_string(orphan)}", %{agent_uri: orphan})
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

      :ok =
        McpRegistry.register(orch_b,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      result =
        TestEndpoint
        # Socket authenticated as A …
        |> socket("orchestrator_socket:#{URI.to_string(orch_a)}", %{agent_uri: orch_a})
        # … but the join targets B's topic.
        |> subscribe_and_join(McpChannel, "orch:bridge:#{URI.to_string(orch_b)}")

      assert {:error, %{reason: reason}} = result
      assert reason =~ "does not match authenticated agent"
    end
  end

  # --- McpRegistry round-trip -------------------------------------------

  describe "McpRegistry binds the server-derived orchestrator context" do
    test "register/lookup round-trips the (session, workspace, owner, parent) context" do
      orch = URI.parse("entity://agent/default/cc_reg-#{uniq()}")
      session_uri = URI.parse("session://generic/default/reg-#{uniq()}")
      parent = URI.parse("template://session/default/reg-parent@abc123")

      :ok =
        McpRegistry.register(orch,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri(),
          parent_template_uri: parent
        )

      assert {:ok, ctx} = McpRegistry.lookup(orch)
      assert ctx.session_uri == session_uri
      assert ctx.workspace_uri == @workspace_uri
      assert ctx.owner_uri == User.admin_uri()
      assert ctx.parent_template_uri == parent

      :ok = McpRegistry.unregister(orch)
      assert McpRegistry.lookup(orch) == :error
    end

    test "from_orchestrator_uri/1 fails closed for an unregistered orchestrator" do
      orch = URI.parse("entity://agent/default/cc_unreg-#{uniq()}")
      assert {:error, :orchestrator_not_registered} = McpServer.from_orchestrator_uri(orch)
    end
  end

  # --- subprocess + JSON-RPC helpers ------------------------------------

  # Run the bridge command as a subprocess, feed `lines` on stdin,
  # collect stdout until both JSON-RPC replies arrive, then close the
  # port (which terminates the bridge — a Port has no stdin-only-close
  # primitive, and the synchronous tools/list reply lands well before
  # we close).
  defp run_bridge_stdio(command, args, extra_env, lines) do
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
    collect_until(port, 2, "")
  end

  # Collect stdout until `expected` JSON-RPC reply lines are seen, or a
  # generous timeout. The bridge answers tools/list synchronously, so a
  # few seconds is ample (uv's first-run dep provisioning aside — hence
  # the 60s ceiling).
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
      60_000 ->
        Port.close(port)
        flunk("bridge did not produce #{expected} JSON-RPC replies in 60s. Got: #{acc}")
    end
  end

  defp count_jsonrpc_replies(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => _, "result" => _}} -> true
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
