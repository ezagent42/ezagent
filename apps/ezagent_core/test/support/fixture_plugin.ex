defmodule Ezagent.Test.FixturePlugin do
  @moduledoc """
  A minimal, correct `use Ezagent.Plugin` module — the happy-path
  fixture for `Ezagent.PluginTest` and `Ezagent.Plugin.BootTest`.

  It implements the required `plugin_info/0` and relies on the
  `defoverridable` defaults (`kinds/0 → []`, `after_boot/0 → :ok`, …)
  for every optional callback it does not need.

  `boot/1` is exercised against this module by the boot tests; the
  declaration callbacks `behaviors/0` / `spawns/0` / `children/0` are
  overridden per-test there via dedicated fixture modules so this stays
  a clean "minimal correct plugin" reference.
  """

  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "fixture",
      name: "Fixture Plugin",
      description: "Minimal correct plugin used by the contract test suite.",
      version: "0.1.0"
    }
  end
end
