defmodule EzagentPluginConforming.MixProject do
  @moduledoc """
  A CONFORMING `ezagent_plugin_*` Mix project — the positive control
  for `Mix.Tasks.Compile.EzagentPluginCheckTest` (codex PR-5 HIGH-3).

  Same shape as `ezagent_plugin_broken` BUT it declares the
  `env: [ezagent_plugin: EzagentPluginConforming]` key and that
  module `use`s `Ezagent.Plugin` correctly. The test compiles this in
  a subprocess and asserts a ZERO exit — proving it is the MISSING
  key (not merely "being a fixture") that fails the broken project.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_conforming,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # The contract module — present, unlike ezagent_plugin_broken.
      env: [ezagent_plugin: EzagentPluginConforming]
    ]
  end

  defp deps do
    [{:ezagent_core, path: "../../../../ezagent_core"}]
  end
end
