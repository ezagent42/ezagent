defmodule EzagentDomainGit.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_git,
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

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentDomainGit.Application, []}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true}
    ]
  end
end
