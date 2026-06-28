defmodule EzagentPluginPkgTest do
  @moduledoc false
  # Test fixture plugin (v1) for the plugin-package E2E gate. A minimal
  # `Ezagent.Plugin` contract module shipping one Behavior (EchoBehavior
  # v1) registered on the Agent Kind. The E2E copies this module's beam
  # into a built package dir + writes a manifest + .app and hot-loads it.

  use Ezagent.Plugin

  @impl true
  def plugin_info do
    %{slug: "pkg-test", name: "PkgTest", description: "plugin-package E2E fixture v1", version: "0.1.0"}
  end

  @impl true
  def behaviors do
    [{Ezagent.Entity.Agent, :echo_pkg, EzagentPluginPkgTest.EchoBehavior}]
  end
end

defmodule EzagentPluginPkgTest.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Ezagent.Plugin.boot(EzagentPluginPkgTest)
  end
end
