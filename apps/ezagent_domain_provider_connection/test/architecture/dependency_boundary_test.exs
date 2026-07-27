defmodule Ezagent.ProviderConnection.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "depends on exactly actor, core and identity umbrella applications" do
    deps = EzagentDomainProviderConnection.MixProject.project()[:deps]
    umbrella = for {name, opts} <- deps, is_list(opts) and opts[:in_umbrella], do: name
    # `:ezagent_actor` is the runtime framework (Ezagent.Kind/Registry), extracted
    # from core in #1579 — a legitimate foundation dep alongside :ezagent_core.
    assert umbrella == [:ezagent_actor, :ezagent_core, :ezagent_domain_identity]
    assert {:jason, "~> 1.2"} in deps
  end
end
