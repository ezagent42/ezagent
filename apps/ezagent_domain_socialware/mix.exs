defmodule EzagentDomainSocialware.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_socialware,
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
      mod: {EzagentDomainSocialware.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      # P3-2: the customer feed is a `:pull` `Ezagent.ExternalMirror.Adapter`
      # (`Ezagent.Socialware.CustomerFeedAdapter`), so socialware needs the
      # external-mirror behaviour at compile time. No cycle: external_mirror
      # does NOT depend on socialware.
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:ezagent_domain_ui, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"}
    ]
  end
end
