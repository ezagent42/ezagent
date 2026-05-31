defmodule Ezagent.Orchestrator.McpChannel do
  @moduledoc """
  Phoenix.Channel hosting one orchestrator MCP transport-bridge
  session (Phase 7 completion SPEC §2 "PR-5").

  ## What this is

  The BEAM-side endpoint of the orchestrator MCP transport bridge.
  The MCP stdio bridge (`priv/orchestrator_bridge.py`) speaks the MCP
  protocol to a live `claude` orchestrator over stdio and forwards the
  two MCP methods it cannot answer locally onto this Channel:

  - `mcp_tools_list` → the 7 orchestrator tool JSON schemas
    (`Ezagent.Orchestrator.McpServer.tool_schemas/0`). The bridge
    answers `tools/list` from a schema file shipped beside it, so this
    Channel event is a redundancy / liveness path — but it is served
    so the wire is self-contained.
  - `mcp_tools_call` → routed to the per-orchestrator
    `Ezagent.Orchestrator.McpServer`, which runs the named tool with
    the orchestrator's four delegated caps as `ctx` and returns a
    structured MCP result.

  Topic shape `orch:bridge:<orchestrator_uri>` — the URI MUST equal the
  token-authenticated `socket.assigns.agent_uri` (`join/3` asserts it).
  This mirrors AgentBridge.Channel's topic discipline.

  ## Identity / caps / session are server-derived — no spoofing

  On join, the Channel resolves the bound `%McpServer{}` ENTIRELY from
  `socket.assigns.agent_uri` (the token-authenticated value) via
  `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1`:

  - the session / workspace / owner / parent-template come from
    `Ezagent.Orchestrator.McpRegistry` — the binding the Generator
    registered when it spawned this orchestrator;
  - the four delegated caps are loaded from the orchestrator agent's
    own `:identity` slice.

  Nothing in any `mcp_tools_call` payload influences caller, caps, or
  session. The `tool` name + its `arguments` are the ONLY wire input,
  and `McpServer.handle_tool_call/3` enforces CapBAC on every tool
  with the server-bound caps. A `claude` process therefore cannot
  spoof another orchestrator's authority — it can only call its OWN 7
  tools, gated by its OWN delegated caps.

  ## Why a separate Channel module (not the cc Channel)

  AgentBridge.Channel carries the inbound/outbound CHAT bridge
  (the `reply` tool, `to_claude` notifications). The orchestrator MCP
  surface is a different concern (7 privileged orchestration tools)
  and a different message set — keeping it a separate Channel keeps
  the two transports independently evolvable.
  """
  use Phoenix.Channel

  require Logger

  alias Ezagent.Orchestrator.McpServer

  # 2026-05-31 orchestrator-startup-atomicity §5 — the async readiness
  # signal. A LIVE claude orchestrator's stdio bridge JOINing this Channel
  # (and resolving to a registered `%McpServer{}`) is the SINGLE definitive
  # signal that the orchestrator is functional end-to-end (PTY up → claude
  # up → MCP bridge up → registered). The creating process (the §5 30s
  # gate in `Ezagent.Entity.Session.ensure_orchestrator/3`) subscribes to
  # this topic BEFORE spawning the PTY, then `receive`s filtered by URI.
  @orch_lifecycle_topic "orch:lifecycle"

  @doc "PubSub topic the readiness signal is broadcast on (§5)."
  def lifecycle_topic, do: @orch_lifecycle_topic

  @impl true
  def join("orch:bridge:" <> topic_uri, _params, socket) do
    claimed = topic_uri
    agent_uri_str = URI.to_string(socket.assigns.agent_uri)

    cond do
      claimed != agent_uri_str ->
        # The topic URI MUST equal the token-authenticated agent URI.
        # A bridge cannot join a topic for an orchestrator whose token
        # it does not hold.
        {:error, %{reason: "topic does not match authenticated agent"}}

      true ->
        case McpServer.from_orchestrator_uri(socket.assigns.agent_uri) do
          {:ok, %McpServer{} = mcp} ->
            # 2026-05-31 orchestrator-startup-atomicity §5 — record the
            # live-join as DURABLE STATE. This is the SINGLE definitive
            # confirmation the orchestrator is functional end-to-end
            # (PTY up → claude up → MCP bridge up → registered). The §5
            # startup gate (`Session.await_orchestrator_ready/3`) POLLS
            # `LiveJoinRegistry.joined?/1` on a bounded loop, so it cannot
            # miss a join that already happened — the fire-once broadcast
            # below was lost whenever the gate's `receive` was not yet
            # parked, killing a working orchestrator + rolling back create
            # with empty members.
            :ok = Ezagent.Orchestrator.LiveJoinRegistry.mark_joined(socket.assigns.agent_uri)

            # KEEP the broadcast as an INSTANT-WAKE optimization for the
            # poll. The URI is the token-authenticated `agent_uri` (== the
            # registered orchestrator URI); the gate filters by it.
            # Fire-and-forget — a no-subscriber broadcast is a harmless
            # no-op (the gate may not be running, e.g. a reconnect after a
            # prior successful create).
            :ok =
              Phoenix.PubSub.broadcast(
                EzagentCore.PubSub,
                @orch_lifecycle_topic,
                {:orchestrator_ready, socket.assigns.agent_uri}
              )

            {:ok, assign(socket, :mcp, mcp)}

          {:error, reason} ->
            # The agent authenticated, but is not a registered
            # orchestrator (no McpRegistry row) — fail-closed: the
            # 7-tool surface is reachable only by a real orchestrator.
            Logger.warning(
              "Ezagent.Orchestrator.McpChannel: #{agent_uri_str} authenticated " <>
                "but is not a registered orchestrator (#{inspect(reason)}) — " <>
                "join rejected (fail-closed)"
            )

            {:error, %{reason: "not a registered orchestrator: #{inspect(reason)}"}}
        end
    end
  end

  # `tools/list` — serve the 7 orchestrator tool JSON schemas. The
  # bridge normally answers `tools/list` from its shipped schema file;
  # this event is the BEAM-served redundancy path so the transport is
  # self-contained.
  @impl true
  def handle_in("mcp_tools_list", _params, socket) do
    {:reply, {:ok, %{"tools" => McpServer.tool_schemas()}}, socket}
  end

  # `tools/call` — route the named tool to the per-orchestrator
  # `McpServer`. The caller / caps / session context is the bound
  # `%McpServer{}` from `socket.assigns.mcp` — set at join from the
  # TOKEN-AUTHENTICATED agent URI. The payload supplies ONLY the tool
  # name and its operation-shaped arguments.
  def handle_in("mcp_tools_call", %{"tool" => tool} = params, socket) do
    arguments =
      case Map.get(params, "arguments") do
        %{} = m -> m
        _ -> %{}
      end

    result = McpServer.handle_tool_call(socket.assigns.mcp, tool, arguments)
    {:reply, {:ok, result}, socket}
  end

  def handle_in("mcp_tools_call", _bad, socket) do
    {:reply, {:error, %{reason: "mcp_tools_call requires a `tool` name"}}, socket}
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  # 2026-05-31 orchestrator-startup-atomicity §5 — on bridge disconnect,
  # CLEAR the durable live-join state so a stale row from a dead
  # incarnation never satisfies a future startup gate. `socket.assigns`
  # carries the token-authenticated `:agent_uri` from `McpSocket.connect/3`
  # (set before `join/3`); a socket that never joined still has it, so the
  # clear is safe + idempotent. Best-effort — `LiveJoinRegistry.clear/1`
  # tolerates an absent row.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{agent_uri: %URI{} = agent_uri} ->
        Ezagent.Orchestrator.LiveJoinRegistry.clear(agent_uri)

      _ ->
        :ok
    end

    :ok
  end
end
