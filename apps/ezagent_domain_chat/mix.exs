defmodule EzagentDomainChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_chat,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentDomainChat.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # Chat references User Kind (admin join, :receive on User) and
      # Workspace.Loader (boot_complete in start callback). The dep
      # order also enforces start order: identity → workspace → chat.
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # Domain.Pty PR-B (2026-05-21 SPEC v1): Chat's Application
      # registers `Ezagent.Behavior.Pty` against `Ezagent.Entity.Agent`
      # — the Kind ↔ Behavior binding belongs in the app that defines
      # the Kind. Behavior module itself lives in ezagent_domain_pty.
      # Tier-2 sibling dep (no cycle: domain_pty → core only).
      {:ezagent_domain_pty, in_umbrella: true},
      # Chat.invoke(:receive) for Agent dispatches to the v2 CC channel
      # BridgeRegistry. v1 prototype dep + fallback branch removed in
      # PR 32c (rebrand-4) after PtyServer cutover landed in PR 32b.
      # layer-violation-exempt: cc-bridge production wire
      {:ezagent_plugin_cc, in_umbrella: true},
      # Phase 7 completion PR-5: the orchestrator MCP transport bridge's
      # BEAM endpoint is a Phoenix.Socket + Phoenix.Channel
      # (Ezagent.Orchestrator.McpSocket / McpChannel) — the same house
      # transport the cc channel bridge uses. Declared explicitly even
      # though Phoenix is transitively present (via ezagent_plugin_cc),
      # because this app now `use`s Phoenix.Socket / Phoenix.Channel.
      {:phoenix, "~> 1.8.0"}
    ]
  end
end
