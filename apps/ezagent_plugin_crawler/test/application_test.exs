defmodule EzagentPluginCrawler.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info exposes the crawler slug + name + version (通用能力层名，非业务名)" do
    info = EzagentPluginCrawler.Application.plugin_info()
    assert info.slug == "crawler"
    assert info.name == "crawler"
    assert info.version == "0.1.0"
  end

  test "children/0 is empty — 零后台 GenServer（Poller/RetentionSweeper 空转腿已删，段2）" do
    assert EzagentPluginCrawler.Application.children() == []
  end
end
