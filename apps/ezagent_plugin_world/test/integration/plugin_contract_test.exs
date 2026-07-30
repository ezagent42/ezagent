defmodule EzagentPluginWorld.Integration.PluginContractTest do
  use ExUnit.Case, async: true

  test "world plugin declares its plugin contract" do
    assert EzagentPluginWorld.Application.plugin_info().slug == "world"
    assert EzagentPluginWorld.Application.kinds() == []

    # Post-#1649 (world layout editor removal): the layout `:manage` behavior is
    # gone, so World now declares NO capability behaviors. The remaining
    # non-behavior contract categories were already empty pre-removal.
    assert EzagentPluginWorld.Application.behaviors() == []

    assert EzagentPluginWorld.Application.spawns() == []
    assert EzagentPluginWorld.Application.template_classes() == []
    assert EzagentPluginWorld.Application.agent_flavors() == []
    assert EzagentPluginWorld.Application.routing_tables() == []
  end
end
