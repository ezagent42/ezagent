defmodule EzagentDomainProviderConnection.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :ezagent_domain_provider_connection,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      deps: deps()
    ]

  def application,
    do: [mod: {EzagentDomainProviderConnection.Application, []}, extra_applications: [:logger]]

  defp deps,
    do: [
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:jason, "~> 1.2"}
    ]
end
