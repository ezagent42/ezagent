defmodule Ezagent.UriQuery.Scan do
  @moduledoc """
  Source scanner for the unify-uri-query migration.

  PR-0 is intentionally warn-only: this module inventories URI construction
  and URI-derived attribute reads so later PRs can hard-fail individual
  categories before their breaking changes land.
  """

  defmodule Violation do
    @moduledoc "One source-level unify-uri-query scan finding."

    @enforce_keys [:category, :path, :line, :rule, :snippet]
    defstruct [:category, :path, :line, :rule, :snippet]

    @type t :: %__MODULE__{
            category: atom(),
            path: String.t(),
            line: pos_integer(),
            rule: String.t(),
            snippet: String.t()
          }
  end

  @affected_schemes ~w(entity session template resource workspace system)
  @per_tenant_schemes ~w(entity session template resource)
  # External transport/protocol URLs; additions must be explicitly classified.
  @external_url_allowlist ~w(postgresql unix http https ws test cc-bridge)
  @agent_flavor_prefixes ~w(cc_ codex_ curl_ echo_ np_)
  @known_categories [
    :flavor_prefix_dependency,
    :home_path_in_runtime_code,
    :orchestrator_derivation,
    :parse_error,
    :positional_uri_read,
    :raw_cross_cutting_uri_construction,
    :raw_uri_construction,
    :tenant_derivation,
    :unknown_scheme_construction,
    :uri_string_key
  ]

  @home_functions [:path, :profile_dir, :home]

  @default_globs [
    "apps/**/*.ex"
  ]

  @default_excluded_paths [
    "apps/ezagent_core/lib/ezagent/uri.ex",
    "apps/ezagent_core/lib/ezagent/uri_query/scan.ex",
    # Scan data/anchor modules embed literals that would otherwise self-trip.
    "apps/ezagent_core/lib/ezagent/uri_query/scan/home_path_exceptions.ex",
    "apps/ezagent_core/lib/ezagent/uri_query/scan/home_path_baseline.ex",
    "apps/ezagent_core/lib/mix/tasks/ezagent.uri_query.scan.ex"
  ]

  @doc "Scan all production `.ex` files under `apps/`."
  @spec scan(keyword()) :: [Violation.t()]
  def scan(opts \\ []) do
    opts
    |> source_paths()
    |> scan_paths(opts)
  end

  @doc """
  Scan the given paths and return sorted findings.

  Options:

    * `:exclude` — paths to skip (defaults to `@default_excluded_paths`).
    * `:baseline` — line-anchored burn-down list of tolerated raw `Home`
      callers (defaults to `HomePathBaseline.all/0`). A `home_path_in_runtime_code`
      finding is dropped only when a baseline entry matches its `{path, line}`.
    * `:exceptions` — exact `Module.function/arity` + line anchors for permanently
      sanctioned raw `Home` callers (defaults to `HomePathExceptions.all/0`).
      An exception is honored only when the finding's enclosing function id
      EQUALS the anchor's `fun_id` at the recorded line (codex MEDIUM:
      enclosing-function identity, not `{path, line}` alone).
  """
  @spec scan_paths([Path.t()], keyword()) :: [Violation.t()]
  def scan_paths(paths, opts \\ []) when is_list(paths) do
    excluded = MapSet.new(Keyword.get(opts, :exclude, @default_excluded_paths))
    baseline = Keyword.get(opts, :baseline, Ezagent.UriQuery.Scan.HomePathBaseline.all())
    exceptions = Keyword.get(opts, :exceptions, Ezagent.UriQuery.Scan.HomePathExceptions.all())

    paths
    |> Enum.reject(&MapSet.member?(excluded, normalize_path(&1)))
    |> Enum.flat_map(&scan_path(&1, baseline, exceptions))
    |> Enum.sort_by(&{&1.path, &1.line, to_string(&1.category), &1.rule})
  end

  @doc "Return finding counts by category."
  @spec counts_by_category([Violation.t()]) :: %{atom() => non_neg_integer()}
  def counts_by_category(violations) do
    Enum.frequencies_by(violations, & &1.category)
  end

  @doc "Return the category names this scanner may emit."
  @spec known_categories() :: [atom()]
  def known_categories, do: @known_categories

  defp source_paths(opts) do
    root = repo_root!()
    globs = Keyword.get(opts, :globs, @default_globs)

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.contains?(&1, "/_build/"))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    # Runtime-loaded E2E scenarios are test fixtures with raw setup URIs.
    |> Enum.reject(&String.contains?(&1, "/e2e/scenarios/"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan_path(path, baseline, exceptions) do
    source = File.read!(path)
    line_snippets = line_snippets(source)

    ast_violations =
      case Code.string_to_quoted(source, columns: true, token_metadata: true) do
        {:ok, ast} ->
          ast_findings(ast, path, line_snippets) ++
            home_path_findings(ast, path, line_snippets, baseline, exceptions)

        {:error, {line, error, token}} ->
          [
            violation(
              :parse_error,
              path,
              line || 1,
              "source must parse before URI-query scan can classify it",
              Exception.format_file_line(path, line || 1) <> format_parse_error(error, token)
            )
          ]
      end

    ast_violations ++ source_text_findings(source, path)
  end

  defp ast_findings(ast, path, line_snippets) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, acc ++ node_findings(node, path, line_snippets)}
      end)

    findings
  end

  defp node_findings(node, path, line_snippets) do
    [
      positional_uri_read_finding(node, path, line_snippets),
      flavor_prefix_dependency_finding(node, path, line_snippets),
      tenant_derivation_finding(node, path, line_snippets),
      orchestrator_derivation_finding(node, path, line_snippets)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # Flags every `Ezagent.Home.path/1` / `Home.profile_dir/0` / `Home.home/0` call
  # in runtime app code, MINUS the line-anchored baseline (burn-down) and MINUS
  # the exact `Module.function/arity` exceptions. Anchor subtraction is by
  # enclosing-function identity (codex MEDIUM), never `{path, line}` alone.
  defp home_path_findings(ast, path, snippets, baseline, exceptions) do
    rel_path = normalize_path(path)
    fun_index = function_anchor_index(ast)
    # A baseline tolerates only its recorded call count; extra calls still fire.
    baseline_budget = baseline_budget_for(baseline, rel_path)

    {findings, _budget} =
      ast
      |> home_call_sites()
      |> Enum.reduce({[], baseline_budget}, fn {line, fun}, {acc, budget} ->
        cond do
          exception_matches?(exceptions, rel_path, fun_index, line) ->
            {acc, budget}

          Map.get(budget, line, 0) > 0 ->
            {acc, Map.update!(budget, line, &(&1 - 1))}

          true ->
            {[home_violation(path, line, fun, snippets) | acc], budget}
        end
      end)

    Enum.reverse(findings)
  end

  defp home_violation(path, line, fun, snippets) do
    violation(
      :home_path_in_runtime_code,
      path,
      line,
      "new raw Ezagent.Home.#{fun} call in runtime app code — resolve via resource:// " <>
        "(add an exact Module.function/arity exception only for boot/operator/OS-handle callers)",
      snippet(snippets, line: line)
    )
  end

  # All Home.{path,profile_dir,home} call sites in the AST as [{line, fun_atom}].
  # Matches the fully-qualified `Ezagent.Home.path(...)`, the plain
  # `alias Ezagent.Home` (→ `Home.path(...)`), AND a renamed
  # `alias Ezagent.Home, as: H` (→ `H.path(...)`) — codex HIGH: a renamed alias
  # must not bypass the gate. An `import Ezagent.Home` (bare `path(...)`) is also
  # caught. Never matches a local `home.path` variable/struct field access.
  defp home_call_sites(ast) do
    aliases = home_alias_names(ast)
    imported = home_imported_functions(ast)

    {_ast, sites} =
      Macro.prewalk(ast, [], fn node, acc ->
        case home_call(node, aliases, imported) do
          {line, fun} -> {node, [{line, fun} | acc]}
          nil -> {node, acc}
        end
      end)

    Enum.sort(sites)
  end

  # Remote call on a module alias that resolves to Ezagent.Home. `List.last(mods)`
  # also catches the `__MODULE__.Home.path(...)` shape (mods ends in `:Home`).
  defp home_call({{:., meta, [{:__aliases__, _, mods}, fun]}, _call_meta, _args}, aliases, _imp)
       when is_list(mods) and fun in @home_functions do
    last = List.last(mods)

    cond do
      # fully-qualified Ezagent.Home.path / plain `alias Ezagent.Home` /
      # `__MODULE__.Home.path` → trailing segment is `:Home`
      last == :Home -> {line(meta), fun}
      # `alias Ezagent.Home, as: H` → single-segment module H
      mods == [last] and MapSet.member?(aliases, last) -> {line(meta), fun}
      true -> nil
    end
  end

  # Bare local call to a function imported from Ezagent.Home (respecting the
  # `only:`/`except:` narrowing — `imported` is the set actually in scope).
  defp home_call({fun, meta, args}, _aliases, imported)
       when fun in @home_functions and is_list(args) do
    if MapSet.member?(imported, fun), do: {line(meta), fun}, else: nil
  end

  defp home_call(_node, _aliases, _imported), do: nil

  # Collect every alias name (last/renamed segment) that points to Ezagent.Home.
  # Handles `alias Ezagent.Home`, `alias Ezagent.Home, as: H`, and the
  # multi-alias `alias Ezagent.{Home, Foo}` form.
  defp home_alias_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn node, acc -> {node, alias_names(node) ++ acc} end)

    MapSet.new(names)
  end

  # `alias Ezagent.Home, as: H`
  defp alias_names({:alias, _, [{:__aliases__, _, mods}, [{:as, {:__aliases__, _, [as]}}]]})
       when is_list(mods) do
    if List.last(mods) == :Home, do: [as], else: []
  end

  # `alias Ezagent.Home` (no `:as`) → bound as `Home`
  defp alias_names({:alias, _, [{:__aliases__, _, mods}]}) when is_list(mods) do
    if List.last(mods) == :Home, do: [:Home], else: []
  end

  # `alias Ezagent.{Home, Foo}` → each child bound as its own last segment
  defp alias_names({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]})
       when is_list(base) and is_list(children) do
    for {:__aliases__, _, child} <- children,
        List.last(base ++ child) == :Home,
        do: List.last(child)
  end

  defp alias_names(_node), do: []

  # The set of Home functions brought into scope by an `import Ezagent.Home`,
  # respecting `only: [...]` / `except: [...]` narrowing. A plain
  # `import Ezagent.Home` imports all of `@home_functions`; `only:` restricts to
  # the listed names; `except:` removes the listed names. (Lexical per-scope
  # narrowing is out of scope — a file-level union is conservative for a gate;
  # only/except is the realistic false-positive source codex flagged.)
  defp home_imported_functions(ast) do
    {_ast, imported} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:import, _, [{:__aliases__, _, mods} | rest]} = node, acc when is_list(mods) ->
          if List.last(mods) == :Home do
            {node, MapSet.union(acc, imported_home_set(rest))}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    imported
  end

  @home_function_set MapSet.new(@home_functions)

  defp imported_home_set([opts | _]) when is_list(opts) do
    cond do
      only = keyword_fun_names(opts, :only) ->
        MapSet.intersection(@home_function_set, only)

      except = keyword_fun_names(opts, :except) ->
        MapSet.difference(@home_function_set, except)

      true ->
        @home_function_set
    end
  end

  defp imported_home_set(_no_opts), do: @home_function_set

  # Extract the function-name set from `only:`/`except:` keyword list value, e.g.
  # `[path: 1, profile_dir: 0]` → MapSet.new([:path, :profile_dir]).
  defp keyword_fun_names(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, list} when is_list(list) ->
        for({name, _arity} when is_atom(name) <- list, do: name) |> MapSet.new()

      _ ->
        nil
    end
  end

  # Per-line tolerance budget = how many baselined Home calls are recorded at
  # each line for this path. Suppress at most that many; extras fire.
  defp baseline_budget_for(baseline, rel_path) do
    baseline
    |> Enum.flat_map(fn
      {^rel_path, line, _call} -> [line]
      _ -> []
    end)
    |> Enum.frequencies()
  end

  # An exception is honored only when there is a function anchor enclosing `line`
  # whose computed Module.function/arity == the recorded fun_id for THIS path.
  defp exception_matches?(exceptions, rel_path, fun_index, line) do
    Enum.any?(exceptions, fn
      {^rel_path, fun_id, ^line, _reason} ->
        enclosing_function_id(fun_index, line) == fun_id

      _ ->
        false
    end)
  end

  @doc """
  S-2 cross-check (codex MEDIUM): true when `path` has EXACTLY one
  `Home.{path,profile_dir,home}` call at `line`, enclosed by a function whose
  computed `Module.function/arity` equals `fun_id`.
  """
  @spec home_call_anchor_matches?(Path.t(), String.t(), pos_integer()) :: boolean()
  def home_call_anchor_matches?(rel_path, fun_id, line) do
    abs_path = Path.join(repo_root!(), rel_path)

    with true <- File.exists?(abs_path),
         {:ok, ast} <- Code.string_to_quoted(File.read!(abs_path)) do
      calls_at_line = ast |> home_call_sites() |> Enum.filter(fn {l, _f} -> l == line end)
      fun_index = function_anchor_index(ast)

      length(calls_at_line) == 1 and enclosing_function_id(fun_index, line) == fun_id
    else
      _ -> false
    end
  end

  @doc "True when `path` has at least one Home.{path,profile_dir,home} call at `line`."
  @spec home_call_at_line?(Path.t(), pos_integer()) :: boolean()
  def home_call_at_line?(rel_path, line) do
    abs_path = Path.join(repo_root!(), rel_path)

    with true <- File.exists?(abs_path),
         {:ok, ast} <- Code.string_to_quoted(File.read!(abs_path)) do
      ast |> home_call_sites() |> Enum.any?(fn {l, _f} -> l == line end)
    else
      _ -> false
    end
  end

  # Build a list of {start_line, end_line, "Module.function/arity"} function
  # anchors from the AST, so a call at `line` can be mapped to its enclosing fn.
  defp function_anchor_index(ast) do
    {_ast, anchors} =
      Macro.prewalk(ast, {[], []}, fn node, {mod_stack, anchors} = acc ->
        case node do
          {:defmodule, _, [{:__aliases__, _, mods} | _]} ->
            {node, {[Module.concat(mods) | mod_stack], anchors}}

          {def_kw, meta, [head | _]} when def_kw in [:def, :defp] ->
            case function_name_arity(head) do
              {name, arity} ->
                mod = List.first(mod_stack) || nil
                fun_id = format_fun_id(mod, name, arity)
                start = line(meta)
                {node, {mod_stack, [{start, end_line(node, meta), fun_id} | anchors]}}

              nil ->
                {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)
      |> then(fn {_n, {_stack, anchors}} -> {ast, anchors} end)

    Enum.sort_by(anchors, fn {start, _end, _id} -> start end)
  end

  defp enclosing_function_id(fun_index, line) do
    fun_index
    |> Enum.filter(fn {start, finish, _id} -> start <= line and line <= finish end)
    # innermost / nearest-preceding function head wins
    |> Enum.max_by(fn {start, _finish, _id} -> start end, fn -> nil end)
    |> case do
      {_start, _finish, id} -> id
      nil -> nil
    end
  end

  # function head AST → {name, arity}. Handles `name(args)`, bare `name`,
  # and guarded `name(args) when guard`.
  defp function_name_arity({:when, _, [head | _guards]}), do: function_name_arity(head)

  defp function_name_arity({name, _meta, args})
       when is_atom(name) and is_list(args),
       do: {name, length(args)}

  defp function_name_arity({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp function_name_arity(_head), do: nil

  defp format_fun_id(nil, name, arity), do: "#{name}/#{arity}"
  defp format_fun_id(mod, name, arity), do: "#{inspect(mod)}.#{name}/#{arity}"

  # End line of a def block: the largest line number appearing in its metadata
  # subtree. `:end` metadata (token_metadata) is most precise; fall back to the
  # deepest line in the node.
  defp end_line(node, meta) do
    case Keyword.get(meta, :end) do
      end_meta when is_list(end_meta) -> Keyword.get(end_meta, :line, max_line(node))
      _ -> max_line(node)
    end
  end

  defp max_line(node) do
    {_node, max} =
      Macro.prewalk(node, 0, fn
        {_form, meta, _args} = n, acc when is_list(meta) ->
          {n, max(acc, Keyword.get(meta, :line, 0))}

        n, acc ->
          {n, acc}
      end)

    max
  end

  defp positional_uri_read_finding(
         {:%, meta, [{:__aliases__, _, [:URI]}, {:%{}, _, pairs}]},
         path,
         snippets
       ) do
    keys =
      pairs
      |> Enum.flat_map(fn
        {key, _value} when is_atom(key) -> [key]
        _other -> []
      end)

    if (:host in keys or :path in keys) and not external_url_pattern?(pairs) do
      violation(
        :positional_uri_read,
        path,
        line(meta),
        "%URI{host: ..., path: ...} positional reads must live in Ezagent.URI",
        snippet(snippets, meta)
      )
    end
  end

  defp positional_uri_read_finding(_node, _path, _snippets), do: nil

  defp external_url_pattern?(pairs) do
    Enum.any?(pairs, fn
      {:scheme, scheme} when scheme in ["http", "https"] -> true
      _pair -> false
    end)
  end

  defp flavor_prefix_dependency_finding(
         {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _, args},
         path,
         snippets
       ) do
    if string_split_on?(args, "_") and not split_parts?(args, 4) do
      violation(
        :flavor_prefix_dependency,
        path,
        line(meta),
        "agent flavor must be read from storage via Ezagent.UriQuery, not split from URI name prefix",
        snippet(snippets, meta)
      )
    end
  end

  defp flavor_prefix_dependency_finding({:derive_flavor, meta, _args}, path, snippets) do
    violation(
      :flavor_prefix_dependency,
      path,
      line(meta),
      "flavor-dependent URI validation/resolution must be backed by stored flavor",
      snippet(snippets, meta)
    )
  end

  defp flavor_prefix_dependency_finding({:agent_uri_prefix, meta, _args}, path, snippets) do
    violation(
      :flavor_prefix_dependency,
      path,
      line(meta),
      "agent URI prefix callbacks preserve flavor-in-URI coupling; use stored flavor",
      snippet(snippets, meta)
    )
  end

  defp flavor_prefix_dependency_finding({:<>, meta, [prefix, _rest]}, path, snippets)
       when prefix in @agent_flavor_prefixes do
    violation(
      :flavor_prefix_dependency,
      path,
      line(meta),
      "agent flavor prefix matches must read stored flavor through Ezagent.UriQuery",
      snippet(snippets, meta)
    )
  end

  # Dynamic flavor-prefix CONSTRUCTION via string interpolation, e.g.
  # `"#{flavor}_#{name}"` — a flavor-bearing interpolation segment immediately
  # followed by an `_`-leading literal segment. The earlier rules only caught
  # parsing (`String.split`) and literal-prefix `<>`; this closes the gap where
  # production code BUILDS a flavor-prefixed agent URI name (codex review).
  defp flavor_prefix_dependency_finding({:<<>>, meta, parts}, path, snippets)
       when is_list(parts) do
    if flavor_underscore_interpolation?(parts) do
      violation(
        :flavor_prefix_dependency,
        path,
        line(meta),
        "agent URI names must not interpolate flavor as a prefix; store flavor and read via Ezagent.UriQuery",
        snippet(snippets, meta)
      )
    end
  end

  defp flavor_prefix_dependency_finding(_node, _path, _snippets), do: nil

  # True if any flavor-bearing interpolation segment is immediately followed by
  # an `_`-leading literal — i.e. a `<flavor>_…` name being constructed.
  defp flavor_underscore_interpolation?(parts) do
    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [seg, next] -> flavor_interpolation_segment?(seg) and underscore_leading_literal?(next)
      _ -> false
    end)
  end

  defp flavor_interpolation_segment?({:"::", _, [expr, {:binary, _, _}]}),
    do: ast_mentions_flavor?(expr)

  defp flavor_interpolation_segment?(_), do: false

  defp ast_mentions_flavor?(ast) do
    ast |> Macro.to_string() |> String.contains?("flavor")
  rescue
    _ -> false
  end

  defp underscore_leading_literal?(bin) when is_binary(bin), do: String.starts_with?(bin, "_")
  defp underscore_leading_literal?(_), do: false

  defp tenant_derivation_finding(
         {{:., meta, [{:__aliases__, _, [:String]}, :split]}, _, args},
         path,
         snippets
       ) do
    if string_split_on?(args, "/") and tenant_bearing_split?(args) do
      violation(
        :tenant_derivation,
        path,
        line(meta),
        "workspace/session/worker derivation from URI segments must be centralized in Ezagent.URI or Ezagent.UriQuery",
        snippet(snippets, meta)
      )
    end
  end

  defp tenant_derivation_finding({kind, meta, [head, [do: body]]}, path, snippets)
       when kind in [:def, :defp] do
    uri_values = uri_pattern_values(head)

    if direct_slash_split_of?(body, uri_values) do
      violation(
        :tenant_derivation,
        path,
        line(meta),
        "workspace/session/worker derivation from URI segments must be centralized in Ezagent.URI or Ezagent.UriQuery",
        snippet(snippets, meta)
      )
    end
  end

  defp tenant_derivation_finding({:workspace_from_3seg_path, meta, _args}, path, snippets) do
    violation(
      :tenant_derivation,
      path,
      line(meta),
      "tenant or worker URI derivation must be centralized before workspace-first reorder",
      snippet(snippets, meta)
    )
  end

  defp tenant_derivation_finding(_node, _path, _snippets), do: nil

  # A slash split is reorder-sensitive only when it is interpreting an opaque
  # ezagent address. Provider refs and relative filesystem paths are independent
  # protocol values; treating every `String.split(value, "/")` as tenant
  # derivation made the gate reject unrelated validation code.
  defp tenant_bearing_split?([expression | _rest]) do
    expression
    |> Macro.to_string()
    |> String.match?(~r/(?:uri|session|workspace|worker)/i)
  end

  defp tenant_bearing_split?(_args), do: false

  defp uri_pattern_values(head) do
    {_head, values} =
      Macro.prewalk(head, MapSet.new(), fn
        {:=, _, [{:%, _, [{:__aliases__, _, [:URI]}, _]}, {name, _, context}]} = node, acc
        when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(acc, name)}

        {:%, _, [{:__aliases__, _, [:URI]}, {:%{}, _, pairs}]} = node, acc ->
          bound =
            Enum.flat_map(pairs, fn
              {_key, {name, _, context}} when is_atom(name) and is_atom(context) ->
                [name]

              {_key, {:<>, _, [_prefix, {name, _, context}]}}
              when is_atom(name) and is_atom(context) ->
                [name]

              _pair ->
                []
            end)

          {node, Enum.reduce(bound, acc, &MapSet.put(&2, &1))}

        node, acc ->
          {node, acc}
      end)

    values
  end

  defp direct_slash_split_of?(body, uri_values) do
    {_body, {_values, found?}} =
      Macro.prewalk(body, {uri_values, false}, fn
        {:=, _,
         [
           {:%{}, _, [{:path, {name, _, context}}]},
           {receiver, _, receiver_context}
         ]} = node,
        {values, found?}
        when is_atom(name) and is_atom(context) and is_atom(receiver) and
               is_atom(receiver_context) ->
          next = if MapSet.member?(values, receiver), do: MapSet.put(values, name), else: values
          {node, {next, found?}}

        {:=, _,
         [
           {name, _, context},
           {{:., _, [{:__aliases__, _, [:Map]}, fetch]}, _,
            [
              {receiver, _, receiver_context},
              :path
            ]}
         ]} = node,
        {values, found?}
        when fetch in [:fetch, :fetch!] and is_atom(name) and is_atom(context) and
               is_atom(receiver) and is_atom(receiver_context) ->
          next = if MapSet.member?(values, receiver), do: MapSet.put(values, name), else: values
          {node, {next, found?}}

        {:=, _,
         [
           {:ok, {name, _, context}},
           {{:., _, [{:__aliases__, _, [:Map]}, :fetch]}, _,
            [
              {receiver, _, receiver_context},
              :path
            ]}
         ]} = node,
        {values, found?}
        when is_atom(name) and is_atom(context) and is_atom(receiver) and
               is_atom(receiver_context) ->
          next = if MapSet.member?(values, receiver), do: MapSet.put(values, name), else: values
          {node, {next, found?}}

        {:=, _, [{name, _, context}, {{:., _, [{receiver, _, receiver_context}, :path]}, _, []}]} =
            node,
        {values, found?}
        when is_atom(name) and is_atom(context) and is_atom(receiver) and
               is_atom(receiver_context) ->
          next = if MapSet.member?(values, receiver), do: MapSet.put(values, name), else: values
          {node, {next, found?}}

        {{:., _, [{:__aliases__, _, [:String]}, :split]}, _, [{name, _, context}, "/" | _]} = node,
        {values, found?}
        when is_atom(name) and is_atom(context) ->
          {node, {values, found? or MapSet.member?(values, name)}}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp orchestrator_derivation_finding({name, meta, _args}, path, snippets)
       when name in [:derive_orchestrator_uri, :derive_orchestrator_instance_name] do
    violation(
      :orchestrator_derivation,
      path,
      line(meta),
      "session orchestrator must be a stored attribute resolved via Ezagent.UriQuery",
      snippet(snippets, meta)
    )
  end

  defp orchestrator_derivation_finding({{:., meta, [_module, name]}, _, _args}, path, snippets)
       when name in [:derive_orchestrator_uri, :derive_orchestrator_instance_name] do
    violation(
      :orchestrator_derivation,
      path,
      line(meta),
      "session orchestrator must be a stored attribute resolved via Ezagent.UriQuery",
      snippet(snippets, meta)
    )
  end

  defp orchestrator_derivation_finding(_node, _path, _snippets), do: nil

  defp source_text_findings(source, path) do
    doc_lines = doc_line_numbers(source)

    raw_uri_findings(source, path, doc_lines) ++ uri_string_key_findings(source, path, doc_lines)
  end

  defp raw_uri_findings(source, path, doc_lines) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line_no} ->
      trimmed = String.trim(text)

      if MapSet.member?(doc_lines, line_no) or String.starts_with?(trimmed, "#") do
        []
      else
        raw_uri_line_findings(path, line_no, trimmed)
      end
    end)
  end

  # Catch-all (T1 project C): every `<scheme>://` literal on a (non-doc,
  # non-comment) line is classified. The gate flipped from "enumerate 6 known
  # schemes" (default-ALLOW everything else) to "block any scheme not on an
  # allowlist" (default-BLOCK, fail-closed — P2 let-it-crash):
  #
  #   * an ezagent per-tenant scheme  → :raw_uri_construction        (use a builder)
  #   * an ezagent cross-cutting scheme → :raw_cross_cutting_uri_construction
  #   * a registered external-URL scheme → no violation              (@external_url_allowlist)
  #   * anything else (ezagent-like unknown scheme) → :unknown_scheme_construction
  #
  # Adding a real ezagent scheme requires registering it in BOTH
  # `Ezagent.URI.SchemeRegistry` AND `@affected_schemes`; adding an external URL
  # requires an explicit `@external_url_allowlist` edit — no silent bypass.
  defp raw_uri_line_findings(path, line_no, text) do
    ~r/([a-z][a-z0-9+.-]*):\/\//
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&scheme_finding(&1, path, line_no, text))
  end

  defp scheme_finding(scheme, path, line_no, text) do
    cond do
      scheme in @per_tenant_schemes ->
        [
          violation(
            :raw_uri_construction,
            path,
            line_no,
            "raw #{scheme}:// string construction must move behind Ezagent.URI typed builders or test sigil",
            text
          )
        ]

      scheme in @affected_schemes ->
        [
          violation(
            :raw_cross_cutting_uri_construction,
            path,
            line_no,
            "raw #{scheme}:// string construction must move behind Ezagent.URI typed builders or test sigil",
            text
          )
        ]

      scheme in @external_url_allowlist ->
        []

      true ->
        [
          violation(
            :unknown_scheme_construction,
            path,
            line_no,
            "unknown scheme #{scheme}:// — an ezagent URI must use one of the six registered " <>
              "schemes (entity/session/template/resource/workspace/system) via Ezagent.URI; a " <>
              "genuine external URL must be registered in the uri_query scan external-URL " <>
              "allowlist (currently postgresql/unix/http/https/ws/test/cc-bridge).",
            text
          )
        ]
    end
  end

  defp uri_string_key_findings(source, path, doc_lines) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line_no} ->
      trimmed = String.trim(text)

      cond do
        MapSet.member?(doc_lines, line_no) ->
          []

        String.starts_with?(trimmed, "#") ->
          []

        not String.contains?(trimmed, "URI.to_string") ->
          []

        uri_string_key_context?(trimmed) ->
          [
            violation(
              :uri_string_key,
              path,
              line_no,
              "URI.to_string map/cap/routing/receiver keys must be audited before URI reorder",
              trimmed
            )
          ]

        true ->
          []
      end
    end)
  end

  defp doc_line_numbers(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({MapSet.new(), :outside_doc}, fn {text, line_no}, {lines, state} ->
      trimmed = String.trim_leading(text)

      cond do
        state == :inside_doc ->
          lines = MapSet.put(lines, line_no)

          if String.contains?(trimmed, ~s(""")) do
            {lines, :outside_doc}
          else
            {lines, :inside_doc}
          end

        doc_attribute_line?(trimmed) ->
          lines = MapSet.put(lines, line_no)

          if heredoc_opens_on_line?(trimmed) do
            {lines, :inside_doc}
          else
            {lines, :outside_doc}
          end

        true ->
          {lines, :outside_doc}
      end
    end)
    |> elem(0)
  end

  defp doc_attribute_line?(trimmed) do
    Enum.any?(["@moduledoc", "@doc", "@typedoc", "@shortdoc"], &String.starts_with?(trimmed, &1))
  end

  defp heredoc_opens_on_line?(line) do
    heredoc_delimiter_count(line) == 1
  end

  defp heredoc_delimiter_count(line) do
    line
    |> String.split(~s("""))
    |> length()
    |> Kernel.-(1)
  end

  defp uri_string_key_context?(line) do
    Enum.any?(
      [
        "Map.",
        "MapSet.",
        "%{",
        "=>",
        "_key",
        "key:",
        "receiver",
        "routing",
        "cap"
      ],
      &String.contains?(line, &1)
    )
  end

  defp string_split_on?([_value, delimiter | _rest], expected),
    do: literal_string?(delimiter, expected)

  defp string_split_on?(_args, _expected), do: false

  defp split_parts?([_value, _delimiter, opts | _rest], expected) when is_list(opts),
    do: Keyword.get(opts, :parts) == expected

  defp split_parts?(_args, _expected), do: false

  defp literal_string?(literal, expected) when is_binary(literal), do: literal == expected
  defp literal_string?(_literal, _expected), do: false

  defp violation(category, path, line, rule, snippet) do
    %Violation{
      category: category,
      path: normalize_path(path),
      line: line,
      rule: rule,
      snippet: snippet || ""
    }
  end

  defp line(meta), do: Keyword.get(meta, :line, 1)

  defp snippet(snippets, meta) do
    snippets
    |> Map.get(line(meta), "")
    |> String.trim()
  end

  defp line_snippets(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Map.new(fn {text, line_no} -> {line_no, text} end)
  end

  defp normalize_path(path), do: Path.relative_to(path, repo_root!())

  defp repo_root! do
    File.cwd!()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(fn path ->
      File.exists?(Path.join(path, "apps/ezagent_core")) and
        File.exists?(Path.join(path, "mix.exs"))
    end) ||
      raise "could not locate ezagent umbrella root from #{File.cwd!()}"
  end

  defp format_parse_error(error, token) do
    " #{inspect(error)} #{inspect(token)}"
  end
end
