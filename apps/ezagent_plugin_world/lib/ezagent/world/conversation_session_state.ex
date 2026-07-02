defmodule Ezagent.World.ConversationSessionState do
  @moduledoc """
  Shared session-selection state for the world conversation surface.

  `WorldLive` uses this for route renders, and `ConversationActions` uses it
  for in-place rail switching so both paths keep the same data shape.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias Ezagent.World.ConversationActions
  alias Ezagent.World.ConversationData

  @doc false
  @spec list_sessions(URI.t() | term()) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    EzagentDomainInstanceMessage.list_sessions(workspace_uri)
  rescue
    _ -> []
  end

  def list_sessions(_), do: []

  @doc false
  @spec rows_for_workspace(URI.t() | term()) :: [map()]
  def rows_for_workspace(workspace_uri) do
    workspace_uri
    |> list_sessions()
    |> Enum.map(&session_row/1)
  end

  @doc false
  @spec session_row(URI.t()) :: map()
  def session_row(%URI{} = session_uri) do
    uri = uri_string(session_uri)
    workspace = session_uri |> Ezagent.Capability.workspace_of() |> uri_string()

    %{
      "uri" => uri,
      "name" => session_uri.path || session_uri.host || uri,
      "workspace_uri" => workspace
    }
  end

  @doc false
  @spec state_for(URI.t(), Phoenix.LiveView.Socket.t()) :: map()
  def state_for(%URI{} = session_uri, socket) do
    ConversationData.state_for(session_uri, %{
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      workspace_uri: socket.assigns.current_workspace_uri,
      sessions: rows_for_workspace(socket.assigns.current_workspace_uri)
    })
  end

  @doc false
  @spec ensure_session_subscribed(Phoenix.LiveView.Socket.t(), URI.t()) ::
          Phoenix.LiveView.Socket.t()
  def ensure_session_subscribed(socket, %URI{} = session_uri) do
    topic = Ezagent.Behavior.Session.session_events_topic(session_uri)
    subscribed = Map.get(socket.assigns, :subscribed_topics, MapSet.new())

    if connected?(socket) and not MapSet.member?(subscribed, topic) do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      assign(socket, :subscribed_topics, MapSet.put(subscribed, topic))
    else
      socket
    end
  end

  @doc """
  Switch the active conversation session with an in-place state push.

  The browser URL is updated separately so a refresh keeps the selected session,
  but the React conversation island is not route-remounted for rail clicks.
  """
  @spec switch_session(Phoenix.LiveView.Socket.t(), URI.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def switch_session(socket, %URI{} = session_uri) do
    socket =
      socket
      |> ensure_session_subscribed(session_uri)
      |> assign(:current_session_uri, session_uri)
      |> assign(:current_session_uri_str, uri_string(session_uri))
      |> ConversationActions.self_join(session_uri)

    state =
      session_uri
      |> state_for(socket)
      |> Map.put("path", "/sessions")
      |> Map.put("title", "Chat")

    path = "/sessions?session=#{encode_param(session_uri)}"

    {:noreply,
     socket
     |> assign(:world_component, "conversation")
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, "ok")
     |> push_event("world:state", state)
     |> push_event("world:url", %{"path" => path})}
  end

  defp encode_param(%URI{} = uri), do: uri |> URI.to_string() |> URI.encode_www_form()
  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(_), do: nil
end
