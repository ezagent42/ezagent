defmodule EzagentDomainAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_agent,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
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
      extra_applications: [:logger],
      mod: {EzagentDomainAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Tier-2 Domain leaf (im → session → agent). Holds the Agent Kind,
      # its lifecycle/read facade, and its transport seam
      # (`agent.receive` → AgentBridge). It never depends on the session/im
      # domain nor on any plugin (PR-9a, #53). Identity/curl behaviors composed onto
      # the Agent Kind are referenced as bare atoms (runtime, via the umbrella
      # app load + the BehaviorRegistry), not compile deps.
      {:ezagent_core, in_umbrella: true},
      # Agent.Config is the cap-gated facade over ConfigEvolve + ConfigStore,
      # both owned by the identity/socialware substrate.
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_agent_bridge, in_umbrella: true}
    ]
  end
end
