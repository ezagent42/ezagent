defmodule EzagentActor.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_actor,
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

  # Configuration for the OTP application.
  def application do
    [
      mod: {EzagentActor.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # §3.1 (actor-framework umbrella extraction): NO `in_umbrella` deps — the
  # framework reaches the core spine ONLY through the config-resolved
  # §3.4 port adapters (`Application.fetch_env!(:ezagent_actor, …)`), never
  # a compile-time reference. The standalone `mix compile` of this app is
  # the extraction's proof.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
