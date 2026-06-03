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
      elixir: "~> 1.15",
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
      mod: {EzagentPluginLoom.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginLoom.Application],
      # :inets + :ssl — `:httpc` is used by the (now-dormant) DeepSeek
      # shell. Kept since `EzagentPluginLoom.DeepSeek` is retained.
      # :erlexec — `EzagentPluginLoom.ClaudeCode` drives the local
      # `claude -p` binary via `:exec.run_link/2` (2026-06-01: loom LLM
      # backend switched from DeepSeek HTTP to local Claude Code).
      extra_applications: [:logger, :inets, :ssl, :erlexec]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # 2026-06-01 — `EzagentPluginLoom.ClaudeCode` 用 `:exec.run_link/2`
      # 跑本地 `claude -p` 作为 LLM 后端(项目唯一 OS-process 库)。
      {:erlexec, "~> 2.3"},
      # Boot-order constraint only (no code referenced): the default
      # `loom_agent` instance is seeded in this plugin's `after_boot/0`
      # via the `entity://` SpawnRegistry dispatcher, which
      # `ezagent_domain_chat` registers in its `start/2`. Loom Kinds
      # also live under `EzagentDomainChat.AgentSupervisor`
      # (`Ezagent.Entity.Loom.supervisor/0`). Declaring the dep makes
      # OTP boot domain_chat BEFORE this plugin.
      {:ezagent_domain_chat, in_umbrella: true},
      # loom v0.2 — `EzagentPluginLoom.Feishu` binds bootstrapped
      # sessions to the demo Feishu group via `Ezagent.ExternalMirror.BindingRow`
      # + spawns `Ezagent.Entity.ExternalMirrorWorker` (one-way mirror, PRD §5.4).
      {:ezagent_domain_external_mirror, in_umbrella: true},
      # loom 前端集成 (2026-05-29) — `EzagentPluginLoom.WebPlug` 用
      # `Plug.Router` 在 /loom 下提供 ai-ui-builder 静态产物 +
      # /loom/api/chat 代理。同飞书 WebhookPlug 的 `:plug` 声明。
      {:plug, "~> 1.18"},
      # 2026-06-01 — `Ezagent.PluginLoom.View.LoomSessionView` registers
      # into `Ezagent.UI.SessionViewRegistry` to add a "Loom" tab to the
      # session view-switcher (in-page iframe of /loom/:ws/:name).
      {:ezagent_domain_ui, in_umbrella: true}
    ]
  end
end
