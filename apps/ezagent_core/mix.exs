defmodule EzagentCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_core,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EzagentCore.Application, []},
      extra_applications: [:logger, :runtime_tools, :erlexec]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      # Presence SPEC `docs/superpowers/specs/2026-05-23-presence.md` —
      # Phoenix.Presence (CRDT-replicated liveness tracking) is in :phoenix,
      # NOT :phoenix_pubsub. Per `layer_purity_test`: core may carry
      # external Hex deps; the rule is "no umbrella deps".
      {:phoenix, "~> 1.8"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:erlexec, "~> 2.3"}
      # bcrypt_elixir moved to ezagent_domain_identity in Phase 6 PR 2.
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run #{__DIR__}/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
