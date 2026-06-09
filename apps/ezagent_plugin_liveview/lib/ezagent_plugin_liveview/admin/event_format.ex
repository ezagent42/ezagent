defmodule EzagentPluginLiveview.Admin.EventFormat do
  @moduledoc """
  Pure presentation helpers for AdminLive's incoming-event handling —
  slice-change / notification flash text + the caller-workspace /
  event-URI authorization predicates. Extracted verbatim from
  `EzagentPluginLiveview.AdminLive` (#25 Phase-3, PR-3Q).

  No socket mutation: every function reads its inputs and returns a
  string or boolean. `AdminLive`'s `handle_info/2` callbacks call these.
  """

  alias EzagentPluginLiveview.Admin.SessionContext

  @doc """
  True when `session_uri` is viewable by the caller behind `socket`
  (i.e. in the caller's workspace per `SessionContext`).
  """
  def session_in_caller_workspace?(%URI{} = session_uri, socket) do
    SessionContext.authorize_session_view(socket, session_uri) == :ok
  end

  def session_in_caller_workspace?(_, _), do: false

  # Today AdminLive subscribes to the caller URI only.
  @doc """
  True when a slice-change `event`'s `:uri` matches the caller URI in
  `socket.assigns`.
  """
  def event_uri_authorized?(%{uri: %URI{} = event_uri}, %{assigns: assigns}) do
    case assigns[:caller_uri] do
      %URI{} = caller_uri -> URI.to_string(event_uri) == URI.to_string(caller_uri)
      _ -> false
    end
  end

  def event_uri_authorized?(_, _), do: false

  @doc """
  Bound slice-change formatting so a slow Kind/Repo cannot stall the LV.
  """
  def format_slice_change_bounded(event, timeout_ms) do
    task = Task.async(fn -> format_slice_change(event) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, flash} when is_binary(flash) ->
        flash

      _ ->
        # Timeout or crash. Generic fallback — the flash still
        # fires, just without the message preview.
        case Map.get(event, :uri) do
          %URI{} = uri -> "Update on #{URI.to_string(uri)}"
          _ -> "Update received"
        end
    end
  end

  @doc """
  Notification flash text. Prefer body text/summary, then outer legacy
  keys.
  """
  def format_notification(%{body: %{} = body} = payload) do
    cond do
      is_binary(body[:text]) -> body[:text]
      is_binary(body["text"]) -> body["text"]
      is_binary(body[:summary]) -> body[:summary]
      is_binary(body["summary"]) -> body["summary"]
      true -> format_notification_legacy(payload)
    end
  end

  def format_notification(%{} = payload), do: format_notification_legacy(payload)
  def format_notification(other), do: "Notification: #{inspect(other)}"

  defp format_notification_legacy(%{} = payload) do
    cond do
      is_binary(payload[:text]) -> payload[:text]
      is_binary(payload["text"]) -> payload["text"]
      is_binary(payload[:summary]) -> payload[:summary]
      is_binary(payload["summary"]) -> payload["summary"]
      true -> "Notification: #{inspect(payload)}"
    end
  end

  defp format_notification_legacy(other), do: "Notification: #{inspect(other)}"

  @doc """
  Slice-change flash text. Chat changes use the cursor-indexed message
  ring; unreadable or non-chat slices degrade to a generic flash.
  """
  def format_slice_change(%{uri: %URI{} = uri, slice_key: :chat, cursor: cursor} = _event)
      when is_integer(cursor) do
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{} = slice} ->
        case chat_msg_id_for_cursor(slice, cursor) do
          {:ok, msg_id} -> chat_flash_for(msg_id)
          :not_found -> "New chat update on #{URI.to_string(uri)}"
        end

      _ ->
        "New chat update on #{Ezagent.URI.stable_key(uri)}"
    end
  end

  # Legacy/synthetic event without a cursor.
  def format_slice_change(%{uri: %URI{} = uri, slice_key: :chat} = _event) do
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{last_received: %{message_id: msg_id}}} when is_binary(msg_id) ->
        chat_flash_for(msg_id)

      _ ->
        "New chat update on #{URI.to_string(uri)}"
    end
  end

  def format_slice_change(%{uri: %URI{} = uri, slice_key: slice_key} = _event)
      when is_atom(slice_key) do
    "Update on #{Ezagent.URI.stable_key(uri)} (#{slice_key})"
  end

  def format_slice_change(other), do: "Slice changed: #{inspect(other)}"

  # Look up the message id for a broadcast cursor in the recent-message ring.
  defp chat_msg_id_for_cursor(slice, cursor) when is_map(slice) and is_integer(cursor) do
    ring = Map.get(slice, :recent_messages, [])

    case List.keyfind(ring, cursor, 0) do
      {^cursor, msg_id} when is_binary(msg_id) -> {:ok, msg_id}
      _ -> :not_found
    end
  end

  # Build the chat-style flash from a persisted message id. Splitting
  # this out makes the `:chat` clause a single match-and-render so the
  # re-fetch failure path stays readable.
  defp chat_flash_for(msg_id) when is_binary(msg_id) do
    case Ezagent.MessageStore.by_id(msg_id) do
      {:ok, %Ezagent.Message{sender: sender, body: body}} ->
        "New message from #{URI.to_string(sender)}: #{message_preview(body)}"

      _ ->
        "New chat message (id #{msg_id})"
    end
  end

  # Best-effort preview from atom-keyed or string-keyed Message bodies.
  defp message_preview(%{text: t}) when is_binary(t), do: truncate_preview(t)
  defp message_preview(%{"text" => t}) when is_binary(t), do: truncate_preview(t)
  defp message_preview(_), do: "(attachment-only message)"

  defp truncate_preview(text) when is_binary(text) do
    case String.length(text) do
      n when n <= 80 -> text
      _ -> String.slice(text, 0, 77) <> "..."
    end
  end
end
