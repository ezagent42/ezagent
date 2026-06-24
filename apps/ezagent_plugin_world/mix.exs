defmodule EzagentPluginWorld.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_world,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginWorld.Application, []},
      env: [ezagent_plugin: EzagentPluginWorld.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:ezagent_domain_pty, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_plugin_kanban, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end
end
