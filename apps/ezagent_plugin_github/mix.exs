defmodule EzagentPluginGithub.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_github,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract —— 非旁路的 app-level gate（对齐 kanban/email）。
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginGithub.Application, []},
      # 给 :ezagent_plugin_check gate 指明 plugin 契约模块。
      env: [ezagent_plugin: EzagentPluginGithub.Application],
      # gh CLI 走 System.cmd（无 :httpc）—— 只需 :logger。
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # role-as-data (SPEC §3/§4)：github-gateway recipe 的 boot 注册回环（seed → lookup）
      # 在 `Ezagent.Agent.RecipeRegistry`（domain_agent）。github lib 不在运行时引它（框架 boot
      # 经 RoleSeedHook 种 recipe）——仅 github_role_test 用,故 TEST-ONLY。plugin → domain
      # （允许的依赖箭头），非 plugin → plugin。
      {:ezagent_domain_agent, in_umbrella: true, only: :test},
      # 解析 gh CLI 的 JSON 输出（gh api / gh pr list --json）。
      {:jason, "~> 1.2"}
    ]
  end
end
