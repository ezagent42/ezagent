defmodule EzagentPluginCc.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_cc,
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
      extra_applications: [:logger, :yaml_elixir],
      mod: {EzagentPluginCc.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginCc.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # AgentBridge PR-B: BridgeRegistry + TokenStore moved from the
      # cc plugin into a domain app. The cc-named modules remain as
      # deprecated delegating shims for the deprecation window.
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      # Domain.Pty PR-C (2026-05-21): the PTY SessionView moved out of
      # cc plugin to EzagentDomainUi.Pty.TerminalView. cc plugin no
      # longer depends on domain_ui — no module reference remains. If
      # a future cc-specific component needs it, re-add this dep then.
      # {:ezagent_domain_ui, in_umbrella: true},
      # Domain.Pty PR-A (2026-05-21 SPEC v1): PTY runtime
      # (Server/Supervisor/Registry) moved to ezagent_domain_pty.
      # cc.agent template now calls Ezagent.Domain.Pty.start/2 with
      # the full claude cmd string built here in the cc plugin.
      {:ezagent_domain_pty, in_umbrella: true},
      # PRODUCTION decoupling preserved: bridge reply dispatch uses
      # Ezagent.Invocation + Ezagent.Message from core; no chat-domain
      # modules are called directly in lib/, so chat stays a runtime
      # peer (always co-deployed via ezagent_web), NOT a compile dep.
      #
      # TEST-ONLY chat dep (post-lifecycle remediation): cc agents are
      # the shared `Ezagent.Entity.Agent` Kind, which is DEFINED in
      # ezagent_domain_session, and the `entity://agent` SpawnRegistry host
      # handler (flavor-prefix → Kind resolution) is REGISTERED by
      # chat's Application.start. Running the cc suite in isolation
      # without chat leaves `Ezagent.Entity.Agent` unloadable and the
      # agent-host handler unregistered, so every CcAgent.instantiate
      # test fails with `{:no_entity_host_handler, "agent"}`. The full
      # umbrella masks this because chat boots alongside cc. Depending
      # on chat `only: :test` makes the isolated suite faithful to the
      # production topology (chat always co-runs) without re-coupling
      # the lib/ build. Mirrors ezagent_plugin_echo, which depends on
      # chat outright for the same Agent-Kind/dispatcher reason.
      {:ezagent_domain_session, in_umbrella: true, only: :test},
      # Absorbed from the deleted ezagent_plugin_cc_channel:
      # Phoenix.Socket/Channel for the v2 WS bridge mounted at
      # /cc_socket in EzagentWeb.Endpoint.
      {:phoenix, "~> 1.8.0"},
      # YAML parsing for TokenStore's cc-channels.yaml persistence.
      {:yaml_elixir, "~> 2.9"}
      # erlexec is no longer a direct dep — Ezagent.Domain.Pty.Server
      # (now in ezagent_domain_pty) is the sole :exec.run/2 caller.
      # cc plugin reaches PTY via the Ezagent.Domain.Pty facade only.
    ]
  end
end
