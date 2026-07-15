defmodule EzagentPluginEmPull.MixProject do
  @moduledoc """
  A CONFORMING `ezagent_plugin_*` Mix project that declares a
  binding-less `:pull` ExternalMirror adapter as a BARE module entry
  in `adapters/0` — positive control for the P3-1 pull-declaration
  branch of `Mix.Tasks.Compile.EzagentPluginCheckTest`.

  The plugin module declares ONE bare adapter module where:
  - it implements `@behaviour Ezagent.ExternalMirror.Adapter`
  - `adapter_kind/0 == :pull`
  - it declares `render/2` + `cap_subject/0` (the pull-required set)
  - it declares NO `binding_module/0`

  The `:ezagent_plugin_check` gate must ACCEPT this bare-module entry
  (no binding required for a pull adapter).
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_em_pull,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginEmPull]
    ]
  end

  defp deps do
    [
      {:ezagent_core, path: "../../../../ezagent_core"},
      {:ezagent_domain_external_mirror, path: "../../../../ezagent_domain_external_mirror"}
    ]
  end
end
