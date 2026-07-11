Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.DirRelativeRuntimeAssetTest do
  @moduledoc """
  Structural guard against the "passes on the dev Mac, breaks in the clean
  deploy container" bug that caused the week-long orchestrator outage (#1325).

  ## The bug class

  `McpConfigWriter.bridge_script_path/0` resolved the esr-bridge MCP sidecar
  via a compile-time `Path.expand("../../../python/…", __DIR__)`. `__DIR__`
  bakes the *build-tree* source path at compile time. That path exists in a
  dev checkout, but `mix release` packages only each app's `priv/` dir — so
  the script was ABSENT on every deployed node, the MCP server never launched,
  no cc agent ever bound, and the orchestrator `:call` timed out. Tests +
  type-check were green throughout, because the dev machine HAD the source
  path (P6 — "the most expensive bugs pass tests and only surface in prod").

  ## The rule (target-zero)

  Runtime `lib/` code must resolve a runtime asset from the app's installed
  `priv/` via `:code.priv_dir/1` or `Application.app_dir/2` — never a bare
  compile-time `__DIR__`-relative path. A `__DIR__` is allowed ONLY as a
  fallback *inside the same function clause* as a `:code.priv_dir` /
  `Application.app_dir` primary (the sanctioned escript/umbrella-test
  fallback, e.g. `Domain.Python.Server.python_lib_dir/0`).

  Scope: `apps/*/lib/**/*.ex`, EXCLUDING `lib/mix/tasks/**` — mix tasks are a
  dev-loop tool that never ship in a release, and legitimately use `__DIR__`
  to anchor the source repo root (e.g. `check_invariants`'s `@repo_root`).

  Suppression: `# arch-allow:` on the offending line.

  This gate structurally kills the compile-time RESOLUTION half of #1325. The
  PACKAGING half (the file must actually ship in `priv/`) and the runtime-boot
  half are covered separately by the deploy repo's dynamic boot/packaging smoke,
  which runs against the real Docker image (ezagent-deploy, B2) — packaging is a
  fact about the built artifact, not a source pattern. The two are complementary.
  """
  use ExUnit.Case, async: true

  # This file lives at apps/ezagent_core/test/architecture/ — the umbrella
  # `apps/` dir is three levels up.
  @apps_root Path.expand("../../..", __DIR__)

  # --- the whole-repo gate ------------------------------------------------

  test "no lib/ code resolves a runtime asset via a bare compile-time __DIR__" do
    offenders =
      lib_ex_files()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> offenders_in_source()
        |> Enum.map(&{Path.relative_to(file, @apps_root), &1})
      end)

    assert offenders == [],
           """
           Bare compile-time `__DIR__`-relative runtime-asset resolution found
           in lib/ code (the #1325 dev-Mac-vs-container bug class):

           #{Enum.map_join(offenders, "\n", fn {rel, line} -> "  #{rel}:#{line}" end)}

           Resolve the asset from the app's installed priv/ instead:
               Application.app_dir(:my_app, "priv/…")   # or :code.priv_dir/1
           A `__DIR__` fallback is allowed only inside the SAME function clause
           as a :code.priv_dir / Application.app_dir primary. If this site is
           genuinely not a shipped runtime asset, append `# arch-allow: <reason>`.
           """
  end

  # --- source-fixture contract (POSITIVE / NEGATIVE) ----------------------

  describe "offenders_in_source/1" do
    test "POSITIVE: the exact #1325 pre-fix resolver is flagged" do
      # verbatim shape of McpConfigWriter.bridge_script_path/0 at e17e079d0^
      source = """
      defmodule EzagentPluginCc.McpConfigWriter do
        @spec bridge_script_path() :: String.t()
        def bridge_script_path do
          Path.expand("../../../python/ezagent_mcp_bridge.py", __DIR__)
        end
      end
      """

      assert offenders_in_source(source) == [4]
    end

    test "POSITIVE: a module-attribute runtime path via __DIR__ is flagged" do
      source = """
      defmodule Demo do
        @script Path.expand("../python/worker.py", __DIR__)
        def script, do: @script
      end
      """

      assert offenders_in_source(source) == [2]
    end

    test "NEGATIVE: __DIR__ fallback behind a :code.priv_dir primary in the same clause" do
      # shape of Domain.Python.Server.python_lib_dir/0
      source = """
      defmodule Demo do
        def python_lib_dir do
          case :code.priv_dir(:my_app) do
            {:error, _} -> Path.expand("../../priv/python", __DIR__)
            path when is_list(path) -> Path.join(List.to_string(path), "python")
          end
        end
      end
      """

      assert offenders_in_source(source) == []
    end

    test "NEGATIVE: Application.app_dir primary in the same clause" do
      source = """
      defmodule Demo do
        def path do
          Application.app_dir(:my_app, "priv/x") || Path.expand("priv/x", __DIR__)
        end
      end
      """

      assert offenders_in_source(source) == []
    end

    test "NEGATIVE: a `# arch-allow:` line is suppressed" do
      source = """
      defmodule Demo do
        def root, do: Path.expand("..", __DIR__) # arch-allow: repo-root anchor, not an asset
      end
      """

      assert offenders_in_source(source) == []
    end

    test "NEGATIVE: __DIR__ mentioned only in a doc string is not code" do
      source = ~S'''
      defmodule Demo do
        @doc "Resolved at runtime, NOT via a compile-time __DIR__ path."
        def path, do: Application.app_dir(:my_app, "priv/x")
      end
      '''

      assert offenders_in_source(source) == []
    end
  end

  # --- pure scanner -------------------------------------------------------

  @doc """
  Returns the sorted list of line numbers where `source` uses a compile-time
  `__DIR__` that is NOT (a) inside a def/defp clause holding a
  `:code.priv_dir`/`Application.app_dir` primary, nor (b) `# arch-allow:`ed.

  Works on the AST, so `__DIR__` appearing inside a doc/string literal is
  never a match (it is binary text, not a `{:__DIR__, _, _}` node).
  """
  def offenders_in_source(source) when is_binary(source) do
    allowed = arch_allow_lines(source)

    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        covered = covered_dir_lines(ast)

        ast
        |> dir_lines()
        |> Enum.reject(&(&1 in covered or &1 in allowed))
        |> Enum.sort()
        |> Enum.uniq()

      {:error, _} ->
        # Unparseable source is out of scope for this static gate; the compiler
        # gate (warnings-as-errors) is what fails on a genuine syntax error.
        []
    end
  end

  # Lines of every `{:__DIR__, meta, _}` node in the AST.
  defp dir_lines(ast), do: collect_lines(ast, &match?({:__DIR__, _, _}, &1))

  # Lines of `__DIR__` nodes that sit inside a def/defp clause which ALSO
  # contains a :code.priv_dir / Application.app_dir primary.
  defp covered_dir_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {kw, _meta, [_head | _] = args} = node, acc when kw in [:def, :defp] ->
          if has_primary?(node) do
            {node, collect_lines(args, &match?({:__DIR__, _, _}, &1)) ++ acc}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines
  end

  # A `:code.priv_dir(...)` or `Application.app_dir(...)` call anywhere in the tree.
  defp has_primary?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [:code, :priv_dir]}, _, _} = n, _ -> {n, true}
        {{:., _, [{:__aliases__, _, [:Application]}, :app_dir]}, _, _} = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    found?
  end

  defp collect_lines(ast, pred) do
    {_, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        if pred.(node), do: {node, [line_of(node) | acc]}, else: {node, acc}
      end)

    lines
  end

  defp line_of({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line_of(_), do: 0

  defp arch_allow_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, "# arch-allow:") end)
    |> Enum.map(fn {_, no} -> no end)
  end

  defp lib_ex_files do
    @apps_root
    |> Path.join("*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/lib/mix/tasks/"))
  end
end
