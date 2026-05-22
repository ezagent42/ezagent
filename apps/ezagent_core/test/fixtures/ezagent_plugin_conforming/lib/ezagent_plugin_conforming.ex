defmodule EzagentPluginConforming do
  @moduledoc """
  A minimal, CORRECT `use Ezagent.Plugin` contract module — the
  positive control for the `:ezagent_plugin_check` negative compile
  test (codex PR-5 HIGH-3). Implements only the mandatory
  `plugin_info/0`; every optional callback keeps its `use`-injected
  default (`spawns/0 → []`, `config_surface/0 → nil`, …), all of
  which the gate accepts.
  """
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "conforming",
      name: "Conforming Fixture",
      description: "A correct plugin used as the gate's positive control.",
      version: "0.1.0"
    }
  end
end
