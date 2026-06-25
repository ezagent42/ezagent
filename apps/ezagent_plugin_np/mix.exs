defmodule EzagentPluginNp.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_np,
      version: "0.1.0",
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

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentPluginNp.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginNp.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      # Outbound chat/send dispatch into the originating session uses
      # the Chat behavior (no new outbound wire).
      {:ezagent_domain_session, in_umbrella: true},
      # Domain.Python is the Tier-2 runtime this plugin validates
      # end-to-end. Per-NpAgent Kind, the Template Class starts a
      # `Ezagent.Domain.Python.Server` running the numpy/sympy
      # compute script.
      {:ezagent_domain_python, in_umbrella: true},
      # TEST-ONLY (post-lifecycle remediation): the comprehensive
      # 4-agent e2e (admin → cc → curl → np → admin) spawns a CurlAgent
      # leg via `Ezagent.Kind.spawn(Ezagent.Entity.CurlAgent, …)`. That
      # Kind module is DEFINED in ezagent_plugin_curl_agent; running the
      # np suite in isolation without it leaves the module unloaded, so
      # the spawn fails `{:undef, [{Ezagent.Entity.CurlAgent,
      # :persistence, …}]}`. The full umbrella masks this (curl_agent
      # boots alongside np). Depend on it `only: :test` so the isolated
      # e2e matches the production topology without coupling lib/.
      {:ezagent_plugin_curl_agent, in_umbrella: true, only: :test},
      # The comprehensive 4-agent e2e mocks the curl-agent's downstream
      # DeepSeek endpoint via a tiny Bandit+Plug listener (see
      # test/support/mock_deepseek.ex). NOT `only: [:test]`: sibling
      # umbrella apps (ezagent_plugin_feishu → :plug, ezagent_web →
      # :bandit) declare these deps unrestricted, and Mix requires the
      # `:only` scope to agree across the umbrella — a `[:test]`
      # restriction here makes np un-runnable as the lead project
      # ("the :only option ... does not match the :only option
      # calculated for {:plug, ..., optional: false}").
      {:plug, "~> 1.18"},
      {:bandit, "~> 1.5"}
    ]
  end
end
