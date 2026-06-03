defmodule EzagentPluginCc.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 3 / §9 item 6).

  These assertions run against the REAL `EzagentPluginCc.Application` —
  the umbrella starts it at boot, so `Ezagent.Plugin.boot/1` has already
  published every declaration by the time this test runs. No fixture
  plugin; this is the proof the contract works on the real cc plugin.
  """

  use ExUnit.Case, async: true

  test "cc plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginCc.Application in Ezagent.PluginRegistry.list_all(),
           "the real cc Application.start/2 → Ezagent.Plugin.boot/1 path " <>
             "must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("cc")
    assert info.slug == "cc"
    assert info.name == "Claude Code"
    assert is_binary(info.version) and info.version != ""
  end

  test "cc's agent_flavors/0 declaration landed in Ezagent.AgentFlavorRegistry" do
    assert {:ok, %{kind: kind, template_class: template_class}} =
             Ezagent.AgentFlavorRegistry.lookup("cc")

    # cc agents are the shared Ezagent.Entity.Agent Kind — the cc flavor
    # lives only in the `entity://agent/<ws>/cc_<name>` name prefix.
    assert kind == Ezagent.Entity.Agent
    assert template_class == Ezagent.PluginCc.Template.CcAgent
  end

  test "cc's cc.agent Template Class was published to TemplateRegistry by boot/1" do
    assert {:ok, Ezagent.PluginCc.Template.CcAgent} =
             Ezagent.TemplateRegistry.lookup("cc.agent")
  end

  test "AgentBridge domain owns the bridge registry ETS table" do
    # PR-B promoted registry lifecycle out of cc. The table existing
    # proves the domain app started its registry before cc relies on it.
    refute :ets.whereis(:ezagent_plugin_agent_bridges) == :undefined
  end

  test "cc plugin declares :flavor config_surface" do
    assert %{kind: :flavor, flavor: "cc"} = EzagentPluginCc.Application.config_surface()
  end
end
