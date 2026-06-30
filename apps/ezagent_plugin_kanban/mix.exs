defmodule EzagentPluginKanban.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_kanban,
      version: "0.1.0",
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
      # RUNTIME dep — the connectors' lazy github-gateway seed
      # (`Connectors.ensure_gateway/0`) calls `Ezagent.Workspace.create_agent`
      # (RF-5a role-create) at first github dispatch — so workspace is PROD, NOT
      # `only: :test`. plugin → domain is the allowed arrow (mirrors ezagent_plugin_cc);
      # NOT a plugin → plugin dep (the github gateway is reached purely by dispatch /
      # role name, zero compile dep on ezagent_plugin_github).
      {:ezagent_domain_workspace, in_umbrella: true},
      # role-as-data (SPEC §4): domain_agent is a PROD dep — `roles/0` is seeded at
      # boot via `Ezagent.Plugin.RoleSeedHook` (impl registered by domain_agent's
      # `start/2`, so OTP starts it BEFORE this plugin's `boot/1` seeds its role),
      # AND `ezagent_domain_workspace` (above) depends on it at runtime, so it
      # cannot be `only: :test`. plugin → domain, not plugin → plugin.
      {:ezagent_domain_agent, in_umbrella: true},
      # session is only exercised by K2/K3 integration tests (relay etc.) — no
      # runtime lib reference — so it stays TEST-ONLY.
      {:ezagent_domain_session, in_umbrella: true, only: :test},
      # T7f: the generic `mix ezagent dispatch` verb e2e drives the CLI Exec
      # surface against a role-mounted kanban agent (the actual gap the verb
      # closes). TEST-ONLY — kanban has ZERO runtime ref to the CLI, and cli
      # does NOT depend on kanban, so no compile cycle.
      {:ezagent_cli, in_umbrella: true, only: :test}
    ]
  end
end
