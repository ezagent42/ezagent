defmodule EzagentCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_cli,
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
      # :crypto for Ezagent.Runtime cookie generation. No HTTP deps —
      # CLI reaches the runtime via distributed Erlang RPC.
      extra_applications: [:logger, :crypto],
      mod: {EzagentCli.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # Session-Config operations are domain APIs. The CLI is a thin outer
      # projection and therefore depends on the owning session domain in
      # production rather than re-declaring names/schemas locally.
      {:ezagent_domain_session, in_umbrella: true},
      {:optimus, "~> 0.5"},
      {:jason, ">= 0.0.0"}
    ]
  end
end
