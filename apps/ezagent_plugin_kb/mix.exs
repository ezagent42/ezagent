defmodule EzagentPluginKb.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_kb,
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
      extra_applications: [:logger],
      mod: {EzagentPluginKb.Application, []},
      # Names the plugin contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginKb.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # The per-KB sqlite store driver, used DIRECTLY (NOT a 2nd Ecto.Repo —
      # one sqlite file PER kb-agent does not fit a single bound Ecto.Repo).
      # ezagent's own DB stays Postgres; exqlite opens ONLY the isolated,
      # portable per-KB sqlite files. Re-treads a removed path (ezagent ran on
      # exqlite/ecto_sqlite3 before the Postgres migration).
      {:exqlite, "~> 0.37"},
      # kb-as-role integration tests: the role × native create path lives in
      # the workspace/agent/session domains. plugin → domain is the allowed
      # dependency arrow (mirrors kanban). lib/ never references the domains (it
      # only declares the recipe + behaviors; the framework wires them at boot).
      {:ezagent_domain_workspace, in_umbrella: true, only: :test},
      # role-as-data (SPEC §4): domain_agent is now a PROD dep, not test-only —
      # `roles/0` is seeded at boot via `Ezagent.Plugin.RoleSeedHook` (impl
      # registered by domain_agent's `start/2`). The prod dep makes OTP start
      # domain_agent BEFORE this plugin, so the hook is registered before this
      # plugin seeds its role (the seam is no-op if unregistered).
      {:ezagent_domain_agent, in_umbrella: true},
      # Kb.data_owner/1 delegates to the identity domain's canonical ApiKeys
      # owner resolver (creator_uri -> AgentLineage -> :no_owner).
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true, only: :test},
      {:ezagent_domain_agent_bridge, in_umbrella: true, only: :test},
      {:ezagent_plugin_codex, in_umbrella: true, only: :test},
      {:ezagent_plugin_world, in_umbrella: true, only: :test}
    ]
  end
end
