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

  # Unicode-aware (`u` flag + \p{L}\p{N}) so CJK legend names like `@传话游戏`
  # are captured (team-routing-unification §3.6, PR-6) alongside the original
  # ASCII agent handles. The `\p{L}\p{N}_.\-` class keeps `cc_e2e_final`,
  # `e2e-final`, dotted names, AND any-script letters.
  #
  # Left-boundary `(?<![\p{L}\p{N}_])` (codex 2026-06-01 MED #5) — without it,
  # `foo@name` matched `@name`. The negative lookbehind over the SAME Unicode
  # letter/number/underscore class LiveView's `parse_bare_mentions/2` uses
  # rejects an `@` glued to a preceding word char (`foo@x`, `中文@x`, `한글@x`),
  # so email-like / inline text doesn't spuriously mention.
  @mention_re ~r/(?<![\p{L}\p{N}_])@([\p{L}\p{N}_.\-]+)/u

  @doc """
  Extract live agent URIs from free text. Returns `[URI.t()]`.

      iex> EzagentPluginFeishu.MentionParser.extract_agent_mentions("@architect look")
      [%URI{scheme: "entity", ...}]  # if live

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

  @doc """
  Like `extract_agent_mentions/1`, but consults the session's legend registry
  FIRST (team-routing-unification §3.6, PR-6). Returns a
  `{mentions :: [URI.t()], legend_triggers :: [String.t()]}` pair:

    * a typed `@<name>` that IS a registered legend is intercepted BEFORE the
      URI-mention path and surfaced as a SYMBOLIC LEGEND NAME in
      `legend_triggers` — NOT pre-canonicalized to concrete URIs. The send
      path (`Behavior.Session.handle_send`) then fires the legend's bound rule-set
      ENTRY rule through the NORMAL `Resolver.resolve_with_ctx/4` expansion
      (matching `mention(<legend_name>)` against the virtual
      `Message.legend_triggers`), which carries the entry's `prompt_template_ref`
      AND expands magic receivers (`$session_members`, …). The legend NAME never
      enters `message.mentions` (it is not URI-castable / persistence-safe).
    * any other `@<name>` → resolved to live agent `%URI{}`s as before.

  Legend precedence (GATE b) means a legend name can never silent-drop or
  mis-route through the concrete-URI matcher: it is intercepted into
  `legend_triggers`, and the typed token is removed from the URI-mention scan.

  `legends` is the session-scoped legend registry (`name => entry`), read off
  the Chat slice via `Ezagent.Behavior.Session.legends_of/1` by the caller.
  Passing `%{}` yields `{extract_agent_mentions(text), []}`.
  """
  @spec extract_mentions(String.t(), map()) :: {[URI.t()], [String.t()]}
  def extract_mentions(text, legends) when is_binary(text) and is_map(legends) do
    typed_names =
      @mention_re
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    {legend_names, non_legend_names} =
      Enum.split_with(typed_names, fn name ->
        match?({:legend, _}, Ezagent.Routing.Legend.mention_token(legends, name))
      end)

    # Concrete agents resolve only from the NON-legend tokens — a legend name
    # is removed from the URI-mention path entirely (so it can't mis-route).
    uri_mentions =
      case non_legend_names do
        [] -> []
        names -> live_agent_uris() |> Enum.filter(&matches_any_typed_name?(&1, names))
      end
      |> Enum.uniq_by(&URI.to_string/1)

    {uri_mentions, legend_names}
  end

  def extract_mentions(_, _), do: {[], []}

  # All currently-live `entity://agent/<workspace>/<name>` URIs.
  defp live_agent_uris do
    KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
      # with try/rescue (silent-drop fallback for corrupted registry rows).
      try do
        case Ezagent.URI.new!(uri_str) do
          %URI{scheme: "entity"} = uri -> if Ezagent.URI.type?(uri, :agent), do: [uri], else: []
          _ -> []
        end
      rescue
        ArgumentError -> []
      end
    end)
  end

  # True if the URI's opaque display name matches one of the typed
  # `@<name>` tokens. Agent flavor is stored metadata and never parsed
  # out of the URI name.
  defp matches_any_typed_name?(%URI{} = uri, typed_names) do
    case Ezagent.URI.name(uri) do
      {:ok, entity_name} -> entity_name in typed_names
      :error -> false
    end
  end

  defp matches_any_typed_name?(_, _), do: false
end
