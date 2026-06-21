defmodule EzagentPluginWorld.Integration.PluginContractTest do
  use ExUnit.Case, async: true

  test "world plugin declares an empty PR-0 contract" do
    assert EzagentPluginWorld.Application.plugin_info().slug == "world"
    assert EzagentPluginWorld.Application.kinds() == []
    assert EzagentPluginWorld.Application.behaviors() == []
    assert EzagentPluginWorld.Application.spawns() == []
    assert EzagentPluginWorld.Application.template_classes() == []
    assert EzagentPluginWorld.Application.agent_flavors() == []
    assert EzagentPluginWorld.Application.routing_tables() == []
  end
end
