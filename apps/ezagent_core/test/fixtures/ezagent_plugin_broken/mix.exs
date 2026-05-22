defmodule EzagentPluginBroken.MixProject do
  @moduledoc """
  A deliberately NON-CONFORMING `ezagent_plugin_*` Mix project — the
  negative compile fixture for the `:ezagent_plugin_check` gate
  (plugin authoring contract SPEC §3.2 / codex PR-5 HIGH-3).

  It IS named `ezagent_plugin_broken` (so the gate's
  `ezagent_plugin_*` prefix detection fires) and it DOES wire the
  `:ezagent_plugin_check` compiler — but it deliberately OMITS the
  `env: [ezagent_plugin: ...]` key. Per HIGH-3 that omission must now
  FAIL the build. `Mix.Tasks.Compile.EzagentPluginCheckTest`
  compiles this project in a subprocess and asserts a non-zero exit.

  Before the HIGH-3 fix the gate was a no-op `{:ok, []}` for an app
  with no `:ezagent_plugin` key — so this exact app compiled cleanly,
  bypassing every contract check. That is the hole this fixture pins.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_broken,
      version: "0.1.0",
      elixir: "~> 1.15",
      # Wire the gate — but application/0 below has NO :ezagent_plugin
      # key. That combination is the contract violation under test.
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    # DELIBERATELY no `env: [ezagent_plugin: ...]`. An ezagent_plugin_*
    # app MUST declare its contract module here; the omission is what
    # the :ezagent_plugin_check gate must reject (codex PR-5 HIGH-3).
    [extra_applications: [:logger]]
  end

  defp deps do
    # The gate (Mix.Tasks.Compile.EzagentPluginCheck) ships in
    # ezagent_core. Point at the umbrella checkout so the compiler
    # module is on the load path when this fixture compiles.
    [{:ezagent_core, path: "../../../../ezagent_core"}]
  end
end
