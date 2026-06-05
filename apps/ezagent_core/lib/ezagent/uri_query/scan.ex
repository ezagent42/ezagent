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
  @agent_flavor_prefixes ~w(cc_ codex_ curl_ echo_ np_)
  @known_categories [
    :flavor_prefix_dependency,
    :orchestrator_derivation,
    :parse_error,
    :positional_uri_read,
    :raw_cross_cutting_uri_construction,
    :raw_uri_construction,
    :tenant_derivation,
    :uri_string_key
  ]

  @default_globs [
    "apps/**/*.ex"
  ]

  @default_excluded_paths [
    "apps/ezagent_core/lib/ezagent/uri.ex",
    "apps/ezagent_core/lib/ezagent/uri_query/scan.ex",
    "apps/ezagent_core/lib/mix/tasks/ezagent.uri_query.scan.ex"
  ]

  @doc "Scan all production `.ex` files under `apps/`."
  @spec scan(keyword()) :: [Violation.t()]
  def scan(opts \\ []) do
    opts
    |> source_paths()
    |> scan_paths(opts)
  end

  @doc "Scan the given paths and return sorted findings."
  @spec scan_paths([Path.t()], keyword()) :: [Violation.t()]
  def scan_paths(paths, opts \\ []) when is_list(paths) do
    excluded = MapSet.new(Keyword.get(opts, :exclude, @default_excluded_paths))

    paths
    |> Enum.reject(&MapSet.member?(excluded, normalize_path(&1)))
    |> Enum.flat_map(&scan_path/1)
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
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan_path(path) do
    source = File.read!(path)
    line_snippets = line_snippets(source)

    ast_violations =
      case Code.string_to_quoted(source, columns: true, token_metadata: true) do
        {:ok, ast} ->
          ast_findings(ast, path, line_snippets)

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

    if :host in keys or :path in keys do
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
    if string_split_on?(args, "/") do
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

  defp raw_uri_line_findings(path, line_no, text) do
    schemes =
      @affected_schemes
      |> Enum.filter(&String.contains?(text, &1 <> "://"))

    Enum.map(schemes, fn scheme ->
      category =
        if scheme in @per_tenant_schemes do
          :raw_uri_construction
        else
          :raw_cross_cutting_uri_construction
        end

      violation(
        category,
        path,
        line_no,
        "raw #{scheme}:// string construction must move behind Ezagent.URI typed builders or test sigil",
        text
      )
    end)
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
