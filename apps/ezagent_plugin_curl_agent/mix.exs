defmodule EzagentPluginCurlAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_curl_agent,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract SPEC §3.2 — the non-bypassable
      # app-level gate. Runs after the app has compiled so its
      # cross-module checks (declared kinds/behaviors/templates exist
      # + implement their behaviour) can see every sibling module.
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
      extra_applications: [:logger, :inets, :ssl],
      mod: {EzagentPluginCurlAgent.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginCurlAgent.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # User Kind lives here; CurlAgent dispatches identity/get_api_key
      # against the caller User to fetch the per-user DeepSeek key.
      {:ezagent_domain_identity, in_umbrella: true},
      # Template Class registers against the workspace template catalog.
      {:ezagent_domain_workspace, in_umbrella: true},
      # PR-6 (im/session/agent decomposition) — the curl flavor's
      # `:in_process_sync` transport adapter implements
      # `Ezagent.AgentBridge.Adapter`, so the bridge domain is a direct dep.
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      # PR-9c (#53) — the curl STATE Behavior `Ezagent.ActionSet.CurlAgent` is
      # REPARENTED into the agent domain (it composes onto `Entity.Agent` as the
      # curl flavor's state half). This plugin still owns the curl flavor WIRING
      # (`behaviors/0` binds `{Entity.Agent, action} → CurlAgent`, plus the
      # template/adapter/flavor), so it references both `Entity.Agent` and
      # `Behavior.CurlAgent` from this domain — the dep makes that explicit and
      # guarantees the agent domain compiles before the `:ezagent_plugin_check`
      # gate validates those bindings. plugin → domain is the allowed direction
      # (the agent domain stays a leaf; it never depends back on this plugin).
      {:ezagent_domain_agent, in_umbrella: true},
      # Outbound chat/send dispatch into the originating session uses
      # the Chat behavior (no new outbound wire).
      {:ezagent_domain_session, in_umbrella: true}
    ]
  end
end
