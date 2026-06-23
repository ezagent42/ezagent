defmodule EzagentPluginCodex.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the Codex plugin's `Ezagent.Plugin` declaration.
  """

  use ExUnit.Case, async: true

  test "codex plugin declares agent flavors and bridge adapters" do
    assert [
             %{
               flavor: "codex",
               kind: Ezagent.Entity.Agent,
               template_class: Ezagent.PluginCodex.Template.CodexAgent,
               bridge_adapter: EzagentPluginCodex.BridgeAdapter
             },
             %{
               flavor: "codex-remote",
               kind: Ezagent.Entity.Agent,
               template_class: Ezagent.PluginCodex.Template.CodexRemoteAgent,
               bridge_adapter: EzagentPluginCodex.CodexRemoteBridgeAdapter
             }
           ] = EzagentPluginCodex.Application.agent_flavors()
  end

  test "Template Classes are declared" do
    assert Ezagent.PluginCodex.Template.CodexAgent in EzagentPluginCodex.Application.template_classes()
    assert Ezagent.PluginCodex.Template.CodexRemoteAgent in EzagentPluginCodex.Application.template_classes()
    assert Ezagent.PluginCodex.Template.CodexAgent.template_name() == "codex.agent"
    assert Ezagent.PluginCodex.Template.CodexRemoteAgent.template_name() == "codex_remote.agent"
  end

  test "codex plugin declares :flavor config_surface" do
    assert %{kind: :flavor, flavor: "codex"} = EzagentPluginCodex.Application.config_surface()
  end
end
