defmodule EzagentPluginRegMixtask.MixProject do
  @moduledoc """
  Check-7 POSITIVE (exemption) fixture (#1476). A plugin app that calls
  `Ezagent.PluginRegistry.register/1` ONLY from a build-time Mix task at
  `lib/mix/tasks/reg_seed.ex`. A Mix task is dev/build tooling invoked
  via `mix <task>`, never loaded into the running app's boot path, so
  seeding a registry there is legitimate and EXEMPT from check 7 (the
  same shape as `mix world.e2e.fixtures` — the #1476 crash-fix).
  `Mix.Tasks.Compile.EzagentPluginCheckTest` asserts the gate PASSES.

  Reuses the already-compiled `EzagentPluginConforming` contract module,
  so with the sole `*Registry.register` call exempted the gate is clean.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_reg_mixtask,
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
