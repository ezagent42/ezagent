defmodule EzagentPluginGitWorkflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_git_workflow,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      # plugin-wire-exempt: E2-A is intentionally dormant until the fail-closed E2-B authorization ingress is integrated
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      mod: {EzagentPluginGitWorkflow.Application, []},
      env: [ezagent_plugin: EzagentPluginGitWorkflow.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true}
    ]
  end
end
