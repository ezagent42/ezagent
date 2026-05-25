defmodule EzagentPluginFeishu.MentionParser do
  @moduledoc """
  Phase 6 PR 16 — text-grep based @mention extraction (B2 route per
  Allen 2026-05-17).

  ## Why text-grep not lark mentioned_users

  lark's `mentioned_users` field carries Feishu open_ids — the user
  would need to type a real Feishu user's name (and that user would
  need to exist in the chat). To target an ESR agent (which has no
  Feishu identity), we use the simpler convention:

      @<agent-name>  →  entity://agent/<flavor>_<agent-name>

  ESR is the source of truth for agent URIs, and the chat is just a
  human-readable surface. If you have an `entity://agent/team-alpha/cc_architect`
  live and someone types `@architect 看看`, the message routes only
  to that agent via MentionRouting (the existing matcher).

  ## Resolution (PR #149 SPEC v2 §5.14)

  `Ezagent.AgentTypeRegistry` was deleted; there's no per-flavor
  enumeration anymore. Resolution now walks `Ezagent.KindRegistry`
  and matches any live `entity://agent/<flavor>_<name>` whose tail
  (everything after the first `_`) equals the typed `@<name>`.
  Multiple live agents sharing a name (cc_alice + curl_alice) both
  match — same UX as before.

  ## UX: name-only mention with flavor auto-discovery

  Users type `@<name>`, not `@<flavor>_<name>` — the parser scans
  every live agent in the registry and pulls those whose name suffix
  matches. Flavor stays an operator-side convention; the typed
  `@<name>` is the natural-language handle.

  Allen 2026-05-17: "B2 路线可以,暂时只考虑文字" — text only,
  no attachment-level mentions.
  """

  alias Ezagent.KindRegistry

  @mention_re ~r/@([A-Za-z0-9_\-\.]+)/

  @doc """
  Extract live agent URIs from free text. Returns `[URI.t()]`.

      iex> EzagentPluginFeishu.MentionParser.extract_agent_mentions("@architect look")
      [%URI{scheme: "entity", host: "agent", path: "/cc_architect", ...}]  # if live

  Returns `[]` if no `@name` tokens or none of them resolve to a live agent.
  """
  @spec extract_agent_mentions(String.t()) :: [URI.t()]
  def extract_agent_mentions(text) when is_binary(text) do
    typed_names =
      @mention_re
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    case typed_names do
      [] ->
        []

      _ ->
        live_agent_uris()
        |> Enum.filter(&matches_any_typed_name?(&1, typed_names))
        |> Enum.uniq_by(&URI.to_string/1)
    end
  end

  def extract_agent_mentions(_), do: []

  # All currently-live `entity://agent/<flavor>_<name>` URIs.
  defp live_agent_uris do
    KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      case URI.new(uri_str) do
        {:ok, %URI{scheme: "entity", host: "agent"} = uri} -> [uri]
        _ -> []
      end
    end)
  end

  # True if the URI's name-suffix (text after the first `_`) matches
  # one of the typed `@<name>` tokens.
  # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment
  # /<workspace>/<entity_name>; extract entity_name first, then split
  # on flavor `_` separator.
  defp matches_any_typed_name?(%URI{path: "/" <> rest}, typed_names) when rest != "" do
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [_flavor, suffix] when suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      suffix in typed_names
    else
      _ -> false
    end
  end

  defp matches_any_typed_name?(_, _), do: false
end
