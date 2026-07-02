defmodule EzagentDomainAgentBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_agent_bridge,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
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
      extra_applications: [:logger, :yaml_elixir],
      mod: {EzagentDomainAgentBridge.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Tier-2 Domain app. AgentBridge owns the shared bridge primitives
      # that bridge-backed agent plugins use; it must not depend on plugins.
      {:ezagent_core, in_umbrella: true},
      {:phoenix, "~> 1.8.0"},
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
