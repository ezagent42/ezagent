defmodule Ezagent.UI.CommandSource do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.3) — pure ranking function for the CmdK command
  palette.

  This is **NOT a registry** and **NOT a query over live registries**.
  It is a pure function over data passed in by the caller. The caller assembles
  `candidates` by mapping the nav routes (delivered DOWN via the `ezagent_web`
  `on_mount` assign — SPEC §2.2) and the `UriOptions` entity/session options
  into `result()` shape, then calls `search/2`.

  ## Dependency-direction (SPEC §2.3 — BLOCKER fix)

  `CommandSource` has **NO `EzagentWeb.Router` dependency** and **NO
  `Ezagent.KindRegistry` dependency**. It never reaches for either —
  it operates only on the `candidates` list. Nav routes reach it only
  via the `ezagent_web` `on_mount` assign; entity/session options
  reach it only via `Ezagent.UI.UriOptions` (whose registry access is
  the caller's concern, not this module's). This keeps the
  dependency graph acyclic: a Tier-2 module never calls up into
  Tier-3 `ezagent_web`. SPEC §4 item 11 guards this with a
  dependency-boundary test.

  ## Stable keys

  Every `result()` carries a stable `:key` — `"nav:/sessions"`,
  `"entity:" <> uri`. The component renders `phx-value-key={r.key}`
  and holds a `%{key => result}` map so `cmdk_select` is an O(1)
  lookup (SPEC §2.3 + §2.5).
  """

  @typedoc """
  A palette result row. V1 kinds are `:nav` and `:entity` — `:action`
  (Source 3) is deferred to V2 (SPEC §2.6).
  """
  @type result :: %{
          key: String.t(),
          kind: :nav | :entity,
          label: String.t(),
          target: String.t(),
          icon: String.t(),
          group: String.t()
        }

  @result_limit 20

  @doc """
  Rank + filter pre-assembled `candidates` against `query`.

  An empty (or whitespace-only) query returns the first
  #{@result_limit} candidates in their incoming order — the palette's
  "browse everything" initial state. A non-empty query keeps only
  candidates whose `label` fuzzily matches, sorts best-match-first,
  and takes #{@result_limit}.

  Pure: same inputs always yield the same output. No registry access,
  no process state.

  ## Examples

      iex> alias Ezagent.UI.CommandSource
      iex> cands = [
      ...>   %{key: "nav:/sessions", kind: :nav, label: "Sessions",
      ...>     target: "/sessions", icon: "message-square", group: "Navigate"},
      ...>   %{key: "nav:/routing", kind: :nav, label: "Routing",
      ...>     target: "/routing", icon: "route", group: "Navigate"}
      ...> ]
      iex> CommandSource.search("sess", cands) |> Enum.map(& &1.key)
      ["nav:/sessions"]

      iex> alias Ezagent.UI.CommandSource
      iex> CommandSource.search("   ", [%{key: "a", kind: :nav, label: "A",
      ...>   target: "/a", icon: "dot", group: "G"}]) |> length()
      1
  """
  @spec search(query :: String.t(), candidates :: [result()]) :: [result()]
  def search(query, candidates) when is_binary(query) and is_list(candidates) do
    case normalize(query) do
      "" ->
        Enum.take(candidates, @result_limit)

      norm ->
        candidates
        |> Enum.filter(&fuzzy_match?(&1.label, norm))
        |> Enum.sort_by(&match_rank(&1, norm))
        |> Enum.take(@result_limit)
    end
  end

  # --- ranking internals -----------------------------------------------------

  defp normalize(query), do: query |> String.trim() |> String.downcase()

  # A subsequence match: every character of `query` appears in `label`
  # in order. Tolerant — "ssn" matches "Sessions" — but the sort below
  # keeps tight prefix/substring matches at the top.
  defp fuzzy_match?(label, query) do
    subsequence?(String.downcase(label), query)
  end

  defp subsequence?(_label, ""), do: true
  defp subsequence?("", _query), do: false

  defp subsequence?(<<c::utf8, label_rest::binary>>, <<c::utf8, query_rest::binary>>),
    do: subsequence?(label_rest, query_rest)

  defp subsequence?(<<_c::utf8, label_rest::binary>>, query),
    do: subsequence?(label_rest, query)

  # Lower rank sorts first. Tiers:
  #   0 — exact label match
  #   1 — label starts with the query
  #   2 — query is a contiguous substring of the label
  #   3 — fuzzy subsequence only
  # Ties broken by label length (shorter = more specific) then label
  # alphabetically (stable, deterministic).
  defp match_rank(%{label: label}, query) do
    down = String.downcase(label)

    tier =
      cond do
        down == query -> 0
        String.starts_with?(down, query) -> 1
        String.contains?(down, query) -> 2
        true -> 3
      end

    {tier, String.length(label), down}
  end
end
