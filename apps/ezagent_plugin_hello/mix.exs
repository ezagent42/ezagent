defmodule EzagentPluginHello.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_hello,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract §3.2 — the non-bypassable app-level gate
      # (verifies declared kinds/behaviors/templates exist + implement their
      # behaviour). Same wiring as every ezagent_plugin_* app.
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
      mod: {EzagentPluginHello.Application, []},
      # Plugin authoring contract §3.2 — names the plugin contract module for
      # the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginHello.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # `Behavior.Turn` + `Behavior.Surface` (the page chokepoint) live in
      # ezagent_domain_session; the hello page is born only via
      # `Surface.put_version/2` driven by `Turn`.
      {:ezagent_domain_session, in_umbrella: true},
      # `ExternalFeed` + `public_view` (external/anonymous visitor delivery of
      # the approved Surface page) live in ezagent_domain_socialware.
      # (Was `CustomerFeed`, renamed in the socialware unification — #1069.)
      {:ezagent_domain_socialware, in_umbrella: true},
      # `Ezagent.UI.SessionViewRegistry` — register the hello internal PageView.
      {:ezagent_domain_ui, in_umbrella: true},
      # `Ezagent.Entity.User` (`User.admin_uri/0` — the admin-genesis dispatch
      # authority used by `App`/`TurnDriver` to drive a session's Turn) is
      # defined in ezagent_domain_identity.
      {:ezagent_domain_identity, in_umbrella: true},
      # `Ezagent.Workspace` (`create/2`) — the hello app's workspace home; used by
      # the demo seed task + the opt-in boot seed.
      {:ezagent_domain_workspace, in_umbrella: true},
      # hello's builder + concierge are ROLES on the unified `Entity.Agent` hosted
      # by the `native` flavor (Principle 1). `App.ensure_app` creates them via
      # `Workspace.create_agent(flavor: "native", role: "hello.…")`, so the native
      # flavor MUST be boot-registered wherever hello boots. The flavor is resolved
      # by the runtime `AgentFlavorRegistry` (a string lookup, no compile coupling),
      # but this dep guarantees `ezagent_plugin_native` starts in hello's app tree.
      {:ezagent_plugin_native, in_umbrella: true},
      # hello owns an agent FLAVOR ("hello") whose in-process AgentBridge adapter
      # routes inbound chat `:receive` to `EzagentPluginHello.Router` — so the
      # orchestrator (a role × "hello" flavor agent) can run custom Elixir on chat
      # (native has no adapter → chat is dropped). Needs the Adapter behaviour +
      # `Ezagent.AgentBridge.Payload`.
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      # `Ezagent.AgentFlavorAttributes` (flavor attribute store, read by the
      # orchestrator migration + the hello.agent Template Class) lives here.
      {:ezagent_domain_agent, in_umbrella: true},
      # hello's `hello.llm` role materializes as a "curl" flavor agent (an HTTP
      # LLM backend, credential-optional) — this dep guarantees the "curl"
      # flavor is boot-registered wherever hello boots, same rationale as the
      # `ezagent_plugin_native` dep above.
      {:ezagent_plugin_curl_agent, in_umbrella: true},
      # i18n (#91, Allen 2026-06-23) — the builder narration (`Generator` turn
      # progress strings) is user-facing copy; it goes through the plugin-owned
      # `EzagentPluginHello.Gettext` backend (per-OTP-app translation namespace,
      # the standard Phoenix pattern — keeps the plugin self-sufficient and out
      # of `ezagent_domain_ui`'s namespace). `:gettext` is the standalone Hex lib,
      # NOT a tier dependency.
      {:gettext, "~> 0.26"}
    ]
  end
end
