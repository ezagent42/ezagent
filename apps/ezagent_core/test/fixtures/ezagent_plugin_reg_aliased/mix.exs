defmodule EzagentPluginRegAliased.MixProject do
  @moduledoc """
  Check-7 NEGATIVE fixture. A plugin app whose RUNTIME `lib` code
  makes a genuine `*Registry.register` call via the ALIASED short form
  (`alias …AdapterRegistry` then `AdapterRegistry.register(x)`) — the form
  real plugins actually use. This locks the AST detector so it cannot be
  fooled into a false NEGATIVE by the aliased shape: the gate keys on the
  alias's LAST segment, so the short and fully-qualified forms resolve
  identically. `Mix.Tasks.Compile.EzagentPluginCheckTest` asserts the gate
  STILL flags this after the doc-comment hardening.

  Reuses the already-compiled `EzagentPluginConforming` contract module,
  so the single diagnostic is unambiguously check 7's.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_reg_aliased,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginConforming]
    ]
  end

  defp deps do
    [{:ezagent_core, path: "../../../../ezagent_core"}]
  end
end
