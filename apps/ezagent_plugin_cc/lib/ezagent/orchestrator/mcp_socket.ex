defmodule Ezagent.Orchestrator.McpSocket do
  @moduledoc """
  Phoenix.Socket entry point for the orchestrator MCP transport bridge
  (Phase 7 completion SPEC §2 "PR-5").

  ## What this is

  The orchestrator MCP server (`Ezagent.Orchestrator.McpServer`) is an
  ESR-side Elixir module — the 7 privileged orchestration tools. A live
  `claude` orchestrator reaches it through the MCP stdio bridge
  (`priv/orchestrator_bridge.py`). That bridge speaks the MCP protocol
  to `claude` over stdio and forwards `tools/call` to the BEAM over a
  WebSocket Phoenix Channel — the same house transport the AgentBridge
  channel uses for plugin sidecars.

  This Socket mirrors the AgentBridge socket identity discipline:

  - one WS connection per orchestrator `claude` process;
  - the connection joins topic `orch:bridge:<orchestrator_uri>`
    (`Ezagent.Orchestrator.McpChannel`);
  - connect params MUST include `token` + `agent_uri`.

  ## Identity is server-derived — no spoofing

  Token auth reuses `Ezagent.AgentBridge.TokenStore`: the orchestrator
  is an Agent entity with a per-instance connect token minted for its
  URI.
  `connect/3` verifies the presented `token` resolves to the SAME
  `agent_uri` the caller claims — exactly AgentBridge.Socket's
  check. The verified URI is stamped into `socket.assigns.agent_uri`.

  Every downstream decision (which `McpServer` context, which caps,
  which session) keys off `socket.assigns.agent_uri` — the
  TOKEN-AUTHENTICATED value — never a field from a `tools/call`
  payload. A `claude` process (or the bridge) therefore cannot point
  the orchestrator surface at another orchestrator's identity, caps,
  or session: it can only present a token, and a token resolves to
  exactly one agent URI.
  """
  use Phoenix.Socket

  alias Ezagent.AgentBridge.TokenStore

  channel("orch:bridge:*", Ezagent.Orchestrator.McpChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # for inbound socket payload; try/rescue keeps the `with`-clause's
    # `{:error, _} | :error` failure path so a malformed agent_uri
    # surfaces as a clean socket-reject (Invariant #9 — no silent drop).
    with {:ok, agent_uri_str} <- Map.fetch(params, "agent_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, agent_uri} <- safe_parse_uri(agent_uri_str),
         :ok <- verify_token(agent_uri, token) do
      socket =
        socket
        |> assign(:agent_uri, agent_uri)
        # Transport #53 Decision C — stash the verified connection token so the
        # Channel can FORWARD it to the session-domain `SessionManager`, which
        # VERIFIES it (the unforgeable authz gate). The token is a SECRET held
        # only on this server-side socket (never echoed to the wire / logs).
        |> assign(:bridge_token, token)
        |> assign(:authed_at, DateTime.utc_now())

      {:ok, socket}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "orchestrator_socket:" <> URI.to_string(socket.assigns.agent_uri)

  defp safe_parse_uri(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_parse_uri(_), do: :error

  # Same token check as AgentBridge.Socket. The resolved URI MUST equal
  # the claimed agent_uri, so the wire cannot claim an identity it has
  # no token for.
  defp verify_token(agent_uri, token) do
    case TokenStore.lookup_by_token(token) do
      {:ok, %URI{} = resolved} ->
        if URI.to_string(resolved) == URI.to_string(agent_uri) do
          :ok
        else
          {:error, :token_uri_mismatch}
        end

      _ ->
        {:error, :invalid_token}
    end
  end
end
