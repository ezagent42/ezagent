defmodule EzagentPluginFeishu.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 3 / §9 item 6).

  These assertions run against the REAL `EzagentPluginFeishu.Application`
  — the umbrella starts it at boot, so `Ezagent.Plugin.boot/1` has
  already published every declaration by the time this test runs.
  """

  use ExUnit.Case, async: true

  test "feishu plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginFeishu.Application in Ezagent.PluginRegistry.list_all(),
           "the real feishu Application.start/2 → Ezagent.Plugin.boot/1 " <>
             "path must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("feishu")
    assert info.slug == "feishu"
    assert info.name == "Feishu (Lark)"
    assert is_binary(info.version) and info.version != ""
  end

  test "feishu's behaviors/0 published FeishuOutbound on the Session core Kind" do
    # SPEC v2 §5.8 — feishu registers a Behavior on the EXISTING
    # Ezagent.Entity.Session core Kind, NOT a plugin-owned scheme.
    for action <- EzagentPluginFeishu.Behavior.FeishuOutbound.actions() do
      assert {:ok, EzagentPluginFeishu.Behavior.FeishuOutbound} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, action),
             "expected (Session, #{inspect(action)}) → FeishuOutbound"
    end
  end

  test "feishu declares NO spawns/0 — it owns no top-level scheme (SPEC v2 §5.8)" do
    # The `feishu://` scheme was deleted in PR #143. The plugin's
    # spawns/0 keeps the `use Ezagent.Plugin` default [].
    assert EzagentPluginFeishu.Application.spawns() == []
  end

  test "feishu declares NO agent_flavors/0 — it is not an agent plugin" do
    assert EzagentPluginFeishu.Application.agent_flavors() == []
  end

  test "feishu declares a :route config_surface to the Bindings page" do
    assert %{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"} =
             EzagentPluginFeishu.Application.config_surface()
  end
end
