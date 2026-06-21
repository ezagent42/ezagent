defmodule Ezagent.World.ConversationData do
  @moduledoc """
  Read-path + message construction for the world session-conversation surface
  (LV→world parity migration PR-1).

  Mirrors the `Ezagent.World.{AdminData,IdentityData,WorkspacePluginData}`
  pattern: `EzagentPluginWorld.WorldLive` stays the SSR/comms shell and this
  module owns the pure data shaping. Everything here is derived against
  core/domain survivors (`Ezagent.MessageStore`, `Ezagent.EntityPresenter`,
  `Ezagent.Message`) — NOT the retired LiveView plugin's `SessionContext`, so
  the LV app can be deleted wholesale at parity-migration PR-7.
  """

  @message_limit 50

  @doc """
  Build the React `conversation` island state for a session.

  Loads the most-recent `#{@message_limit}` messages (chronological,
  oldest-first) plus the workspace session list (for the in-header selector)
  and the deep-link/inbound-filter session URI. `caller_uri` lets the island
  flag the viewer's own messages; `sessions` are the already-shaped session
  rows from `WorldLive`.
  """
  @spec state_for(URI.t(), %{
          required(:caller_uri) => URI.t() | nil,
          required(:workspace_uri) => URI.t() | nil,
          required(:sessions) => [map()]
        }) :: map()
  def state_for(%URI{} = session_uri, %{
        caller_uri: caller_uri,
        workspace_uri: workspace_uri,
        sessions: sessions
      }) do
    messages = load_messages(session_uri)

    %{
      "component" => "conversation",
      "session_uri" => encode_uri(session_uri),
      "current_session_uri" => encode_uri(session_uri),
      "workspace_uri" => encode_uri(workspace_uri),
      "caller_uri" => encode_uri(caller_uri),
      "messages" => messages,
      "oldest_cursor" => oldest_cursor_iso(messages),
      "sessions" => sessions
    }
  end

  @doc """
  Fetch a page of messages older than `cursor` (ISO-8601), oldest-first.

  Returns `{rows, next_oldest_cursor}` for the island to prepend; an invalid
  cursor yields `{[], nil}` (no paging).
  """
  @spec load_older(URI.t(), String.t()) :: {[map()], String.t() | nil}
  def load_older(%URI{} = session_uri, before) when is_binary(before) do
    case DateTime.from_iso8601(before) do
      {:ok, cursor, _offset} ->
        rows =
          session_uri
          |> Ezagent.MessageStore.older_than(cursor, @message_limit)
          |> Enum.reverse()
          |> messages_to_rows()

        {rows, oldest_cursor_iso(rows)}

      _ ->
        {[], nil}
    end
  end

  @doc """
  Construct a chat `Ezagent.Message` for the composer.

  PR-1 is text-only; PR-2 (file upload) populates `mentions:`/attachments.
  """
  @spec build_message(URI.t(), String.t()) :: Ezagent.Message.t()
  def build_message(%URI{} = sender, text) when is_binary(text) do
    Ezagent.Message.new(sender, %{text: text, attachments: []})
  end

  @doc "Render-ready row for a single message (resolves the sender display)."
  @spec message_row(Ezagent.Message.t()) :: map()
  def message_row(%Ezagent.Message{} = msg), do: message_row(msg, %{})

  @doc "Oldest-visible-cursor (ISO-8601) for backwards paging; `nil` when empty."
  @spec oldest_cursor_iso([map()]) :: String.t() | nil
  def oldest_cursor_iso([%{"at" => at} | _]) when is_binary(at), do: at
  def oldest_cursor_iso(_), do: nil

  defp load_messages(%URI{} = session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
    |> messages_to_rows()
  end

  defp messages_to_rows(messages) when is_list(messages) do
    sender_uris = Enum.map(messages, fn %Ezagent.Message{sender: s} -> URI.to_string(s) end)
    display_map = Ezagent.EntityPresenter.display_many(sender_uris)
    Enum.map(messages, &message_row(&1, display_map))
  end

  defp message_row(%Ezagent.Message{} = msg, display_map) do
    sender_str = URI.to_string(msg.sender)

    %{
      "id" => msg.id,
      "sender" => sender_str,
      "sender_display" =>
        Map.get(display_map, sender_str) || Ezagent.EntityPresenter.display(sender_str),
      "sender_kind" => sender_kind(sender_str),
      "text" => body_text(msg.body),
      "attachments" => body_attachments(msg.body),
      "at" => datetime_iso(msg.inserted_at)
    }
  end

  defp sender_kind(uri_str) when is_binary(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} ->
        cond do
          Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, :user) -> "user"
          Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, :agent) -> "agent"
          true -> "other"
        end

      _ ->
        "other"
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # PR-1 renders attachments as plain labels; PR-2 (file upload) replaces
  # this with signed download links (`Ezagent.Uploads.DownloadToken`).
  defp body_attachments(%{attachments: list}) when is_list(list),
    do: Enum.map(list, &attachment_label/1)

  defp body_attachments(%{"attachments" => list}) when is_list(list),
    do: Enum.map(list, &attachment_label/1)

  defp body_attachments(_), do: []

  defp attachment_label(%URI{} = uri), do: URI.to_string(uri)
  defp attachment_label(s) when is_binary(s), do: s
  defp attachment_label(other), do: inspect(other)

  defp datetime_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_iso(_), do: nil

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
