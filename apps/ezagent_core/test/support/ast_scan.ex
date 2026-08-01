defmodule EzagentCore.AstScan do
  @moduledoc """
  Shared AST machinery for the read-plane chokepoint arch gates
  (`MessageReadChokepointBoundaryTest`, `ListReadChokepointBoundaryTest`).

  Extracted so the gates share ONE implementation of the parts that must
  not drift (a security gate is never copy-pasted):

    * `expand_pipes/1` — rewrite `left |> call(args…)` into
      `call(left, args…)` so matchers see the fully-applied call.
    * `collect_aliases/1` — resolve `alias Foo.Bar` / `alias Foo.Bar, as: B`.
    * `collect_imports/1` — resolve `import Foo.Bar` (the bare-call
      evasion vector).
    * `resolve/3` — alias resolution + a leading `:Elixir` segment
      normalized away (the root-qualified `Elixir.Mod.fun` evasion),
      then a gate-supplied `normalize` hook for bare-name defaults.
    * `line_of/1` — source line from call metadata.

  Test-only module (compiled under `test/support`).
  """

  @doc """
  Rewrite `left |> call(args…)` into `call(left, args…)` throughout the
  AST, so offense matchers see the fully-applied call. `Macro.prewalk`
  re-descends into the rewritten node, so nested pipes expand too.
  """
  def expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, {call, meta, args}]} when is_list(args) -> {call, meta, [left | args]}
      other -> other
    end)
  end

  @doc """
  `alias Foo.Bar` → `%{Bar: [:Foo, :Bar]}`;
  `alias Foo.Bar, as: B` → `%{B: [:Foo, :Bar]}`;
  `alias Foo.{Bar, Baz}` → both segments mapped.
  """
  def collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} ->
              {node, Map.put(acc, as_name, parts)}

            _ ->
              # `alias Foo.{Bar, Baz}` — the multi-alias form lands here
              # with a `{{:., _, ...}, _, ...}` first arg handled below.
              {node, acc}
          end

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, segments}]} = node, acc ->
          acc =
            Enum.reduce(segments, acc, fn
              {:__aliases__, _, [seg]}, a -> Map.put(a, seg, base ++ [seg])
              _, a -> a
            end)

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  @doc """
  `import Foo.Bar` → `[[:Foo, :Bar]]` (a list of imported module parts).
  `import Foo.Bar, only: [...]` / `except:` resolve to the same module.
  """
  def collect_imports(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:import, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [parts | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  @doc """
  Resolve a module-reference AST's parts via the file's aliases, then
  normalize: a leading `:Elixir` segment is dropped (the root-qualified
  `Elixir.Ezagent.Mod.fun` evasion form) and the result is passed
  through the gate's `normalize` hook (bare-name defaults).
  """
  def resolve(parts, aliases, normalize \\ &Function.identity/1) do
    resolved =
      case Map.get(aliases, List.first(parts)) do
        nil -> parts
        full -> full ++ tl(parts)
      end

    resolved
    |> drop_elixir_prefix()
    |> normalize.()
  end

  @doc "Does a module-reference AST resolve (via `aliases`) to `target`?"
  def resolves_to?({:__aliases__, _, parts}, target, aliases, normalize) do
    resolve(parts, aliases, normalize) == target
  end

  def resolves_to?(_other, _target, _aliases, _normalize), do: false

  @doc "The source line recorded in call metadata (0 when absent)."
  def line_of(meta), do: Keyword.get(meta, :line, 0)

  @doc """
  True for a path that belongs to an ExUnit `@tag :tmp_dir` fixture rather than
  to the source tree.

  ExUnit roots `:tmp_dir` at `<cwd>/tmp/<Module>/<test name>`, which inside this
  umbrella lands under `apps/<app>/tmp/`. Several architecture gates glob
  `apps/**/*.ex`, so those fixtures are enumerated as if they were production
  source. `apps/ezagent_core/.gitignore` already excludes the directory — the
  scanners are reading files version control does not track.

  Two things go wrong when they do, and the second is the reason this is not
  merely a tidiness fix:

    * **Crash.** The fixture is created and removed by a concurrently running
      test, so the window between `Path.wildcard/1` and `File.read!/1` is enough
      for `File.Error`. That is the intermittent red these gates have been
      showing.
    * **False positive.** `GitAdapterBoundaryTest` PLANTS deliberate bypass
      samples in its fixtures — that is what it is testing. Win the race instead
      of losing it and a gate reports a violation that exists only inside
      another test's scratch directory.
  """
  def tmp_fixture?(path) when is_binary(path),
    do: Regex.match?(~r{(?:^|/)apps/[^/]+/tmp(?:/|$)}, path)

  defp drop_elixir_prefix([:"Elixir" | rest]) when rest != [], do: rest
  defp drop_elixir_prefix(parts), do: parts
end
