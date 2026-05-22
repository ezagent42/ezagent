defmodule EzagentPluginEcho.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_echo,
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
      mod: {EzagentPluginEcho.Application, []},
      # Plugin authoring contract SPEC §3.2 — names the plugin
      # contract module for the :ezagent_plugin_check gate.
      env: [ezagent_plugin: EzagentPluginEcho.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      # Domain.Pty SPEC v1 §4 cross-flavor opt-in
      # (`Ezagent.PluginEcho.Template.EchoAgent`): when an echo agent
      # template sets `with_pty: true`, instantiate calls
      # `Ezagent.Domain.Pty.start/2` to attach a `/bin/bash -i` PTY
      # sidecar — surfacing the agent in the SessionView Terminal tab
      # + `/identities/agents/:uri/terminal` standalone page.
      {:ezagent_domain_pty, in_umbrella: true},
      # Plugin authoring contract PR-5 codex HIGH-2 — the default echo
      # agent is seeded in this plugin's `after_boot/0` (it owns the
      # echo flavor). The seed spawns via the `entity://` SpawnRegistry
      # dispatcher, which `ezagent_domain_chat` registers in its
      # `start/2`. Declaring the dep makes OTP boot domain_chat BEFORE
      # this plugin, so the `entity://` spawn fn is published by the
      # time `after_boot/0` runs. (No code from domain_chat is
      # referenced here — the dep is purely a boot-order constraint.)
      {:ezagent_domain_chat, in_umbrella: true}
    ]
  end
end
