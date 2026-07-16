defmodule EzagentDomainGit.Architecture.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  @approved_umbrella_dependencies [:ezagent_core]
  @forbidden_dependency_fragments [
    "ezagent_plugin_",
    "phoenix",
    "ezagent_domain_socialware",
    "ezagent_domain_workspace",
    "workspace_provision",
    "kanban"
  ]

  test "domain app declares exactly its approved inward dependency" do
    source = File.read!(Path.expand("../../mix.exs", __DIR__))

    assert dependency_names(source) == @approved_umbrella_dependencies
    assert umbrella_dependencies(source) == @approved_umbrella_dependencies

    for fragment <- @forbidden_dependency_fragments do
      refute source =~ fragment
    end
  end

  defp dependency_names(source) do
    ~r/\{:([a-z][a-z0-9_]*),\s*(?:in_umbrella:|["'])/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [app] -> String.to_existing_atom(app) end)
    |> Enum.sort()
  end

  defp umbrella_dependencies(source) do
    ~r/\{:(ezagent_[a-z0-9_]+),\s*in_umbrella:\s*true\}/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [app] -> String.to_existing_atom(app) end)
    |> Enum.sort()
  end
end
