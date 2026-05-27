defmodule Ezagent.AgentBridge.Socket do
  @moduledoc """
  Phoenix.Socket entry point for bridge-backed agent sidecars.

  New sidecars connect to `/agent_bridge` and join
  `agent_bridge:<flavor>:<agent_uri>`. During the cc deprecation
  window, the same socket is also mounted at `/cc_socket` and accepts
  legacy `cc:bridge:<agent_uri>` topics.
  """
  use Phoenix.Socket

  alias Ezagent.AgentBridge.TokenStore

  channel "agent_bridge:*", Ezagent.AgentBridge.Channel
  channel "cc:bridge:*", Ezagent.AgentBridge.Channel

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
  def id(socket), do: "agent_bridge:" <> URI.to_string(socket.assigns.agent_uri)

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
