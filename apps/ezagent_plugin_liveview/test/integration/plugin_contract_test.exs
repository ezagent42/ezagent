defmodule EzagentPluginLiveview.Integration.PluginContractTest do
  @moduledoc """
  Acceptance test for the `Ezagent.Plugin` contract migration (plugin
  authoring contract SPEC §7 row 3 / §9 item 6).

  These assertions run against the REAL
  `EzagentPluginLiveview.Application` — the umbrella starts it at boot,
  so `Ezagent.Plugin.boot/1` has already published the plugin by the
  time this test runs.
  """

  use ExUnit.Case, async: true

  test "liveview plugin is registered in Ezagent.PluginRegistry after boot" do
    assert EzagentPluginLiveview.Application in Ezagent.PluginRegistry.list_all(),
           "the real liveview Application.start/2 → Ezagent.Plugin.boot/1 " <>
             "path must self-register the plugin in PluginRegistry"

    info = Ezagent.PluginRegistry.info("liveview")
    assert info.slug == "liveview"
    assert info.name == "Admin Web UI"
    assert is_binary(info.version) and info.version != ""
  end

  test "liveview ships no Kinds / Behaviors / flavors / spawns / templates" do
    # The web UI plugin is a passive component library — every
    # contributing callback keeps its `use Ezagent.Plugin` default.
    assert EzagentPluginLiveview.Application.kinds() == []
    assert EzagentPluginLiveview.Application.behaviors() == []
    assert EzagentPluginLiveview.Application.spawns() == []
    assert EzagentPluginLiveview.Application.template_classes() == []
    assert EzagentPluginLiveview.Application.agent_flavors() == []
    assert EzagentPluginLiveview.Application.routing_tables() == []
  end

  test "liveview declares config_surface/0 nil — it IS the web UI" do
    # SPEC §6.1 — liveview has no separate config surface to open from
    # the /plugins page.
    assert EzagentPluginLiveview.Application.config_surface() == nil
  end
end
