defmodule EzagentPluginAutoservice.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_autoservice,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # :phoenix_live_view stays first (it preprocesses .heex colocated
      # hooks before the standard Elixir compiler). This plugin hosts the
      # customer + operator chat LiveViews.
      compilers: [:phoenix_live_view] ++ Mix.compilers()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentPluginAutoservice.Application, []},
      env: [ezagent_plugin: EzagentPluginAutoservice.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core runtime: dispatch, KindRegistry, SpawnRegistry, Invocation, Message, etc.
      {:ezagent_core, in_umbrella: true},
      # Content plugin APIs: TenantRuntime, SoulRenderer, KbMcpProvider
      {:ezagent_plugin_content, in_umbrella: true},
      # Socialware domain: settlement integration for customer service
      {:ezagent_domain_socialware, in_umbrella: true},
      # Curl (DeepSeek) agent flavor: fast agent template class
      {:ezagent_plugin_curl_agent, in_umbrella: true},
      # CC (claude-code) agent flavor: create_agent / spawn plan
      {:ezagent_plugin_cc, in_umbrella: true},
      # CR plugin: release management (ensure_active_cr used by migrate_cinnox task)
      {:ezagent_plugin_cr, in_umbrella: true},
      # Identity domain: users, roles, capabilities
      {:ezagent_domain_identity, in_umbrella: true},
      # Instance message domain: Session Kind + Chat behavior
      {:ezagent_domain_session, in_umbrella: true},
      # UI primitives for chat
      {:ezagent_domain_ui, in_umbrella: true},
      # Workspace domain: customer_session.ex + seed task hard-ref `Ezagent.Workspace`
      # (defined here). Declared per #57 — a hard compile ref needs a real dep,
      # not alphabetical umbrella-build-order luck.
      {:ezagent_domain_workspace, in_umbrella: true},
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end
end
