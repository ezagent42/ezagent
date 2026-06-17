defmodule EzagentPluginLoom.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_loom,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {EzagentPluginLoom.Application, []},
      env: [ezagent_plugin: EzagentPluginLoom.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_socialware, in_umbrella: true},
      # 复用现成 OpenAI/DeepSeek-shape HTTP 客户端(Ezagent.PluginCurlAgent.ApiClient),
      # 不自造 :httpc 调用。ApiClient 是无状态纯模块,无需 curl_agent 起 app 进程。
      {:ezagent_plugin_curl_agent, in_umbrella: true},
      {:plug, "~> 1.16"}
    ]
  end
end
