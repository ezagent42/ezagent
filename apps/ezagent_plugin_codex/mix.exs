defmodule EzagentPluginCodex.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_codex,
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
      extra_applications: [:logger],
      mod: {EzagentPluginCodex.Application, []},
      env: [ezagent_plugin: EzagentPluginCodex.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      {:ezagent_domain_pty, in_umbrella: true},
      {:phoenix, "~> 1.8.0"}
    ]
  end
end
