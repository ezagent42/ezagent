defmodule EzagentDomainInstanceMessage.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_session,
      version: "0.1.0",
      package: package(),
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

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      mod: {EzagentDomainInstanceMessage.Application, []},
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
      # ExternalMirror PR-EM-0 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
      # §9): chat depends on external_mirror for the `Ezagent.ActionSet.Publisher`
      # contract module + `Ezagent.Publisher.Event` struct. The dep is
      # unidirectional — external_mirror NEVER depends on chat
      # (Publisher is duck-typed against any publishing Kind URI via
      # `Invocation.dispatch/1`); putting Session implementation in
      # chat (rather than external_mirror) keeps the new Domain free
      # of references to the publishing Kinds it serves.
      {:ezagent_domain_external_mirror, in_umbrella: true},
      # Domain.Pty PR-B (2026-05-21 SPEC v1): Chat's Application
      # registers `Ezagent.ActionSet.Pty` against `Ezagent.Entity.Agent`
      # — the Kind ↔ Behavior binding belongs in the app that defines
      # the Kind. Behavior module itself lives in ezagent_domain_pty.
      # Tier-2 sibling dep (no cycle: domain_pty → core only).
      {:ezagent_domain_pty, in_umbrella: true},
      # AgentBridge PR-D: Agent chat.receive builds
      # Ezagent.AgentBridge.Payload and dispatches through the
      # plugin-independent bridge facade.
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      # PR-9a (#53): the agent domain (Agent Kind + agent.receive). The session
      # domain references `Ezagent.Entity.Agent` / `AgentTemplate` from its spawn
      # fns + session-management logic (im → session → agent). The reverse — the
      # agent-flavor resolver `delivery.ex` still calls — is the one allowlisted
      # cross-edge the acyclic gate tracks (shrunk by 9c).
      {:ezagent_domain_agent, in_umbrella: true},
      {:yaml_elixir, "~> 2.9"},
      # Phase 7 completion PR-5: the orchestrator MCP transport bridge's
      # BEAM endpoint is a Phoenix.Socket + Phoenix.Channel
      # (Ezagent.Orchestrator.McpSocket / McpChannel). Declared
      # explicitly because this app now `use`s Phoenix.Socket /
      # Phoenix.Channel.
      {:phoenix, "~> 1.8.0"},
      # Phase 7 MCP-bridge hardening (codex MEDIUM-3): the authenticated
      # subprocess test (`orchestrator_mcp_bridge_test.exs`) starts a
      # real HTTP listener hosting `McpSocket` so the Python bridge can
      # round-trip a `tools/call` through the production transport.
      # Bandit is the project's adapter (`config/config.exs`); declared
      # test-only here so the test runs even when this app's suite is
      # invoked standalone (`mix cmd --app ezagent_domain_session`).
      {:bandit, "~> 1.5", only: :test}
    ]
  end
end
