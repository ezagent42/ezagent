defmodule EzagentPluginForgejo.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_forgejo,
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
      extra_applications: [:logger, :crypto],
      mod: {EzagentPluginForgejo.Application, []},
      env: [ezagent_plugin: EzagentPluginForgejo.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # Ezagent.URI lives in ezagent_actor; OAuthApp validates workspace URIs with it.
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true},
      {:ezagent_domain_provider_connection, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"}
    ]
  end
end
