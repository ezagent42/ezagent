defmodule EzagentPluginBroken do
  @moduledoc """
  Trivial module so the fixture app has something to compile. It does
  NOT `use Ezagent.Plugin` and the app does NOT name it via the
  `:ezagent_plugin` env key — the whole point of this fixture is that
  the gate has no contract module to check, which (post codex PR-5
  HIGH-3) is itself a build failure for an `ezagent_plugin_*` app.
  """
  def hello, do: :broken
end
