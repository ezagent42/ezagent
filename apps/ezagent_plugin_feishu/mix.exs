defmodule EzagentPluginFeishu.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_feishu,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract SPEC §3.2 — the non-bypassable
      # app-level gate. Runs after the app has compiled so its
      # cross-module checks (declared kinds/behaviors/templates exist
      # + implement their behaviour) can see every sibling module.
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {EzagentPluginFeishu.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginFeishu.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_chat, in_umbrella: true},
      # PR-EM-6: ExternalMirror Adapter + Binding behaviours +
      # BindingRow projection table. The Feishu plugin's FeishuAdapter
      # / FeishuChatBinding implement these contracts; the inbound
      # dispatcher reads BindingRow for chat_id → session_uri reverse
      # lookup; the migration mix task uses WorkerSpawn + BindingRow
      # directly to migrate legacy feishu_session_bindings rows.
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.18"},
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
