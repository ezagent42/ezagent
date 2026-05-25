defmodule EzagentPluginEmMismatch.MixProject do
  @moduledoc """
  A NON-CONFORMING `ezagent_plugin_*` Mix project where
  `adapter.binding_module()` returns a DIFFERENT module than the one
  declared in `adapters/0`. Grill-5 rule (c) — bidirectional
  declaration — must REJECT this.

  Test fixture for `Mix.Tasks.Compile.EzagentPluginCheckTest`
  (ExternalMirror PR-EM-1 acceptance test (ii)).
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_em_mismatch,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginEmMismatch]
    ]
  end

  defp deps do
    [
      {:ezagent_core, path: "../../../../ezagent_core"},
      {:ezagent_domain_external_mirror, path: "../../../../ezagent_domain_external_mirror"}
    ]
  end
end
