defmodule EzagentPluginWorld.Integration.PluginContractTest do
  use ExUnit.Case, async: true

  test "world plugin declares its plugin contract" do
    assert EzagentPluginWorld.Application.plugin_info().slug == "world"
    assert EzagentPluginWorld.Application.kinds() == []

    assert EzagentPluginWorld.Application.behaviors() == [
             {Ezagent.Entity.Workspace, :manage, Ezagent.World.Behavior.Layout}
           ]

    assert EzagentPluginWorld.Application.spawns() == []
    assert EzagentPluginWorld.Application.template_classes() == []
    assert EzagentPluginWorld.Application.agent_flavors() == []
    assert EzagentPluginWorld.Application.routing_tables() == []
  end

  test "world layout manage cap shape is workspace scoped and entity granted" do
    admin_uri = Ezagent.Entity.User.admin_uri()
    workspace_uri = Ezagent.URI.workspace(:system)
    cap = Ezagent.World.LayoutBootstrap.manage_cap(admin_uri, workspace_uri)

    assert cap.kind == :workspace
    assert cap.behavior == Ezagent.World.Behavior.Layout
    assert cap.action == :manage
    assert cap.instance == workspace_uri
    assert cap.workspace_uri == workspace_uri
    assert cap.granted_by == admin_uri
    assert cap.granted_by.scheme == "entity"
  end
end
