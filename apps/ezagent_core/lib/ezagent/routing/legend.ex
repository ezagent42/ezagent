defmodule Ezagent.Routing.Legend do
  @moduledoc """
  Legend registry + resolution layer (team-routing-unification §3.6, PR-6).

  A **Legend** is a session-scoped *symbolic handle* for a team of members:

      %{name, member_set (URIs and/or role_names), bound_rule_set, fold}

  It is NOT a member/agent URI. A user `@`-mentioning a legend name means
  "trigger the bound rule-set's entry rule" (spec §3.6 semantics A) — NOT
  "deliver to a concrete recipient". So a legend name must NOT ride
  `Ezagent.Routing.Matcher.mention/1` (which matches concrete URIs in
  `message.mentions`): if it did, the URI-mention path would either silent-drop
  it (no live agent named `传话游戏`) or mis-route it. This module is the
  dedicated resolution layer the mention parsers (LiveView + Feishu) consult
  BEFORE their URI-mention path.

  ## Storage (session-scoped)

  The legend registry is a plain map `name => %{member_set, bound_rule_set,
  fold}` stored in the Chat session slice (`:legends`, persistent `state`),
  alongside `:members`. This module is pure over that map — it never reads the
  slice directly, so it stays a `ezagent_core` routing primitive (no
  core→domain dependency). The Chat behavior owns read/write of the slice key;
  callers pass the map in.

  ## Resolution flow (how a `@legend` fires its rule-set entry)

  1. A parser sees a typed `@name`. It calls `mention_token/2`.
  2. If `name` is a registered legend → `{:legend, name}`: the parser emits the
     **legend NAME string** into the message's VIRTUAL `:legend_triggers` field
     (NOT `:mentions` — a CJK / non-URI name would crash the `[URI.t()]` Ecto
     cast), and crucially does NOT also resolve that token through the
     URI-mention path.
  3. The rule-set's **entry rule** is `mention(<legend_name>) → <first hop>`
     (a symbolic-string mention matcher — see `Ezagent.Routing.Matcher`). When
     the Resolver runs, `Matcher.match?({:mention, name}, msg)` is true because
     `name` is in `message.legend_triggers`, so the entry rule fires — through
     the NORMAL `Resolver.resolve_with_ctx/4` path, which carries the entry's
     `prompt_template_ref` (PR-4 delivery transform) AND expands magic
     receivers (`$session_members`, …) on the entry's `receivers`.

  `entry_rule/2` is provided so callers/tests can fetch a rule-set's entry (the
  lowest-`position` rule) deterministically.

  ## Fold (UI)

  A folded legend collapses its members into ONE legend row in the member-list
  UI (declutter — Allen). They remain **first-class members**: the underlying
  members map is unchanged, so each folded member is still individually
  `@`-able (by URI or role_name) and snapshot-able. `fold_members/3` is the pure
  presentation transform the member-list component applies.
  """

  alias Ezagent.Routing.RuleStore

  @typedoc """
  A legend registry entry. `member_set` holds member role_names and/or URI
  strings; `bound_rule_set` is the name of the rule-set this legend fronts;
  `fold` controls UI collapse.
  """
  @type entry :: %{
          name: String.t(),
          member_set: [String.t()],
          bound_rule_set: String.t() | nil,
          fold: boolean()
        }

  @typedoc "Session-scoped legend registry: `name => entry` (minus the name key)."
  @type registry :: %{optional(String.t()) => map()}

  @doc """
  Install/overwrite a legend in the registry. `opts`:

    * `:member_set` — list of role_names and/or URI strings (default `[]`)
    * `:bound_rule_set` — the rule-set name the legend fronts (default `nil`)
    * `:fold` — collapse members into one UI row (default `false`)

  Returns the updated registry map.
  """
  @spec put(registry(), String.t(), keyword()) :: registry()
  def put(legends, name, opts \\ []) when is_map(legends) and is_binary(name) do
    Map.put(legends, name, %{
      member_set: Keyword.get(opts, :member_set, []),
      bound_rule_set: Keyword.get(opts, :bound_rule_set),
      fold: Keyword.get(opts, :fold, false)
    })
  end

  @doc """
  Look up a legend by name. Returns `{:ok, entry}` (with `:name` folded in) or
  `:error`.
  """
  @spec get(registry(), String.t()) :: {:ok, entry()} | :error
  def get(legends, name) when is_map(legends) and is_binary(name) do
    case Map.fetch(legends, name) do
      {:ok, %{} = e} -> {:ok, Map.put(e, :name, name)}
      :error -> :error
    end
  end

  def get(_legends, _name), do: :error

  @doc "Is `name` a registered legend in this session?"
  @spec legend?(registry(), term()) :: boolean()
  def legend?(legends, name) when is_map(legends) and is_binary(name),
    do: Map.has_key?(legends, name)

  def legend?(_legends, _name), do: false

  @doc "All registered legend names."
  @spec names(registry()) :: [String.t()]
  def names(legends) when is_map(legends), do: Map.keys(legends)

  @doc """
  Resolve a legend NAME to its entry (the bound rule-set handle).

  This is the core of the resolution layer (spec §3.6): a `@legend` symbolic
  handle yields "fire its bound rule-set's entry". The returned `entry` carries
  `:bound_rule_set`; the entry rule itself (matched by `mention(name)`) is
  fetched via `entry_rule/2` when a caller needs the concrete rule.

  `{:ok, entry}` for a registered legend, `:error` otherwise.
  """
  @spec resolve(registry(), String.t()) :: {:ok, entry()} | :error
  def resolve(legends, name), do: get(legends, name)

  @doc """
  Parser precedence helper: classify a typed `@name`.

    * `{:legend, name}` — `name` is a registered legend; the parser emits the
      legend NAME as the symbolic mention token and MUST NOT also resolve it
      through the URI-mention path.
    * `:not_a_legend` — fall through to normal URI-mention handling.

  This is what makes a legend take precedence over a concrete URI mention
  (spec §3.6, GATE b): the legend name never reaches the URI matcher.
  """
  @spec mention_token(registry(), String.t()) :: {:legend, String.t()} | :not_a_legend
  def mention_token(legends, name) when is_map(legends) and is_binary(name) do
    if legend?(legends, name), do: {:legend, name}, else: :not_a_legend
  end

  def mention_token(_legends, _name), do: :not_a_legend

  @doc """
  The entry rule of a named rule-set: the lowest-`position` enabled rule whose
  `rule_set` equals `name`. Ties on `position` break by lowest `id` (earliest
  created) — deterministic. Returns `{:ok, rule}` (a `RuleStore.t()`) or
  `:error` when the rule-set has no rules.

  This is the rule a legend `@`-trigger fires; it carries the set's
  `prompt_template_ref` and the receiver of the flow's first hop.
  """
  @spec entry_rule(atom(), String.t()) :: {:ok, RuleStore.t()} | :error
  def entry_rule(table_name_atom, name)
      when is_atom(table_name_atom) and is_binary(name) do
    RuleStore.list(table_name_atom)
    |> Enum.filter(fn r -> r.enabled and r.rule_set == name end)
    |> Enum.sort_by(fn r -> {r.position, r.id} end)
    |> case do
      [entry | _] -> {:ok, entry}
      [] -> :error
    end
  end

  @doc """
  Collapse folded-legend members into a single legend row for the member-list
  UI (spec §3.6 fold). Pure presentation transform — does NOT mutate the
  members map, so every collapsed member stays a first-class, individually
  `@`-able member.

  `members` is the Chat slice `:members` map (`%{URI => meta}`). `legends` is
  the session legend registry. `role_resolver` is a `(role_name -> URI | nil)`
  closure (the `Ezagent.Behavior.Chat.role_name_to_uri/2` contract) used to map
  a legend's `member_set` role_names to live member URIs; a `member_set` entry
  that is already a URI string is resolved directly.

  Returns a list of rows:

    * `{:legend, name, [URI.t()]}` — one row per FOLDED legend, carrying the
      collapsed member URIs (so the UI can still expand / @ them).
    * `{:member, URI.t(), meta}` — a plain member row (NOT collapsed into any
      folded legend).

  Members belonging to a non-folded legend are left as plain `:member` rows.
  """
  @spec fold_members(map(), registry(), (String.t() -> URI.t() | nil)) :: [
          {:legend, String.t(), [URI.t()]} | {:member, URI.t(), map()}
        ]
  def fold_members(members, legends, role_resolver)
      when is_map(members) and is_map(legends) and is_function(role_resolver, 1) do
    folded_legends =
      legends
      |> Enum.filter(fn {_name, e} -> Map.get(e, :fold, false) end)

    # URIs (as canonical strings) that are collapsed into SOME folded legend.
    collapsed_uri_strs =
      folded_legends
      |> Enum.flat_map(fn {_name, e} -> resolve_member_set(e, members, role_resolver) end)
      |> Enum.map(&URI.to_string/1)
      |> MapSet.new()

    legend_rows =
      folded_legends
      |> Enum.map(fn {name, e} ->
        {:legend, name, resolve_member_set(e, members, role_resolver)}
      end)

    member_rows =
      members
      |> Enum.reject(fn {uri, _meta} -> URI.to_string(uri) in collapsed_uri_strs end)
      |> Enum.map(fn {uri, meta} -> {:member, uri, meta} end)

    legend_rows ++ member_rows
  end

  # Resolve a legend entry's member_set (role_names and/or URI strings) to the
  # subset of live member URIs. role_names go through the resolver; URI strings
  # are matched against the live members map. Unresolvable entries drop.
  defp resolve_member_set(entry, members, role_resolver) do
    member_strs = members |> Map.keys() |> MapSet.new(&Ezagent.URI.stable_key/1)

    entry
    |> Map.get(:member_set, [])
    |> Enum.flat_map(fn ref ->
      cond do
        # A URI-string member_set entry — keep iff it's a live member.
        is_binary(ref) and MapSet.member?(member_strs, ref) ->
          [safe_uri(ref)]

        # Otherwise treat it as a role_name and resolve via the closure.
        is_binary(ref) ->
          case role_resolver.(ref) do
            %URI{} = uri -> [uri]
            _ -> []
          end

        true ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&Ezagent.URI.stable_key/1)
  end

  defp safe_uri(s) do
    # #23 — use the canonical non-raising constructor (validates + canonicalizes the
    # Ezagent-scheme URI) instead of stdlib URI.new!, which yields a non-canonical struct
    # for Ezagent schemes (the silent-error hole the URI invariant guards).
    case Ezagent.URI.parse(s) do
      {:ok, uri} -> uri
      {:error, _} -> nil
    end
  end
end
