defmodule Ezagent.DispatchOrigin.Gate do
  @moduledoc """
  Build-time source inventory for dispatch provenance.

  The gate parses every product Elixir source containing a dispatch envelope or
  dispatch call. Envelope defaults are deliberately unstamped; every product
  constructor must explicitly choose one of the two positive values. The sole
  product exception is the Feishu HTTP webhook path, which deliberately passes
  `nil` into the shared dispatcher and is rejected until transport
  authentication is implemented.
  """

  @positive [:authenticated_external, :trusted_internal]

  # Files whose envelope constructors take the origin from a RUNTIME value
  # (transport-derived, or caller-owned) rather than a literal: the Feishu
  # inbound dispatcher, the Router (re-stamps the Cmd's origin onto the
  # Invocation), and — V5 A1b (codex blocker A) — the resolver seam, whose
  # `dispatch/4` PRESERVES the caller-owned `ctx.origin` and rejects a
  # missing/invalid one instead of stamping `:trusted_internal` itself.
  @dynamic_origin_sites [
    "inbound_dispatcher.ex",
    "ezagent/router.ex",
    "ezagent/runtime/resolver.ex"
  ]

  @type finding :: {String.t(), pos_integer(), term()}

  # The dispatch/raw-call SOURCES the inventory tracks (V5 A1b codex
  # NOT-CLOSED — AST-resolved, no longer substring-matched): `{module, fun}`
  # pairs a call-site must RESOLVE to (through the file's own aliases) before
  # it counts. The resolver seam is a dispatch source too — `dispatch/4` (the
  # provenance-carrying KIND path) and raw `call/3` (the sidecar-messaging
  # path) sit alongside `Router.dispatch/1` and `Invocation.dispatch/1`.
  @dispatch_sources MapSet.new([
                      {Ezagent.Router, :dispatch},
                      {Ezagent.Invocation, :dispatch},
                      {Ezagent.Runtime.Resolver, :dispatch},
                      {Ezagent.Runtime.Resolver, :call}
                    ])

  # The envelope modules whose `%Struct{}` construction counts as a
  # constructor site (AST-resolved like the dispatch sources).
  @envelope_modules MapSet.new([Ezagent.Cmd, Ezagent.Invocation])

  @doc false
  @spec check_source(String.t(), String.t()) :: [finding()]
  def check_source(source, path \\ "fixture.ex") when is_binary(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        {_ast, findings} = Macro.prewalk(ast, [], &inspect_node(&1, &2, path))
        Enum.reverse(findings)

      {:error, error} ->
        [{path, 1, {:parse_error, error}}]
    end
  end

  @doc false
  @spec inventory([String.t()]) :: %{
          dispatches: non_neg_integer(),
          constructors: non_neg_integer()
        }
  def inventory(paths) do
    Enum.reduce(paths, %{dispatches: 0, constructors: 0}, fn path, counts ->
      case Code.string_to_quoted(File.read!(path)) do
        {:ok, ast} ->
          # AST-RESOLVED (V5 A1b codex NOT-CLOSED): dispatch sources and
          # envelope constructors are counted as real call/struct nodes whose
          # module resolves — through the FILE'S OWN aliases — to a tracked
          # module. The old substring count self-counted this gate's own
          # literal needles, missed alias forms, and double-counted
          # `%Ezagent.Cmd{` (it contains the `%Cmd{` substring); a bare
          # unaliased `Resolver.call` now resolves to `Elixir.Resolver` and
          # correctly does NOT count.
          aliases = collect_aliases(ast)
          {_ast, counts} = Macro.prewalk(ast, counts, &count_node(&1, &2, aliases))
          counts

        {:error, _error} ->
          counts
      end
    end)
  end

  defp inspect_node({:%, meta, [module_ast, {:%{}, _, fields}]} = node, findings, path) do
    if envelope_constructor?(module_ast, fields) do
      case Keyword.fetch(fields, :origin) do
        {:ok, origin} when origin in @positive ->
          {node, findings}

        {:ok, {:origin, _, _} = other} ->
          if Enum.any?(@dynamic_origin_sites, &String.ends_with?(path, &1)) do
            {node, findings}
          else
            {node, [{path, meta[:line] || 1, {:invalid_origin, other}} | findings]}
          end

        {:ok, nil} ->
          {node, [{path, meta[:line] || 1, :unstamped_origin} | findings]}

        {:ok, other} ->
          {node, [{path, meta[:line] || 1, {:invalid_origin, other}} | findings]}

        :error ->
          {node, [{path, meta[:line] || 1, :missing_origin} | findings]}
      end
    else
      {node, findings}
    end
  end

  defp inspect_node(node, findings, _path), do: {node, findings}

  defp envelope_constructor?(module_ast, fields) do
    if Keyword.keyword?(fields) do
      keys = fields |> Keyword.keys() |> MapSet.new()

      case module_name(module_ast) do
        :Cmd -> MapSet.subset?(MapSet.new([:target, :action, :args, :ctx]), keys)
        :Invocation -> MapSet.subset?(MapSet.new([:target, :mode, :args, :ctx]), keys)
        _ -> false
      end
    else
      false
    end
  end

  defp module_name({:__aliases__, _, parts}), do: List.last(parts)
  defp module_name(_module), do: nil

  # A dispatch/raw-call SITE: `Mod.fun(...)` whose module resolves to a
  # tracked source. An unresolvable or unrelated module never counts.
  defp count_node({{:., _, [module_ast, fun]}, _, args} = node, counts, aliases)
       when is_atom(fun) and is_list(args) do
    if MapSet.member?(@dispatch_sources, {resolve_ast(module_ast, aliases), fun}) do
      {node, %{counts | dispatches: counts.dispatches + 1}}
    else
      {node, counts}
    end
  end

  # An envelope CONSTRUCTOR site: `%Mod{...}` resolving to Cmd/Invocation.
  defp count_node({:%, _, [module_ast, {:%{}, _, _}]} = node, counts, aliases) do
    if MapSet.member?(@envelope_modules, resolve_ast(module_ast, aliases)) do
      {node, %{counts | constructors: counts.constructors + 1}}
    else
      {node, counts}
    end
  end

  defp count_node(node, counts, _aliases), do: {node, counts}

  # Module resolution through the file's own aliases (same idiom as
  # `Ezagent.ActorBoundaryScanner`): a fully-qualified `Ezagent.Router`
  # resolves directly, a single-segment `Router` resolves ONLY when the file
  # aliases it, and an alias head also resolves a longer suffix
  # (`alias Ezagent.Runtime` + `Runtime.Resolver.call`).
  defp resolve_ast({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: resolve(parts, aliases), else: nil
  end

  defp resolve_ast(_other, _aliases), do: nil

  defp resolve([first | rest], aliases) do
    parts =
      case Map.get(aliases, first) do
        nil -> [first | rest]
        full -> full ++ rest
      end

    # `Module.concat/1` raises on non-alias segments (e.g. an
    # `alias __MODULE__.Saga` head) — treat those as unresolvable instead.
    if alias_parts?(parts), do: Module.concat(parts), else: nil
  end

  # Valid alias segments only (uppercase-led atoms): `__MODULE__` heads and
  # other non-alias atoms make a module UNRESOLVABLE, never a crash.
  defp alias_parts?(parts) do
    Enum.all?(parts, fn part ->
      is_atom(part) and match?(<<first, _::binary>> when first in ?A..?Z, Atom.to_string(part))
    end)
  end

  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, kids}]} = node, acc
        when is_list(kids) ->
          acc =
            Enum.reduce(kids, acc, fn
              {:__aliases__, _, [last]}, a ->
                parts = prefix ++ [last]
                if alias_parts?(parts), do: Map.put(a, last, parts), else: a

              _, a ->
                a
            end)

          {node, acc}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          if alias_parts?(parts),
            do: {node, Map.put(acc, List.last(parts), parts)},
            else: {node, acc}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} ->
              if alias_parts?(parts), do: {node, Map.put(acc, as_name, parts)}, else: {node, acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
