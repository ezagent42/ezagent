defmodule EzagentDomainIdentity.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_identity,
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

  # Phase 6 PR 2: identity domain — User Kind + Identity Behavior +
  # Users provisioning facade + auth mix tasks. Owned by core team
  # (not pluggable). Extracted from ezagent_core so plugins that need user
  # references depend only on this domain app, not on the entire core
  # mechanism stack.
  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      mod: {EzagentDomainIdentity.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:bcrypt_elixir, "~> 3.0"}
    ]
  end
end
