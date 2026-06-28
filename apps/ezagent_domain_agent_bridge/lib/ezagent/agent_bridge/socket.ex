defmodule Ezagent.AgentBridge.Socket do
  @moduledoc """
  Phoenix.Socket entry point for bridge-backed agent sidecars.

  Sidecars connect to `/agent_bridge` and join
  `agent_bridge:<flavor>:<agent_uri>`. The legacy `/cc_socket` mount was
  removed in Cleanup-3 (FF-4 3→0); the legacy `cc:bridge:<agent_uri>`
  topic is still accepted on the `/agent_bridge` mount for any in-flight
  sidecar configured with `EZAGENT_BRIDGE_TOPIC`.
  """
  use Phoenix.Socket

  alias Ezagent.AgentBridge.TokenStore

  channel("agent_bridge:*", Ezagent.AgentBridge.Channel)
  channel("cc:bridge:*", Ezagent.AgentBridge.Channel)

  @impl true
  def connect(params, socket, _connect_info) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # at inbound socket boundary; try/rescue preserves the `with`'s
    # `:error` failure path (Invariant #9 — graceful socket reject).
    with {:ok, agent_uri_str} <- Map.fetch(params, "agent_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, agent_uri} <- safe_parse_uri(agent_uri_str),
         :ok <- verify_token(agent_uri, token) do
      {:ok, assign_authenticated_bridge(socket, agent_uri, token)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "agent_bridge:" <> URI.to_string(socket.assigns.agent_uri)

  defp assign_authenticated_bridge(socket, agent_uri, token) do
    socket
    |> assign(:agent_uri, agent_uri)
    |> assign(:bridge_token, token)
    |> assign(:authed_at, DateTime.utc_now())
  end

  defp safe_parse_uri(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_parse_uri(_), do: :error

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
