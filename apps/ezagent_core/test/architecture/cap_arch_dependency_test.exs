defmodule Ezagent.Architecture.CapArchDependencyTest do
  @moduledoc """
  Dependency skeleton for the Phase 3 crypto seam.

  `Ezagent.Cap` must remain core-owned and must not reach upward into any
  `ezagent_domain_*` application. S2 extends this gate when the complete
  authorization algorithm moves beside the seam.
  """
  use ExUnit.Case, async: true

  test "Ezagent.Cap has no domain module or umbrella-app dependency" do
    root = repo_root()
    core_mix = File.read!(Path.join(root, "apps/ezagent_core/mix.exs"))

    references =
      [
        "apps/ezagent_core/lib/ezagent/cap.ex",
        "apps/ezagent_core/lib/ezagent/cap/authority_loader.ex",
        "apps/ezagent_core/lib/ezagent/capability_registry.ex"
      ]
      |> Enum.flat_map(&module_references(Path.join(root, &1)))

    assert Enum.filter(references, &domain_module?/1) == []
    refute core_mix =~ ~r/\{:ezagent_domain_[a-z_]+,\s*in_umbrella:/
  end

  defp module_references(file) do
    {:ok, ast} = Code.string_to_quoted(File.read!(file))

    {_ast, references} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _, parts} = node, acc -> {node, [Module.concat(parts) | acc]}
        node, acc -> {node, acc}
      end)

    references
  end

  defp domain_module?(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, "Elixir.EzagentDomain") or name == "Elixir.Ezagent.Identity"
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
