defmodule EzagentPluginKanban.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_kanban,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract — the non-bypassable app-level gate.
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
      mod: {EzagentPluginKanban.Application, []},
      # Names the plugin contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginKanban.Application],
      # :inets/:ssl/:crypto for the Miro REST client (:httpc, mirrors feishu).
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # Miro REST client JSON encode/decode（飞书也用，:httpc + Jason 不引重依赖）。
      {:jason, "~> 1.2"},
      # kanban-as-role (K2/K3) integration tests: the role × native create path
      # lives in the workspace/agent/session domains. plugin → domain is the
      # allowed dependency arrow (mirrors ezagent_plugin_cc). The plugin's lib/
      # never references the domains (it only declares the recipe + behaviors; the
      # framework wires them at boot).
      {:ezagent_domain_workspace, in_umbrella: true, only: :test},
      # role-as-data (SPEC §4): domain_agent is now a PROD dep, not test-only —
      # `roles/0` is seeded at boot via `Ezagent.Plugin.RoleSeedHook`, whose impl
      # `Ezagent.Agent.RoleSeedHook` is registered by domain_agent's `start/2`.
      # The prod dep makes OTP start domain_agent BEFORE this plugin, so the hook
      # is registered before this plugin's `Ezagent.Plugin.boot/1` seeds its role
      # (the seam is no-op if unregistered — the dep removes that race).
      {:ezagent_domain_agent, in_umbrella: true},
      # Kanban.data_owner/1 delegates to the identity domain's canonical
      # ApiKeys owner resolver (creator_uri -> AgentLineage -> :no_owner).
      {:ezagent_domain_identity, in_umbrella: true},
      # kanban socialware: domain_session is a PROD dep, not test-only —
      # `BoardView` hard-refs `Ezagent.Socialware.Installation` in lib/ (the
      # board reads the session's installed definitions). Tests additionally
      # drive `Ezagent.Socialware.ShippedManifest.load!/2` directly over the
      # shipped deploy-seed manifest (no plugin-side wrapper module — Decision
      # #156: socialware carries zero code; the governed publish runs on the
      # deploy-seed lane, not this plugin's boot). Undeclared it is a latent
      # "module not available" hazard (#57 arch gate).
      {:ezagent_domain_session, in_umbrella: true},
      # kanban board view (S4): domain_ui owns the `Ezagent.UI.SessionView`
      # contract + `SessionViewRegistry` that `BoardView` implements/registers
      # into (and brings Phoenix.Component for the internal render). PROD dep so
      # the registry ETS table is init'd before this plugin registers (mirrors
      # hello + the world-views ordering note in hello's `Application.start/2`).
      {:ezagent_domain_ui, in_umbrella: true}
    ]
  end
end
