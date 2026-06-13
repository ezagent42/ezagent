defmodule EzagentPluginCurlAgent.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 2 / §9 item 6).

  These assertions run against the REAL
  `EzagentPluginCurlAgent.Application` — the umbrella starts it at
  boot, so `Ezagent.Plugin.boot/1` has already published every
  declaration by the time this test runs. No fixture plugin; this is
  the proof the contract works on the real curl_agent plugin.
  """

  use ExUnit.Case, async: true

  test "curl_agent plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginCurlAgent.Application in Ezagent.PluginRegistry.list_all(),
           "the real curl_agent Application.start/2 → Ezagent.Plugin.boot/1 " <>
             "path must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("curl_agent")
    assert info.slug == "curl_agent"
    assert info.name == "Curl Agent"
    assert is_binary(info.version) and info.version != ""
  end

  test "curl's agent_flavors/0 declaration landed in Ezagent.AgentFlavorRegistry" do
    assert {:ok, %{kind: kind, template_class: template_class}} =
             Ezagent.AgentFlavorRegistry.lookup("curl")

    # PR-6 — the curl flavor now resolves to the UNIFIED Entity.Agent Kind.
    assert kind == Ezagent.Entity.Agent
    assert template_class == Ezagent.PluginCurlAgent.Template
  end

  test "curl's :in_process_sync bridge adapter is registered for the curl flavor" do
    # PR-6 — the curl transport adapter registers UP at boot (symmetric to
    # cc/codex). `:in_process_sync` is the no-subprocess/no-WS class.
    assert {:ok, EzagentPluginCurlAgent.BridgeAdapter} =
             Ezagent.AgentBridge.AdapterRegistry.lookup("curl")

    assert EzagentPluginCurlAgent.BridgeAdapter.transport_class() == :in_process_sync
  end

  test "curl's behaviors/0 were published to BehaviorRegistry by boot/1" do
    # PR-6 — the curl STATE Behavior is reparented onto Entity.Agent (NEW
    # agents) AND kept bound on the legacy Entity.CurlAgent Kind (existing
    # agents, through the PR-7 rollback window).
    for action <- Ezagent.Behavior.CurlAgent.actions() do
      assert {:ok, Ezagent.Behavior.CurlAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, action),
             "expected (Entity.Agent, #{inspect(action)}) → Behavior.CurlAgent"

      assert {:ok, Ezagent.Behavior.CurlAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.CurlAgent, action),
             "expected legacy (Entity.CurlAgent, #{inspect(action)}) → Behavior.CurlAgent"
    end
  end

  test "curl's curl.agent Template Class was published to TemplateRegistry" do
    assert {:ok, Ezagent.PluginCurlAgent.Template} =
             Ezagent.TemplateRegistry.lookup("curl.agent")
  end
end
