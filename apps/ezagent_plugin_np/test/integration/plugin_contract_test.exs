defmodule EzagentPluginNp.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract — the umbrella starts
  this plugin at boot, so `Ezagent.Plugin.boot/1` has already published
  every declaration by the time this test runs.
  """

  use ExUnit.Case, async: true

  test "np plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginNp.Application in Ezagent.PluginRegistry.list_all(),
           "the real np Application.start/2 → Ezagent.Plugin.boot/1 path " <>
             "must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("np_agent")
    assert info.slug == "np_agent"
    assert info.name == "Np Agent"
    assert is_binary(info.version) and info.version != ""
  end

  test "np's agent_flavors/0 declaration landed in Ezagent.AgentFlavorRegistry" do
    assert {:ok, %{kind: kind, template_class: template_class}} =
             Ezagent.AgentFlavorRegistry.lookup("np")

    assert kind == Ezagent.Entity.NpAgent
    assert template_class == Ezagent.PluginNp.Template.NpAgent
  end

  test "np's behaviors/0 were published to BehaviorRegistry by boot/1" do
    for action <- [:receive, :reset, :configure] do
      assert {:ok, Ezagent.Behavior.NpAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.NpAgent, action),
             "Behavior.NpAgent must be registered on (NpAgent Kind, #{action})"
    end
  end

  test "np's np.agent Template Class was published to TemplateRegistry" do
    assert {:ok, Ezagent.PluginNp.Template.NpAgent} =
             Ezagent.TemplateRegistry.lookup("np.agent")
  end

  test "np's InstanceSupervisor child is alive" do
    pid = Process.whereis(EzagentPluginNp.InstanceSupervisor)
    assert is_pid(pid) and Process.alive?(pid)
  end
end
