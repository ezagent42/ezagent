defmodule EzagentPluginHello.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_hello,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract §3.2 — the non-bypassable app-level gate
      # (verifies declared kinds/behaviors/templates exist + implement their
      # behaviour). Same wiring as every ezagent_plugin_* app.
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginHello.Application, []},
      # Plugin authoring contract §3.2 — names the plugin contract module for
      # the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginHello.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # `Behavior.Turn` + `Behavior.Surface` (the page chokepoint) live in
      # ezagent_domain_session; the hello page is born only via
      # `Surface.put_version/2` driven by `Turn`.
      {:ezagent_domain_session, in_umbrella: true},
      # `CustomerFeed` + `public_view` (anonymous visitor delivery of the
      # approved Surface tree) live in ezagent_domain_socialware.
      {:ezagent_domain_socialware, in_umbrella: true},
      # `Ezagent.UI.SessionViewRegistry` — register the hello operator PageView.
      {:ezagent_domain_ui, in_umbrella: true}
    ]
  end
end
