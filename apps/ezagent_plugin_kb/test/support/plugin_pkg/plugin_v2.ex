defmodule EzagentPluginPkgTestV2 do
  @moduledoc false
  # Test fixture plugin (v2) for the plugin-package E2E SWAP leg. Same
  # slug as v1 ("pkg-test") but its EchoBehavior returns version "v2".

  use Ezagent.Plugin

  @impl true
  def plugin_info do
    %{slug: "pkg-test", name: "PkgTest", description: "plugin-package E2E fixture v2", version: "0.2.0"}
  end

  @impl true
  def behaviors do
    [{Ezagent.Entity.Agent, :echo_pkg, EzagentPluginPkgTestV2.EchoBehavior}]
  end
end

defmodule EzagentPluginPkgTestV2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Ezagent.Plugin.boot(EzagentPluginPkgTestV2)
  end
end
