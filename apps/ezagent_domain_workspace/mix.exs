defmodule EzagentDomainWorkspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_workspace,
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

  # Phase 6 PR 2: workspace domain — Workspace Kind + Workspace
  # Behavior + the loader/store that lift persisted Workspaces back
  # into running Kinds at boot. Owned by core team.
  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      mod: {EzagentDomainWorkspace.Application, []},
      extra_applications: [:logger],
      env: [ezagent_resource_provider: EzagentDomainWorkspace.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true},
      # Workspace.Loader uses admin caps from User Kind.
      {:ezagent_domain_identity, in_umbrella: true}
    ]
  end
end
