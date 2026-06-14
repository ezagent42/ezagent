defmodule EzagentPluginLiveview.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_liveview,
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
      # is the non-bypassable app-level gate; it runs after the app
      # has compiled. `:phoenix_live_view` stays first (it preprocesses
      # `.heex` colocated hooks before the standard Elixir compiler).
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:ezagent_plugin_check]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # Plugin authoring contract SPEC §3 — the OTP app boots the
      # plugin contract module via two-phase `Ezagent.Plugin.boot/1`.
      mod: {EzagentPluginLiveview.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginLiveview.Application]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # Phase 6 PR 3: shadcn-like HEEx primitives shared across plugin UIs.
      {:ezagent_domain_ui, in_umbrella: true},
      # NOTE: deliberately do NOT depend on :ezagent_web here. ezagent_web
      # owns routing and references this plugin's LiveView modules by
      # atom — having the plugin also depend on ezagent_web would create a
      # compile cycle. The plugin uses Phoenix.LiveView directly.
      {:phoenix_live_view, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      # i18n (Allen 2026-05-22): the plugin owns its own Gettext backend
      # `EzagentPluginLiveview.Gettext` + `priv/gettext` tree. A
      # plugin-owned backend keeps `mix gettext.extract` self-contained
      # (a foreign backend would fail the clean-build compile-order
      # check). `:gettext` is a standalone Hex lib — no dep on
      # :ezagent_web.
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:ezagent_domain_socialware, in_umbrella: true},
      # Phase 2: the /admin LV displays Session membership (online/
      # offline) sourced from `Ezagent.Behavior.Session`. Same shape as the
      # cc-bridge coupling — Phase 3+ may abstract the LV's "what
      # session UI to show" via configuration rather than direct dep.
      {:ezagent_domain_session, in_umbrella: true},
      # ezagent_plugin_cc — unified CC plugin (merged from cc_pty +
      # cc_channel in PR #130). Provides cc.pty Template Class +
      # PtyServer + BridgeRegistry surface used by admin LV.
      {:ezagent_plugin_cc, in_umbrella: true},
      # Phase 5 PR 6: Feishu adapter — Template Class for
      # session ↔ chat_id binding + outbound subscriber + webhook plug.
      # Direct dep ensures Application.start fires + WebhookPlug compiles.
      {:ezagent_plugin_feishu, in_umbrella: true},
      # PR-EM-4 (2026-05-25): admin LV /admin/sessions/:id/external_mirror
      # consumes the `Ezagent.ExternalMirror` facade (bind / unbind /
      # list_bindings / list_adapters) + `Ezagent.ExternalMirror.WorkerSpawn.
      # worker_uri_for/3` + the per-adapter cap_subject() for caps-filtered
      # adapter dropdown. Per-LV admin tooling is the canonical caller for
      # the facade, so the dep is direct (no transitive coverage from any
      # of the existing :ezagent_plugin_* / :ezagent_domain_* deps).
      {:ezagent_domain_external_mirror, in_umbrella: true}
    ]
  end
end
