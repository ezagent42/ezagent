defmodule EzagentPluginDealScout.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info exposes dealscout slug + name + version" do
    info = EzagentPluginDealScout.Application.plugin_info()
    assert info.slug == "dealscout"
    assert info.name == "dealscout"
    assert info.version == "0.1.0"
  end

  test "children/0 returns a supervisable list" do
    assert is_list(EzagentPluginDealScout.Application.children())
  end
end
