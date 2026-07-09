defmodule EzagentPluginCrawler.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_crawler,
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
      mod: {EzagentPluginCrawler.Application, []},
      # Plugin authoring contract §3.2 — names the plugin contract module for
      # the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginCrawler.Application],
      # `:inets`/`:ssl` — the OTP `:httpc` client Fetch uses to crawl public
      # sources needs both applications started.
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_ui, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      # 组合 hello 拿公开面 + concierge（展示腿）——dealscout manifest
      # `uses: ["hello", "crawler"]`。爬取能力本身不用它，但 demo socialware
      # 组合（manifest 测试解析 hello recipes + ALT 调 hello 公开生成入口）
      # 需要它先编译进 build path。
      {:ezagent_plugin_hello, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
