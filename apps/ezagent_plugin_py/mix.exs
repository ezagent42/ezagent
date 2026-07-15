defmodule EzagentPluginPy.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_py,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract SPEC §3.2 — the non-bypassable app-level
      # gate. Runs after the app has compiled so its cross-module checks
      # (declared kinds/behaviors/templates exist + implement their
      # behaviour) can see every sibling module.
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
      extra_applications: [:logger],
      mod: {EzagentPluginPy.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin contract
      # module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginPy.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      # P4b — the py `:in_process_sync` BridgeAdapter implements the
      # `Ezagent.AgentBridge.Adapter` behaviour from this app.
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      # Outbound chat/send dispatch into the originating session uses the
      # Chat behavior (no new outbound wire).
      {:ezagent_domain_session, in_umbrella: true},
      # The unified create path (Workspace.create_agent) lives here; the
      # py create-path-live e2e drives it through this dep.
      {:ezagent_domain_workspace, in_umbrella: true},
      # Domain.Python is the Tier-2 runtime py consumes: per-PyAgent Kind,
      # the Template Class starts an Ezagent.Domain.Python.Server running
      # the operator-supplied script installed into the config_dir.
      {:ezagent_domain_python, in_umbrella: true}
    ]
  end
end
