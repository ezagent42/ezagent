defmodule EzagentCore.Invariants.DomainKindLookupGateTest do
  @moduledoc """
  V5 pid-closure, A1c chunk4 — the domain-app `KindRegistry.lookup/1`
  enumerator gate (the A2 correctness guarantee).

  `Ezagent.KindRegistry.lookup/1` is the allowlisted pid-acquisition
  WRAPPER. V5 "burn to zero" means no **domain-app** module (anything
  outside `apps/ezagent_actor`) may call it: pid consumption routes through
  the sanctioned `Ezagent.Runtime.Resolver` seam faces (`call/3`, `cast/2`,
  `alive?/1`, `whereis/1`, `pid_for/1`, `terminate_child/2`) BY URI, so the
  pid never lives in domain code.

  This test ENUMERATES — AST-resolved (`Code.string_to_quoted/1` + walk,
  per-file alias resolution, same idiom as
  `Ezagent.ActorBoundaryScanner.acquisition_sites_in_source/2`), NOT a
  substring/regex grep — every `Ezagent.KindRegistry.lookup/1` call in
  `apps/*/lib/**` outside the actor app, and asserts the scanned set is
  exactly the tiny, explicitly-justified exempt list below. AST resolution
  is what a substring count cannot do: it tells `KindRegistry.lookup/1`
  (alias-expanded) apart from a shadowing local `lookup/1` or another
  module's `lookup/1`.

  REPORT-FIRST: when a migration chunk leaves sites behind, the failure
  message lists exactly `{path, line}` per remaining call.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActorBoundaryScanner, as: Scanner

  # The ONLY files outside the actor app allowed to call
  # `Ezagent.KindRegistry.lookup/1`, with their exact call counts (a count
  # drift in either direction REDs — the exempt list can only shrink).
  # Each entry is a sanctioned exemption CLASS (per the A1c chunk4 scope):
  @exempt_calls %{
    # `application.ex` boot: the system routing singleton ensure-spawn runs
    # before any domain facade exists; boot code is an excluded class.
    "apps/ezagent_core/lib/ezagent_core/application.ex" => 1,
    # Dev/stress mix task (`mix ezagent.stress`), never shipped runtime code;
    # dev mix tasks are an excluded class.
    "apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex" => 1,
    # Test-support: `Ezagent.LifecycleCase` is an ExUnit case template that
    # lives in lib/ only so sibling apps can `use` it from their own tests;
    # it never runs in production.
    "apps/ezagent_core/lib/ezagent/lifecycle_case.ex" => 2
  }

  test "no domain-app module calls Ezagent.KindRegistry.lookup/1 (AST-resolved)" do
    found =
      domain_lookup_sites()
      |> Enum.group_by(& &1.path)
      |> Map.new(fn {path, sites} -> {path, length(sites)} end)

    unexpected = Map.drop(found, Map.keys(@exempt_calls))
    drifted = Map.filter(@exempt_calls, fn {path, n} -> Map.get(found, path) != n end)

    assert unexpected == %{} and drifted == %{},
           """
           domain-app KindRegistry.lookup/1 gate tripped.

           NEW sites (must migrate onto a Runtime.Resolver seam face):
           #{inspect(unexpected, pretty: true)}

           EXEMPT sites whose count drifted (shrink the exempt list, or justify the new call):
           #{inspect(drifted, pretty: true)}

           all scanned sites:
           #{inspect(domain_lookup_sites(), pretty: true)}
           """
  end

  test "has-teeth: aliased + fully-qualified calls are detected; shadowing locals are not" do
    source = """
    defmodule SynthDomainLookup do
      alias Ezagent.KindRegistry
      alias Ezagent.KindRegistry, as: KR

      def a(uri), do: KindRegistry.lookup(uri)
      def b(uri), do: KR.lookup(uri)
      def c(uri), do: Ezagent.KindRegistry.lookup(uri)
      # a shadowing LOCAL `lookup/1` — never the registry wrapper.
      def lookup(uri), do: {:local, uri}
      def d(uri), do: lookup(uri)
      # another module's lookup/1 — not the banned wrapper.
      def e(uri), do: Ezagent.AgentLineage.lookup(uri)
    end
    """

    lines = lookup_sites_in_source(source)

    assert length(lines) == 3,
           "expected exactly the 3 alias-resolved KindRegistry.lookup/1 calls, got #{inspect(lines)}"
  end

  # ── AST-resolved enumerator (scanner idiom, self-contained) ────────────────

  # Every `Ezagent.KindRegistry.lookup/1` call site in `apps/*/lib/**`
  # EXCLUDING `apps/ezagent_actor/**` (the seam/actor internals may use the
  # wrapper freely). Each hit: `%{path, line}`.
  defp domain_lookup_sites do
    root = Scanner.repo_root()
    actor_prefix = Path.join(root, "apps/ezagent_actor") <> "/"

    root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, actor_prefix))
    |> Enum.flat_map(fn abs ->
      rel = Path.relative_to(abs, root)

      abs
      |> File.read!()
      |> lookup_sites_in_source()
      |> Enum.map(&%{path: rel, line: &1})
    end)
    |> Enum.sort_by(&{&1.path, &1.line})
  end

  # Source-line numbers of every alias-resolved `Ezagent.KindRegistry.lookup/1`
  # call in `source`. Returns [] on unparseable source (same fail-open idiom
  # as the boundary scanner — a syntax-broken file REDS the compile gate long
  # before this scan matters).
  defp lookup_sites_in_source(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)

        {_, hits} =
          Macro.prewalk(ast, [], fn
            {{:., _, [modast, :lookup]}, meta, args} = node, acc when is_list(args) ->
              if length(args) == 1 and resolve_ast(modast, aliases) == Ezagent.KindRegistry do
                {node, [Keyword.get(meta, :line, 0) | acc]}
              else
                {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        hits

      {:error, _} ->
        []
    end
  end

  # ── alias resolution (same idiom as ActorBoundaryScanner) ─────────────────

  defp resolve_ast({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: resolve(parts, aliases), else: nil
  end

  defp resolve_ast(mod, _aliases) when is_atom(mod), do: mod
  defp resolve_ast(_other, _aliases), do: nil

  defp resolve([first | rest], aliases) do
    parts =
      case Map.get(aliases, first) do
        nil -> [first | rest]
        full -> full ++ rest
      end

    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, kids}]} = node, acc
        when is_list(kids) ->
          acc =
            Enum.reduce(kids, acc, fn
              {:__aliases__, _, [last]}, a -> Map.put(a, last, prefix ++ [last])
              _, a -> a
            end)

          {node, acc}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} -> {node, Map.put(acc, as_name, parts)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
