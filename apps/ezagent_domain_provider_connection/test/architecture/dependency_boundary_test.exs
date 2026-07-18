defmodule Ezagent.ProviderConnection.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "depends on exactly core and identity umbrella applications" do
    deps = EzagentDomainProviderConnection.MixProject.project()[:deps]
    umbrella = for {name, opts} <- deps, opts[:in_umbrella], do: name
    assert umbrella == [:ezagent_core, :ezagent_domain_identity]
  end
end
