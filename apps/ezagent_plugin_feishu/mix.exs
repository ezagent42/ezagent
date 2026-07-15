defmodule EzagentPluginFeishu.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_feishu,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
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

  defp package do
    [
      licenses: ["Apache-2.0"]
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
      {:ezagent_domain_session, in_umbrella: true},
      # PR-EM-6: ExternalMirror Adapter + Binding behaviours +
      # BindingRow projection table. The Feishu plugin's FeishuAdapter
      # / FeishuChatBinding implement these contracts; the inbound
      # dispatcher reads BindingRow for chat_id → session_uri reverse
      # lookup; the migration mix task uses WorkerSpawn + BindingRow
      # directly to migrate legacy feishu_session_bindings rows.
      {:ezagent_domain_external_mirror, in_umbrella: true},
      # TEST-ONLY (post-lifecycle remediation): MentionParserTest spawns
      # LIVE `cc_`-flavored agents (the parser walks KindRegistry and the
      # URI assertions pin `entity://agent/<ws>/cc_<name>`). Post PR #149
      # the `cc` flavor → Ezagent.Entity.Agent is registered by the cc
      # PLUGIN's `Plugin.boot` into AgentFlavorRegistry, NOT by chat.
      # Running the feishu suite in isolation without the cc plugin yields
      # `{:no_kind_module_for_agent, "...cc_..."}`. The full umbrella
      # masks this (cc boots alongside feishu). Depend on cc `only: :test`
      # so the isolated suite registers the `cc` flavor it asserts against.
      {:ezagent_plugin_cc, in_umbrella: true, only: :test},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.18"},
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
