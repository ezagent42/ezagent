defmodule EzagentPluginKanban.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_kanban,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract — the non-bypassable app-level gate.
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginKanban.Application, []},
      # Names the plugin contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginKanban.Application],
      # :inets/:ssl/:crypto for the Miro REST client (:httpc, mirrors feishu).
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # Miro REST client JSON encode/decode（飞书也用，:httpc + Jason 不引重依赖）。
      {:jason, "~> 1.2"}
    ]
  end
end
