defmodule EzagentPluginRegDoccomment.MixProject do
  @moduledoc """
  Check-7 POSITIVE (false-positive regression) fixture. A plugin
  app whose ONLY `*Registry.register` occurrences are inside a
  `@moduledoc` heredoc AND a `#` line comment — never a real call. This
  mirrors `ezagent_plugin_forgejo`'s moduledoc (which reddened the prod
  build): the old raw-text grep matched the prose as if it were a call.
  The AST-based check must PASS this fixture while STILL flagging genuine
  calls (`ezagent_plugin_reg_runtime` / `ezagent_plugin_reg_aliased`).

  Reuses the already-compiled `EzagentPluginConforming` contract module,
  so with check 7 correctly silent the gate is clean end-to-end.
  """
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_reg_doccomment,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginConforming]
    ]
  end

  defp deps do
    [{:ezagent_core, path: "../../../../ezagent_core"}]
  end
end
