defmodule Ezagent.World.EntitySearchActions do
  @moduledoc """
  LiveView reply actions for world entity search surfaces.
  """

  alias Ezagent.World.ConversationData

  @spec handle_search(Phoenix.LiveView.Socket.t(), map()) ::
          {:reply, map(), Phoenix.LiveView.Socket.t()}
  def handle_search(socket, %{"session_uri" => session_uri_str} = params) do
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        rows =
          ConversationData.search_invitable_entities(
            socket.assigns.current_entity_uri,
            socket.assigns.current_workspace_uri,
            Map.get(params, "q", ""),
            session_uri
          )

        {:reply, %{"options" => rows}, socket}

      :error ->
        {:reply, %{"options" => [], "error" => "bad_session_uri"}, socket}
    end
  end

  def handle_search(socket, _params), do: {:reply, %{"options" => []}, socket}

  defp parse_session_uri(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session_uri(_), do: :error
end
