defmodule EzagentPluginCodex.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the Codex plugin's `Ezagent.Plugin` declaration.
  """

  use ExUnit.Case, async: true

  test "codex plugin declares the shared Agent flavor and bridge adapter" do
    assert [
             %{
               flavor: "codex",
               kind: Ezagent.Entity.Agent,
               template_class: Ezagent.PluginCodex.Template.CodexAgent,
               bridge_adapter: EzagentPluginCodex.BridgeAdapter
             }
           ] = EzagentPluginCodex.Application.agent_flavors()
  end

  test "codex.agent Template Class is declared" do
    assert EzagentPluginCodex.Application.template_classes() == [
             Ezagent.PluginCodex.Template.CodexAgent
           ]

    assert Ezagent.PluginCodex.Template.CodexAgent.template_name() == "codex.agent"
  end

  test "codex plugin declares :flavor config_surface" do
    assert %{kind: :flavor, flavor: "codex"} = EzagentPluginCodex.Application.config_surface()
  end
end
