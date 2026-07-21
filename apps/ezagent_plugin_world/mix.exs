defmodule EzagentPluginWorld.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_world,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:ezagent_plugin_check],
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
      mod: {EzagentPluginWorld.Application, []},
      env: [ezagent_plugin: EzagentPluginWorld.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:ezagent_domain_pty, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # SessionView registry owner (Ezagent.UI.SessionViewRegistry). world consumes
      # it to enumerate the session's caller-visible views into dynamic tabs; this
      # is an in-umbrella REFERENCE only (world does not modify ezagent_domain_ui).
      {:ezagent_domain_ui, in_umbrella: true},
      # Operator console ensures a hello session created from a PUBLISHED template
      # gets its @hello builder (the generic create path installs behaviours + the
      # seeded page but not the per-session builder). world already integrates the
      # hello vertical on the frontend (Page pane); this is the backend counterpart.
      {:ezagent_plugin_hello, in_umbrella: true},
      # ⚠️ 过渡脚手架，**随 zyli 的 #1476 整行删除** ⚠️
      #
      # 债②：kanban 页面的数据/动作层（WorldData / WorldActions）已搬进 kanban
      # plugin，但**注册那一半还留在 world**——`PluginPageRegistry` 的 `@pages` 是
      # 编译期常量，字面写着 `EzagentPluginKanban.WorldData/WorldActions`
      # （world_live 的 `state_for_route` 编译期 unroll 也 unquote 这些模块名），
      # 于是 world 代码里出现了跨 app 硬引用 → `undeclared_umbrella_dep_test.exs`
      # （#57 arch gate）要求声明它。dep 方向 world → plugin_kanban（hello 先例）；
      # plugin_kanban **不得**反向引 world 模块（会成环——presenter cap 是经
      # `Ezagent.World.PresenterCaps.put/1` 塞进 socket assign 传过去的，不是反向调用）。
      #
      # 消失条件：#1476（UiSurfaceProvider 插件 UI 自声明）把 `@pages` 从编译期常量
      # 反转成运行时 `resolve/1` 枚举各插件的声明——模块名从插件自己的声明里来，
      # world 里不再出现字面引用，本行连同 `@pages` 的 kanban 条目一起删。
      {:ezagent_plugin_kanban, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end
end
