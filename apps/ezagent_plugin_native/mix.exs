defmodule EzagentPluginNative.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_native,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
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
      mod: {EzagentPluginNative.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin contract
      # module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginNative.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # The `native` flavor resolves to the UNIFIED `Ezagent.Entity.Agent`
      # Kind (the generic, no-sidecar host) from the agent domain. plugin →
      # domain is the allowed direction (the agent domain stays a leaf; it
      # never depends back on this plugin).
      {:ezagent_domain_agent, in_umbrella: true},
      # The Template Class registers against the workspace template catalog.
      {:ezagent_domain_workspace, in_umbrella: true}
    ]
  end
end
