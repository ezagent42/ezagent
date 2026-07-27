defmodule EzagentDomainGit.Architecture.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  # :ezagent_actor was added by the C4-C7 actor-framework extraction (#1579),
  # which moved Ezagent.URI into that app. Every app using it declares the dep
  # directly rather than reaching it transitively through ezagent_core. That PR
  # updated the mix.exs files but not this approved list, leaving this test red
  # on main. The dep is inward and framework-tier, so it belongs here.
  @approved_umbrella_dependencies [:ezagent_actor, :ezagent_core]
  @forbidden_dependency_fragments [
    "ezagent_plugin_",
    "ezagent_domain_socialware",
    "ezagent_domain_workspace",
    "workspace_provision",
    "kanban"
  ]

  test "domain app declares exactly its approved inward dependency" do
    dependencies = Mix.Project.config()[:deps]

    assert dependency_names(dependencies) == @approved_umbrella_dependencies
    assert umbrella_violations(dependencies) == []

    for dependency <- dependency_names(dependencies),
        fragment <- @forbidden_dependency_fragments do
      refute Atom.to_string(dependency) =~ fragment
    end
  end

  test "path-form ezagent dependencies are included and rejected without in_umbrella" do
    dependencies = [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, path: "../ezagent_domain_identity"}
    ]

    assert dependency_names(dependencies) == [:ezagent_core, :ezagent_domain_identity]
    assert umbrella_violations(dependencies) == [:ezagent_domain_identity]
  end

  defp dependency_names(dependencies) do
    dependencies
    |> Enum.map(&dependency_name/1)
    |> Enum.sort()
  end

  defp umbrella_violations(dependencies) do
    dependencies
    |> Enum.filter(fn dependency ->
      dependency
      |> dependency_name()
      |> Atom.to_string()
      |> String.starts_with?("ezagent_")
    end)
    |> Enum.reject(&Keyword.get(dependency_options(&1), :in_umbrella, false))
    |> Enum.map(&dependency_name/1)
    |> Enum.sort()
  end

  defp dependency_name({name, options}) when is_atom(name) and is_list(options), do: name

  defp dependency_name({name, requirement}) when is_atom(name) and is_binary(requirement),
    do: name

  defp dependency_name({name, requirement, options})
       when is_atom(name) and is_binary(requirement) and is_list(options),
       do: name

  defp dependency_options({_name, options}) when is_list(options), do: options
  defp dependency_options({_name, requirement}) when is_binary(requirement), do: []

  defp dependency_options({_name, requirement, options})
       when is_binary(requirement) and is_list(options),
       do: options
end
