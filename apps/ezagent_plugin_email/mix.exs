defmodule EzagentPluginEmail.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_email,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
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
      mod: {EzagentPluginEmail.Application, []},
      env: [ezagent_plugin: EzagentPluginEmail.Application],
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      # #88 PR-1 — the email external-mirror Adapter/Binding implement the
      # generic ExternalMirror domain contract (Adapter/Binding behaviours,
      # Publisher.Event, BindingRow); behaviors/0 registers on the Session Kind.
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:swoosh, "~> 1.17"},
      # Swoosh's SMTP adapter calls :gen_smtp_client — required for the prod
      # SMTP send path (the web mailer declares both; codex plan review MED).
      {:gen_smtp, "~> 1.2"}
    ]
  end
end
