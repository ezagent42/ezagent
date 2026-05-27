defmodule EzagentPluginCc.Socket do
  @moduledoc """
  Phase 6 PR 4 — Phoenix.Socket entry point for the v2 CC channel.

  Each CC instance (one bridge per claude process) opens a WebSocket
  to `/cc_socket` and joins topic `cc:bridge:<agent_uri>`. Connect
  params must include `token` (minted via AgentBridge TokenStore.mint/1)
  AND `agent_uri` matching the token's owner. Mismatch → :error.

  Replaces the v1_prototype's HTTP /api/cc-bridge/announce + SSE
  /api/cc-bridge/events pair with a single full-duplex WS — eliminates
  the SSE-loop boilerplate + per-message HTTP overhead.
  """
  use Phoenix.Socket

  alias Ezagent.AgentBridge.TokenStore

  channel "cc:bridge:*", EzagentPluginCc.Channel

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, agent_uri_str} <- Map.fetch(params, "agent_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, agent_uri} <- URI.new(agent_uri_str),
         :ok <- verify_token(agent_uri, token) do
      socket =
        socket
        |> assign(:agent_uri, agent_uri)
        |> assign(:authed_at, DateTime.utc_now())

      {:ok, socket}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "cc_socket:" <> URI.to_string(socket.assigns.agent_uri)

  defp verify_token(agent_uri, token) do
    # PR 5's TokenStore.lookup_by_token returns {:ok, URI.t()} for valid
    # tokens. Confirm the resolved URI matches the claimed agent_uri.
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
