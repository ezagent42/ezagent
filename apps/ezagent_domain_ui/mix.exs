defmodule EzagentDomainUi.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_ui,
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

  # Phase 6 PR 3: ui domain — shadcn-like HEEx component primitives
  # any plugin (including ezagent_plugin_liveview) can use to build pages.
  #
  # Domain.Pty PR-C (2026-05-21) — promoted from library to OTP app to
  # register `EzagentDomainUi.Pty.TerminalView` as a SessionView at
  # boot. The Application boots no GenServers; it's a registration
  # hook only.
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
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_pty, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"}
    ]
  end
end
