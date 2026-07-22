defmodule EzagentPluginGithub.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_github,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key],
      mod: {EzagentPluginGithub.Application, []},
      env: [ezagent_plugin: EzagentPluginGithub.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true},
      {:ezagent_domain_provider_connection, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.18"}
    ]
  end
end
