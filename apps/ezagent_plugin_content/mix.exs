defmodule EzagentPluginContent.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_content,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {EzagentPluginContent.Application, []}]
  end

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_socialware, in_umbrella: true},
      {:yaml_elixir, "~> 2.0"}
    ]
  end
end
