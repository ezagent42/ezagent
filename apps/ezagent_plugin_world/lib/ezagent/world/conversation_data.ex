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
      "members" => member_options(session_uri),
      "sessions" => sessions
    }
  end

  @doc """
  Session members as `%{"uri" => ..., "display_name" => ..., "online" => bool,
  "kind" => "user"|"agent"|"other"}` rows. Reads the authoritative session
  slice (`Ezagent.Kind.get_slice/2`) — the same source the server-side mention
  parse uses, so the @mention dropdown, the members panel, and routing can't
  drift. The panel (PR-3a) shows presence; the autocomplete ignores it.
  """
  @spec member_options(URI.t()) :: [map()]
  def member_options(%URI{} = session_uri) do
    presence = member_presence(session_uri)
    uris = Map.keys(presence)
    display_map = Ezagent.EntityPresenter.display_many(uris)

    uris
    |> Enum.sort()
    |> Enum.map(fn uri ->
      %{
        "uri" => uri,
        "display_name" => Map.get(display_map, uri, uri),
        "online" => Map.get(presence, uri, false),
        "kind" => sender_kind(uri)
      }
    end)
  end

  @doc """
  Parse @mentions in `text` into recipient entity URIs, against `members`
  (`member_options/1` rows). Recognizes explicit `@entity://...` URIs and bare
  `@name` tokens resolved by URI path segment then display name (unique match
  only). Port of the LiveView parser against survivors — world carries no
  reference to the LV plugin. The result is what the domain's recipient
  resolver consumes (`msg.mentions`), so this is the load-bearing piece, not
  the autocomplete UI.
  """
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members) when is_binary(text) and is_list(members) do
    (parse_uri_mentions(text) ++ parse_bare_mentions(text, members))
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_text, _members), do: []

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

  Parses @mentions server-side against the session's authoritative members
  (never trusting a client-supplied recipient list). `attachments` are
  `resource://…/uploads/…` URIs ALREADY VERIFIED by the caller
  (`ConversationActions.send_message/4` checks each upload grant's signature +
  caller/session binding before passing them here — PR-2b anti-laundering), so
  this function trusts the list it is given. `legend_triggers` stay empty.
  """
  @spec build_message(URI.t(), String.t(), URI.t(), [URI.t()]) :: Ezagent.Message.t()
  def build_message(sender, text, session_uri, attachments \\ [])

  def build_message(%URI{} = sender, text, %URI{} = session_uri, attachments)
      when is_binary(text) and is_list(attachments) do
    mentions = parse_mentions(text, member_options(session_uri))
    Ezagent.Message.new(sender, %{text: text, attachments: attachments}, mentions: mentions)
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

  # Each attachment renders as `%{"name", "href"}`: an uploads `resource://…`
  # URI gets a signed `DownloadToken` link (the existing authed `/uploads/download`
  # route re-checks the participant at serve time, so minting does not widen
  # access — same contract as LV `att_to_link/1`); any other value renders as a
  # plain label with no href (PR-2b).
  defp body_attachments(%{attachments: list}) when is_list(list),
    do: Enum.map(list, &attachment_row/1)

  defp body_attachments(%{"attachments" => list}) when is_list(list),
    do: Enum.map(list, &attachment_row/1)

  defp body_attachments(_), do: []

  defp attachment_row(att) do
    case attachment_uri(att) do
      %URI{scheme: "resource"} = uri -> uploads_attachment_row(uri)
      _ -> %{"name" => attachment_label(att), "href" => nil}
    end
  end

  defp uploads_attachment_row(%URI{} = uri) do
    name = uri |> URI.to_string() |> Path.basename() |> strip_uuid_prefix()

    case safe_mint_download(uri) do
      {:ok, token} -> %{"name" => name, "href" => "/uploads/download?token=#{token}"}
      :error -> %{"name" => name, "href" => nil}
    end
  end

  defp safe_mint_download(%URI{} = uri) do
    {:ok, Ezagent.Uploads.DownloadToken.mint!(uri)}
  rescue
    _ -> :error
  end

  # Stored names are `<uuid>-<sanitized>`; show the human part in the link label.
  defp strip_uuid_prefix(name) when is_binary(name) do
    case Regex.run(~r/^[0-9a-fA-F-]{36}-(.+)$/, name) do
      [_, rest] -> rest
      _ -> name
    end
  end

  defp attachment_uri(%URI{} = uri), do: uri

  defp attachment_uri(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{} = uri} -> uri
      _ -> s
    end
  end

  defp attachment_uri(other), do: other

  defp attachment_label(%URI{} = uri), do: URI.to_string(uri)
  defp attachment_label(s) when is_binary(s), do: s
  defp attachment_label(other), do: inspect(other)

  defp datetime_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_iso(_), do: nil

  # %{uri_string => online_bool} from the session slice members map (values
  # carry an `:online` flag). Empty for a cold/unknown session.
  defp member_presence(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        Map.new(members, fn {uri, meta} ->
          {URI.to_string(uri), is_map(meta) and Map.get(meta, :online, false) == true}
        end)

      _ ->
        %{}
    end
  end

  # --- @mention parse (port vs survivors; NO LV dep) ----------------------

  defp parse_uri_mentions(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&safe_uri/1)
  end

  defp parse_bare_mentions(_text, []), do: []

  defp parse_bare_mentions(text, members) do
    ~r/(?<![\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&resolve_member_name(&1, members))
  end

  # Bare @name resolves by URI path segment first, then by display name —
  # unique match only (an ambiguous name resolves to nothing, never a guess).
  defp resolve_member_name(name, members) do
    by_segment = Enum.filter(members, &(uri_path_segment(Map.get(&1, "uri")) == name))

    candidates =
      if by_segment != [],
        do: by_segment,
        else: Enum.filter(members, &(Map.get(&1, "display_name") == name))

    case candidates |> Enum.map(&Map.get(&1, "uri")) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [uri_str] -> safe_uri(uri_str)
      _ -> []
    end
  end

  defp uri_path_segment(uri_str) when is_binary(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} ->
        case Ezagent.URI.name(uri) do
          {:ok, name} -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp uri_path_segment(_), do: nil

  defp safe_uri(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} -> [uri]
      _ -> []
    end
  end

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
