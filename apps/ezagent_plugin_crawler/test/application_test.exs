defmodule EzagentPluginCrawler.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info exposes the crawler slug + name + version (通用能力层名，非业务名)" do
    info = EzagentPluginCrawler.Application.plugin_info()
    assert info.slug == "crawler"
    assert info.name == "crawler"
    assert info.version == "0.1.0"
  end

  test "children/0 只有页面发布腿的 Task.Supervisor — 零周期后台（Poller/RetentionSweeper 空转腿已删，段2；段4 加发布 Task 监督）" do
    assert EzagentPluginCrawler.Application.children() == [
             {Task.Supervisor, name: EzagentPluginCrawler.TaskSupervisor}
           ]
  end

  test "behaviors/0 declares ONLY the {Session, :crawler_render} view cap subject（段4 D2，照 kanban S4）" do
    assert EzagentPluginCrawler.Application.behaviors() == [
             {Ezagent.Entity.Session, :crawler_render, Ezagent.ActionSet.CrawlerRender}
           ]
  end
end
