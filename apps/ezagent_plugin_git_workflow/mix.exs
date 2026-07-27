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
      # Ezagent.URI moved into ezagent_actor by the C4-C7 extraction (#1579).
      # Every app that uses it declares this dep directly rather than relying
      # on reaching it transitively through ezagent_core — same as
      # ezagent_domain_git, ezagent_plugin_world, and ezagent_plugin_kanban.
      # This app was invisible to #1579 because it lives only on the Plan E
      # integration branch, so the dep is added here instead.
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true}
    ]
  end
end
