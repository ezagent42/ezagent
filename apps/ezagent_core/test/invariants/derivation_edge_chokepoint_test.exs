defmodule Ezagent.Invariants.DerivationEdgeChokepointTest do
  @moduledoc "D-1/MF6 creation-source completeness gate with an empty allowlist."

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @allowlist []

  @route_marker ~r/# derivation-edge: (?:recorded-by|rehydration-only|template-post-obligation|genesis-root|non-principal|test-scenario)\b/

  test "every low-level Kind creation site declares its derivation-edge route" do
    violations =
      @root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&unclassified_creation_sites/1)

    assert @allowlist == []

    assert violations == [],
           """
           derivation-edge creation bypasses (empty allowlist):
           #{Enum.map_join(violations, "\n", &"  - #{&1}")}
           """
  end

  defp unclassified_creation_sites(path) do
    source = File.read!(path)
    lines = String.split(source, "\n")

    source
    |> Code.string_to_quoted!(columns: true)
    |> creation_call_lines()
    |> Enum.reject(&classified?(lines, &1))
    |> Enum.map(&"#{Path.relative_to(path, @root)}:#{&1}")
  end

  defp creation_call_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {{:., _, [module_ast, fun]}, meta, _args} = node, acc
        when fun in [:spawn, :spawn_detailed] ->
          module = Macro.to_string(module_ast)

          if {module, fun} in [
               {"Ezagent.Kind", :spawn},
               {"Kind", :spawn},
               {"Ezagent.SpawnRegistry", :spawn_detailed},
               {"SpawnRegistry", :spawn_detailed}
             ] do
            {node, [Keyword.fetch!(meta, :line) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines |> Enum.uniq() |> Enum.sort()
  end

  defp classified?(lines, line) do
    first = max(line - 4, 1)

    lines
    |> Enum.slice((first - 1)..(line - 1))
    |> Enum.any?(&Regex.match?(@route_marker, &1))
  end

  test "the append-only writer and no-cutoff all-kind closure remain present" do
    source =
      File.read!(Path.join(@root, "apps/ezagent_core/lib/ezagent/provenance/derivation_edges.ex"))

    assert source =~ "def record_derivation_edge"
    assert source =~ "def descendants"
    assert source =~ "edge.parent_uri in ^frontier"
    refute source =~ "max_depth"
    refute source =~ "Repo.delete"
    refute source =~ "Repo.update"
  end
end
