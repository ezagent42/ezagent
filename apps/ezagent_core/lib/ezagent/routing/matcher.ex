defmodule Ezagent.Routing.Matcher do
  @moduledoc """
  Routing matchers — predicates over `%Ezagent.Message{}` used by
  `Ezagent.Routing.Resolver` to derive recipients (Phase 3 落地 Decision
  #41 / #42 / #70).

  Per Decision #70 (boundary "reads core data → core"): all 5 leaf
  matchers read `%Ezagent.Message{}` fields, so they live in `ezagent_core`.
  Plugin-payload matchers (e.g. `feishu_card_type`) belong in the
  plugin that owns that payload.

  ## 5 leaf matchers + 3 combinators (Phase 4-completion Spec 05 Part B)

  Leaves (Phase 3):
  - `mention(URI.t())` — `URI` in `message.mentions`
  - `from(URI.t())` — `message.sender == URI`
  - `text_contains(String.t())` — body text contains substring
  - `text_matches(regex_string)` — body text matches Elixir-regex string
  - `always()` — unconditional true (catchall rule use)

  Combinators (Phase 4-completion):
  - `all_of([m1, m2, ...])` — `{:and, list}` — every leaf must match
  - `any_of([m1, m2, ...])` — `{:or, list}` — at least one
  - `negate(m)` — `{:not, m}` — single nested negation

  ## Shape

  Matchers are plain Elixir tuples (Decision #42 JSON-serializable):
  - `{:mention, "entity://user/system/admin"}` (URI as string for JSON round-trip)
  - `{:from, "entity://agent/team-alpha/cc_builder"}`
  - `{:text_contains, "urgent"}`
  - `{:text_matches, "^/help"}`
  - `{:always}`

  ## Why string URIs in matcher tuples (not %URI{})

  Matchers persist to SQLite via Jason; URI struct doesn't round-trip
  through JSON cleanly (Jason serializes %URI{} as string via the
  `defimpl Jason.Encoder, for: URI` from `Ezagent.Message`, but
  deserializes to plain string). Storing as string in the matcher
  tuple makes the JSON round-trip explicit + symmetric.
  """

  # Phase 4-completion Spec 05 Part B B.1: combinator clauses use
  # `match?/2` recursively in `:and` / `:or` / `:not` clauses. Exclude
  # Kernel.match?/2 to avoid the new conflict-warning in Elixir 1.18+.
  import Kernel, except: [match?: 2, match?: 3]

  @type matcher ::
          {:mention, String.t()}
          | {:from, String.t()}
          | {:from_role, String.t()}
          | {:text_contains, String.t()}
          | {:text_matches, String.t()}
          | {:in_session, String.t()}
          | {:always}
          | {:and, [matcher()]}
          | {:or, [matcher()]}
          | {:not, matcher()}

  # --- Constructors (accept URI struct OR string) -----------------------

  @doc "Match if `uri` is in message.mentions."
  @spec mention(URI.t() | String.t()) :: matcher()
  def mention(%URI{} = uri), do: {:mention, URI.to_string(uri)}
  def mention(uri) when is_binary(uri), do: {:mention, uri}

  @doc "Match if message.sender == uri."
  @spec from(URI.t() | String.t()) :: matcher()
  def from(%URI{} = uri), do: {:from, URI.to_string(uri)}
  def from(uri) when is_binary(uri), do: {:from, uri}

  @doc "Match if message.sender currently holds a session role."
  @spec from_role(String.t()) :: matcher()
  def from_role(role_name) when is_binary(role_name) and role_name != "",
    do: {:from_role, role_name}

  @doc "Match if message.body.text contains substring."
  @spec text_contains(String.t()) :: matcher()
  def text_contains(s) when is_binary(s), do: {:text_contains, s}

  @doc "Match if message.body.text matches Elixir regex (string form)."
  @spec text_matches(String.t()) :: matcher()
  def text_matches(re) when is_binary(re) do
    # Validate at construction so bad regex fails fast, not at first match.
    {:ok, _} = Regex.compile(re)
    {:text_matches, re}
  end

  @doc "Always match — catchall rule constructor."
  @spec always() :: matcher()
  def always, do: {:always}

  @doc """
  Match if message originated in a specific session.

  Without this, all routing rules apply globally — a rule
  `always() → [entity://agent/team-alpha/cc_alerts]` would fire for EVERY
  session's send. `in_session(session_uri)` scopes a rule to one
  session so an agent / receiver can subscribe to one session via
  routing rule without affecting unrelated sessions.

  (Pre-PR-144 this was also how the Feishu plugin bound a chat to
  a session — `in_session(session) → [feishu://oc_X]`. The
  `feishu://` Receiver Kind was deleted (SPEC §5.8). Post-PR-EM-6
  the binding lives in the generic `external_mirror_bindings`
  projection table maintained by `Ezagent.ActionSet.ExternalMirror`;
  the outbound mirror is a per-binding Worker Kind (one per
  session × adapter × target) — not a routing rule.)
  """
  @spec in_session(URI.t() | String.t()) :: matcher()
  def in_session(%URI{} = uri), do: {:in_session, URI.to_string(uri)}
  def in_session(uri) when is_binary(uri), do: {:in_session, uri}

  # --- Combinators (Phase 4-completion Spec 05 Part B B.1) -------------

  @doc """
  Conjunction: all sub-matchers must evaluate true. `Enum.all?` short-
  circuits on first false. Empty list = vacuously true (Spec 05 B.1 §A).
  """
  @spec all_of([matcher()]) :: matcher()
  def all_of(list) when is_list(list), do: {:and, list}

  @doc """
  Disjunction: at least one sub-matcher must evaluate true. `Enum.any?`
  short-circuits on first true. Empty list = vacuously false (Spec 05 B.1 §A).
  """
  @spec any_of([matcher()]) :: matcher()
  def any_of(list) when is_list(list), do: {:or, list}

  @doc """
  Negation: single nested matcher flipped. Named `negate/1` to avoid
  collision with `Kernel.not/1` (Spec 05 §B.1 §A naming).
  """
  @spec negate(matcher()) :: matcher()
  def negate(m) when is_tuple(m), do: {:not, m}

  # --- Predicate ---------------------------------------------------------

  @doc """
  Evaluate a matcher against a Message. Returns `true` / `false`.

  `:text_matches` recompiles the regex per call — Phase 3 acceptable
  (rules are <100; eval is microsecond). Phase 4+ can memoize compiled
  regex if profiling shows.
  """
  @spec match?(matcher(), Ezagent.Message.t()) :: boolean()
  def match?(matcher, %Ezagent.Message{} = msg), do: match?(matcher, msg, %{})

  @doc """
  Evaluate a matcher against a Message plus pure routing context.

  Context keys:
    * `:members` — current session member snapshot, keyed by member URI, whose
      values may carry `:role_name` or `"role_name"` facets.
  """
  @spec match?(matcher(), Ezagent.Message.t(), map()) :: boolean()
  def match?({:mention, token}, %Ezagent.Message{} = msg, _ctx) do
    # A `mention(token)` matcher fires when `token` is in `message.mentions`
    # (concrete agent/user URIs — the usual case) OR in
    # `message.legend_triggers` (team-routing §3.6, PR-6 — the SYMBOLIC legend
    # NAME a rule-set ENTRY rule keys on, e.g. `mention("传话游戏")`). The legend
    # name CANNOT ride `:mentions` (typed `[URI.t()]`; a CJK / non-URI name
    # crashes the Ecto cast), so it rides the virtual `:legend_triggers` and is
    # matched here — letting the entry rule fire through the NORMAL Resolver
    # expansion (matched-rule ctx + magic-receiver expansion intact).
    mention_match?(msg.mentions, token) or
      legend_trigger_match?(Map.get(msg, :legend_triggers) || [], token)
  end

  def match?({:from, uri_str}, %Ezagent.Message{sender: sender}, _ctx) do
    case sender do
      %URI{} = u -> URI.to_string(u) == uri_str
      s when is_binary(s) -> s == uri_str
    end
  end

  def match?({:from_role, role_name}, %Ezagent.Message{sender: sender}, ctx) do
    sender_role?(sender, role_name, Map.get(ctx, :members, %{}))
  end

  def match?({:in_session, session_str}, %Ezagent.Message{session_uri: session_uri}, _ctx) do
    case session_uri do
      %URI{} = u -> URI.to_string(u) == session_str
      s when is_binary(s) -> s == session_str
      _ -> false
    end
  end

  def match?({:text_contains, sub}, %Ezagent.Message{body: body}, _ctx) do
    case extract_text(body) do
      text when is_binary(text) -> String.contains?(text, sub)
      _ -> false
    end
  end

  def match?({:text_matches, re_str}, %Ezagent.Message{body: body}, _ctx) do
    case extract_text(body) do
      text when is_binary(text) ->
        {:ok, re} = Regex.compile(re_str)
        Regex.match?(re, text)

      _ ->
        false
    end
  end

  def match?({:always}, _msg, _ctx), do: true

  # Combinators
  def match?({:and, sub_matchers}, %Ezagent.Message{} = msg, ctx) when is_list(sub_matchers) do
    Enum.all?(sub_matchers, &match?(&1, msg, ctx))
  end

  def match?({:or, sub_matchers}, %Ezagent.Message{} = msg, ctx) when is_list(sub_matchers) do
    Enum.any?(sub_matchers, &match?(&1, msg, ctx))
  end

  def match?({:not, sub_matcher}, %Ezagent.Message{} = msg, ctx) do
    not match?(sub_matcher, msg, ctx)
  end

  # --- JSON serde (Decision #42 / DECISIONS P3-D impl Matcher AST) ------

  @doc """
  Serialize matcher to JSON-friendly map for `RuleStore` persistence.

  Format: `%{"type" => "<atom_name>", "arg" => <string>}`.
  `:always` has no arg.
  """
  @spec to_json(matcher()) :: map()
  def to_json({:mention, uri_str}), do: %{"type" => "mention", "arg" => uri_str}
  def to_json({:from, uri_str}), do: %{"type" => "from", "arg" => uri_str}
  def to_json({:from_role, role_name}), do: %{"type" => "from_role", "arg" => role_name}
  def to_json({:text_contains, sub}), do: %{"type" => "text_contains", "arg" => sub}
  def to_json({:text_matches, re}), do: %{"type" => "text_matches", "arg" => re}
  def to_json({:always}), do: %{"type" => "always"}
  def to_json({:in_session, uri_str}), do: %{"type" => "in_session", "arg" => uri_str}

  # Combinators
  def to_json({:and, list}) when is_list(list),
    do: %{"type" => "and", "items" => Enum.map(list, &to_json/1)}

  def to_json({:or, list}) when is_list(list),
    do: %{"type" => "or", "items" => Enum.map(list, &to_json/1)}

  def to_json({:not, m}), do: %{"type" => "not", "item" => to_json(m)}

  @doc """
  Deserialize from JSON map back to matcher tuple.

  Returns `{:ok, matcher}` or `{:error, reason}` — caller validates.
  """
  @spec from_json(map()) :: {:ok, matcher()} | {:error, term()}
  def from_json(%{"type" => "mention", "arg" => uri}) when is_binary(uri),
    do: {:ok, mention(uri)}

  def from_json(%{"type" => "from", "arg" => uri}) when is_binary(uri),
    do: {:ok, from(uri)}

  def from_json(%{"type" => "from_role", "arg" => role_name}) when is_binary(role_name),
    do: {:ok, from_role(role_name)}

  def from_json(%{"type" => "text_contains", "arg" => sub}) when is_binary(sub),
    do: {:ok, text_contains(sub)}

  def from_json(%{"type" => "text_matches", "arg" => re}) when is_binary(re) do
    try do
      {:ok, text_matches(re)}
    rescue
      e -> {:error, {:invalid_regex, Exception.message(e)}}
    end
  end

  def from_json(%{"type" => "always"}), do: {:ok, always()}

  def from_json(%{"type" => "in_session", "arg" => uri}) when is_binary(uri),
    do: {:ok, in_session(uri)}

  # Combinators — recursive descent
  def from_json(%{"type" => "and", "items" => items}) when is_list(items) do
    decode_list(items, [])
    |> case do
      {:ok, list} -> {:ok, all_of(list)}
      err -> err
    end
  end

  def from_json(%{"type" => "or", "items" => items}) when is_list(items) do
    decode_list(items, [])
    |> case do
      {:ok, list} -> {:ok, any_of(list)}
      err -> err
    end
  end

  def from_json(%{"type" => "not", "item" => item}) when is_map(item) do
    case from_json(item) do
      {:ok, m} -> {:ok, negate(m)}
      err -> err
    end
  end

  def from_json(other), do: {:error, {:invalid_matcher_json, other}}

  defp decode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_list([item | rest], acc) do
    case from_json(item) do
      {:ok, m} -> decode_list(rest, [m | acc])
      err -> err
    end
  end

  # --- Internals --------------------------------------------------------

  # Body can have atom OR string keys (in-flight vs loaded from MessageStore).
  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: nil

  defp sender_role?(sender, role_name, members) when is_map(members) do
    sender_str = uri_to_string(sender)

    Enum.any?(members, fn {member_uri, meta} ->
      uri_to_string(member_uri) == sender_str and role_name_of(meta) == role_name
    end)
  end

  defp sender_role?(_sender, _role_name, _members), do: false

  defp role_name_of(%{role_name: role_name}) when is_binary(role_name), do: role_name
  defp role_name_of(%{"role_name" => role_name}) when is_binary(role_name), do: role_name
  defp role_name_of(_), do: nil

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(uri) when is_binary(uri), do: uri
  defp uri_to_string(_), do: nil

  # Concrete-URI mention match (the usual `@agent` path).
  defp mention_match?(mentions, token) when is_list(mentions) do
    Enum.any?(mentions, fn
      %URI{} = u -> URI.to_string(u) == token
      s when is_binary(s) -> s == token
      _ -> false
    end)
  end

  defp mention_match?(_, _), do: false

  # Symbolic legend-name match (team-routing §3.6, PR-6) — the virtual
  # `legend_triggers` carries plain name strings (e.g. "传话游戏").
  defp legend_trigger_match?(triggers, token) when is_list(triggers) do
    Enum.any?(triggers, fn t -> t == token end)
  end

  defp legend_trigger_match?(_, _), do: false
end
