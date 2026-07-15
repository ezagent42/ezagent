defmodule EzagentPluginEmConforming.MixProject do
  @moduledoc """
  A CONFORMING `ezagent_plugin_*` Mix project that declares a valid
  ExternalMirror `adapters/0` pair — positive control for
  `Mix.Tasks.Compile.EzagentPluginCheckTest` (ExternalMirror PR-EM-1).

  The plugin module declares ONE `{adapter, binding}` pair where:
  - both implement their respective behaviour
  - `adapter.binding_module() == binding`
  - `binding.adapter_module() == adapter`
  - adapter ≠ binding

  The `:ezagent_plugin_check` gate must accept this.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_em_conforming,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginEmConforming]
    ]
  end

  defp deps do
    [
      {:ezagent_core, path: "../../../../ezagent_core"},
      {:ezagent_domain_external_mirror, path: "../../../../ezagent_domain_external_mirror"}
    ]
  end
end
