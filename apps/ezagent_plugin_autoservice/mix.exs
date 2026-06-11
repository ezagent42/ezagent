defmodule EzagentPluginAutoservice.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_autoservice,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Plugin authoring contract SPEC §3.2 — `:ezagent_plugin_check`
      # is the non-bypassable app-level gate; runs after the app
      # compiles. `:phoenix_live_view` stays first (it preprocesses
      # `.heex` colocated hooks before the standard Elixir compiler) —
      # this plugin hosts the customer + operator chat LiveViews.
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:ezagent_plugin_check]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # Plugin authoring contract SPEC §3 — the OTP app boots the
      # plugin contract module via two-phase `Ezagent.Plugin.boot/1`.
      mod: {EzagentPluginAutoservice.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin contract
      # module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginAutoservice.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # SocialwareSession Kind + Behavior.Turn/Surface/ConfigUpdate +
      # ConfigStore / ConfigProjection / CustomerFeed — the autoservice
      # session is built on the socialware base (autoservice→socialware).
      {:ezagent_domain_socialware, in_umbrella: true},
      # Session Kind + Chat behavior + EzagentDomainChat facade.
      {:ezagent_domain_instance_message, in_umbrella: true},
      # Content supply: TenantPaths / TenantContent / soul files.
      {:ezagent_plugin_content, in_umbrella: true},
      # CR (code review) plugin — depended upon for config plumbing.
      {:ezagent_plugin_cr, in_umbrella: true},
      # curl-flavored fast agent.
      {:ezagent_plugin_curl_agent, in_umbrella: true},
      # cc-flavored slow agent.
      {:ezagent_plugin_cc, in_umbrella: true},
      # NOTE: deliberately do NOT depend on :ezagent_web — ezagent_web
      # owns routing and references this plugin's LiveView modules by
      # atom; a back-dep would create a compile cycle (same rule as
      # ezagent_plugin_liveview).
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.2"}
    ]
  end
end
