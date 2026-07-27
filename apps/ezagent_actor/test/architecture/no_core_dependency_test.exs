defmodule EzagentActor.Architecture.NoCoreDependencyTest do
  @moduledoc """
  C5 §3.1 — the extraction's compile-time teeth, test half.

  `apps/ezagent_actor` declares NO `in_umbrella` deps, so the framework
  physically cannot reference core/domain modules: it reaches the core
  spine ONLY through the §3.4 config-resolved port adapters
  (`Application.fetch_env!(:ezagent_actor, …)`). This test AST-scans
  `apps/ezagent_actor/lib/**/*.ex` and REDs on any `EzagentCore.*` module
  reference in any position — call, bare atom, remote type, or struct
  pattern. (Moduledoc TEXT mentioning `EzagentCore.Repo`/`EzagentCore.PubSub`
  as the wired VALUES is documentation, not a reference, and is allowed.)

  The wider reverse gate (staying `Ezagent.*` spine modules, with its one
  reasoned LegacyCallbacks carve-out) lives in core as
  `Ezagent.ActorBoundaryScanner` — it cannot be reused here because the
  scanner itself is core code. This scan needs nothing outside the app.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)

  test "apps/ezagent_actor/lib has no EzagentCore.* module references" do
    offenders =
      @lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case Code.string_to_quoted(File.read!(path)) do
          {:ok, ast} ->
            {_ast, hits} =
              Macro.prewalk(ast, [], fn
                {:__aliases__, meta, [:EzagentCore | _] = parts} = node, acc ->
                  {node, [{meta[:line] || 0, Module.concat(parts)} | acc]}

                node, acc ->
                  {node, acc}
              end)

            Enum.map(hits, fn {line, module} ->
              "#{Path.relative_to(path, @lib_dir)}:#{line} #{inspect(module)}"
            end)

          {:error, _} ->
            []
        end
      end)

    assert offenders == [],
           """
           ezagent_actor must not reference EzagentCore.* modules (C5 §3.1 — the
           framework reaches the core spine only via the §3.4 ports):
           #{Enum.join(offenders, "\n")}
           """
  end
end
