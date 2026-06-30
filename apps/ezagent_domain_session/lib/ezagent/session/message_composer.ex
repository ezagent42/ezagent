defmodule Ezagent.Session.MessageComposer do
  @moduledoc """
  Composer-surface message construction for the session-conversation domain.

  This is the ONE sanctioned place that turns a human composer input (sender +
  free text + session) into a routable `%Ezagent.Message{}` with `@mentions`
  resolved server-side against the session's AUTHORITATIVE members slice. Every
  composer surface reuses it instead of re-deriving recipients:

  - the World UI chat island (`Ezagent.World.ConversationData.build_message/4`
    + `parse_mentions/2` delegate here), and
  - the operator CLI (`mix ezagent session send`, via
    `EzagentCli.Dispatch.run_session_send/1`).

  Tier (P9 — "reads what data decides ownership"): `member_options/1` reads the
  Session Kind's `:session` slice (`Ezagent.Kind.get_slice/2`) and resolves
  display names via `Ezagent.EntityPresenter` (domain_identity), so the builder
  is session-domain code — NOT a plugin one-off and NOT a core primitive. The
  resulting `msg.mentions` is what `Ezagent.Behavior.Session.handle_send/2`
  consumes to fan the message out, so this is the load-bearing recipient
  resolver, not autocomplete UI sugar.
  """

  alias Ezagent.Message

  @doc """
  Construct a chat `%Ezagent.Message{}` for a session composer.

  Parses `@mentions` server-side against the session's authoritative members
  (never trusting a client-supplied recipient list). `attachments` are URIs the
  caller has ALREADY verified (the World composer checks upload-grant signatures
  before passing them); this function trusts the list it is given.
  `legend_triggers` stay empty.
  """
  @spec build_message(URI.t(), String.t(), URI.t(), [URI.t()]) :: Message.t()
  def build_message(sender, text, session_uri, attachments \\ [])

  def build_message(%URI{} = sender, text, %URI{} = session_uri, attachments)
      when is_binary(text) and is_list(attachments) do
    mentions = parse_mentions(text, member_options(session_uri))
    Message.new(sender, %{text: text, attachments: attachments}, mentions: mentions)
  end

  @doc """
  Parse `@mentions` in `text` into recipient entity URIs, against `members`
  (`member_options/1` rows). Recognizes explicit `@entity://...` URIs and bare
  `@name` tokens resolved by URI path segment first, then by display name
  (unique match only — an ambiguous name resolves to nothing, never a guess).
  """
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members) when is_binary(text) and is_list(members) do
    (parse_uri_mentions(text) ++ parse_bare_mentions(text, members))
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_text, _members), do: []

  @doc """
  Session members as `%{"uri" => ..., "display_name" => ...}` rows, read from
  the authoritative `:session` slice. The same source the World members panel
  and routing use, so the @mention resolver can't drift from the UI. Presence /
  kind flags (UI-only) are intentionally NOT shaped here — mention resolution
  needs only the URI and the display name.
  """
  @spec member_options(URI.t()) :: [map()]
  def member_options(%URI{} = session_uri) do
    uris = member_uris(session_uri)
    display_map = Ezagent.EntityPresenter.display_many(uris)

    uris
    |> Enum.sort()
    |> Enum.map(fn uri ->
      %{"uri" => uri, "display_name" => Map.get(display_map, uri, uri)}
    end)
  end

  def member_options(_), do: []

  # Member URI strings from the `:session` slice members map (the live members
  # set). Empty for a cold/unknown session.
  defp member_uris(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        Enum.map(Map.keys(members), &encode_uri/1)

      _ ->
        []
    end
  end

  # --- @mention parse ------------------------------------------------------

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
  defp encode_uri(other) when is_binary(other), do: other
end
