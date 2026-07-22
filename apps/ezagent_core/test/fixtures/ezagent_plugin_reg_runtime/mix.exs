defmodule EzagentPluginRegRuntime.MixProject do
  @moduledoc """
  Check-7 NEGATIVE fixture (#1476). A plugin app whose RUNTIME `lib`
  code calls `Ezagent.PluginRegistry.register/1` directly — the exact
  "declare, don't call" violation the grep gate exists to catch
  (SPEC §3.2). `Mix.Tasks.Compile.EzagentPluginCheckTest` asserts the
  gate STILL flags this after the mix-task exemption, proving the
  exemption did not blanket-disable check 7.

  Reuses the already-compiled `EzagentPluginConforming` module as its
  `:ezagent_plugin` contract, so every check EXCEPT check 7 passes and
  the single diagnostic is unambiguously check 7's.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_reg_runtime,
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
