defmodule EzagentPluginEcho.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 2 / §9 item 6).

  These assertions run against the REAL `EzagentPluginEcho.Application`
  — the umbrella starts it at boot, so `Ezagent.Plugin.boot/1` has
  already published every declaration by the time this test runs. No
  fixture plugin; this is the proof the contract works on the real
  echo plugin.
  """

  use ExUnit.Case, async: true

  test "echo plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginEcho.Application in Ezagent.PluginRegistry.list_all(),
           "the real echo Application.start/2 → Ezagent.Plugin.boot/1 path " <>
             "must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("echo")
    assert info.slug == "echo"
    assert info.name == "Echo"
    assert is_binary(info.version) and info.version != ""
  end

  test "echo's agent_flavors/0 declaration landed in Ezagent.AgentFlavorRegistry" do
    assert {:ok, %{kind: kind, template_class: template_class}} =
             Ezagent.AgentFlavorRegistry.lookup("echo")

    assert kind == Ezagent.Entity.Echo
    assert template_class == Ezagent.PluginEcho.Template.EchoAgent
  end

  test "echo's behaviors/0 were published to BehaviorRegistry by boot/1" do
    assert {:ok, Ezagent.Behavior.Echo} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Echo, :say)

    assert {:ok, Ezagent.Behavior.Echo} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Echo, :receive)
  end

  test "echo's echo.agent Template Class was published to TemplateRegistry" do
    assert {:ok, Ezagent.PluginEcho.Template.EchoAgent} =
             Ezagent.TemplateRegistry.lookup("echo.agent")
  end
end
