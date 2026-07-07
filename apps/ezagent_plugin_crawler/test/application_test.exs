defmodule EzagentPluginCrawler.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info exposes the crawler slug + name + version (通用能力层名，非业务名)" do
    info = EzagentPluginCrawler.Application.plugin_info()
    assert info.slug == "crawler"
    assert info.name == "crawler"
    assert info.version == "0.1.0"
  end

  test "children/0 returns a supervisable list" do
    assert is_list(EzagentPluginCrawler.Application.children())
  end
end
