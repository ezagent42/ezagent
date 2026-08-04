defmodule EzagentDomainUi.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_ui,
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

  # Phase 6 PR 3: ui domain — shadcn-like HEEx component primitives
  # any plugin can use to build pages.
  #
  # Domain.Pty PR-C (2026-05-21) — promoted from library to OTP app to
  # register `EzagentDomainUi.Pty.TerminalView` as a SessionView at
  # boot. The Application boots no GenServers; it's a registration
  # hook only.
  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentDomainUi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Tier-2 rule: Domain apps depend on ezagent_core (always) and
      # may reference sibling Domain apps. ezagent_domain_pty is
      # consumed by EzagentDomainUi.Pty.TerminalView.applies_to?/1
      # which queries Ezagent.Domain.Pty.alive?/1 for cross-flavor
      # detection (Domain.Pty PR-C, 2026-05-21).
      #
      # V1 UI PR-1 (SPEC §1.3) — ezagent_domain_identity is consumed by
      # `Ezagent.UI.UriOptions`, which enriches option labels via
      # `Ezagent.EntityPresenter.display/1`. Identity is a sibling
      # Domain app that depends only on ezagent_core, so this introduces
      # no dependency cycle.
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_pty, in_umbrella: true},
      # TerminalView also reads durable AgentAdmission rows to expose a
      # provisional live PTY before its agent joins session.members. Session
      # depends on core/identity/workspace/pty, never domain_ui, so this
      # sibling-domain edge is acyclic.
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      # Read-plane PR-4 rework — `Ezagent.UI.UriOptions` enumerates
      # sessions/agents/users through the caller-authorizing chokepoints
      # (`Ezagent.Workspace.WorkspaceReads` / `UserReads`) instead of the
      # global registry. workspace is a sibling Domain app (deps: core,
      # agent, identity — never ui), so no dependency cycle.
      {:ezagent_domain_workspace, in_umbrella: true},
      # 2026-05-25 — ExternalMirror Bindings SessionView (under
      # `EzagentDomainUi.ExternalMirror.View`) consumes
      # `Ezagent.ExternalMirror.list_bindings/2` to render the per-
      # session bindings tab in the `/sessions` view-switcher. Domain
      # → Domain dep (no cycle: external_mirror depends only on core).
      {:ezagent_domain_external_mirror, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      # i18n (Allen 2026-05-22) — domain_ui owns its own Gettext backend
      # (`EzagentDomainUi.Gettext`) + `priv/gettext` tree. `:gettext` is
      # a standalone Hex lib, NOT `:ezagent_web` — a Tier-2 domain app
      # depending on it introduces no tier violation. This keeps the
      # shared UI component library self-sufficient for translation
      # without threading translated-string assigns through every
      # Tier-3 call site (standard Phoenix shared-component pattern).
      {:gettext, "~> 0.26"}
    ]
  end
end
