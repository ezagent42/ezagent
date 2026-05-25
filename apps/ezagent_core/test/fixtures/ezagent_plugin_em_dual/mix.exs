defmodule EzagentPluginEmDual.MixProject do
  @moduledoc """
  A NON-CONFORMING `ezagent_plugin_*` Mix project where a SINGLE
  module implements BOTH `Ezagent.ExternalMirror.Adapter` AND
  `Ezagent.ExternalMirror.Binding` behaviours. Grill-5 (e) — the
  `adapter != binding` check — must REJECT this.

  Test fixture for `Mix.Tasks.Compile.EzagentPluginCheckTest`
  (ExternalMirror PR-EM-1 acceptance test (i)).
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_em_dual,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginEmDual]
    ]
  end

  defp deps do
    [
      {:ezagent_core, path: "../../../../ezagent_core"},
      {:ezagent_domain_external_mirror, path: "../../../../ezagent_domain_external_mirror"}
    ]
  end
end
