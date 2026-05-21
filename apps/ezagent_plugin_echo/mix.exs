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
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginEcho.Application, []},
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
      {:ezagent_domain_pty, in_umbrella: true}
    ]
  end
end
