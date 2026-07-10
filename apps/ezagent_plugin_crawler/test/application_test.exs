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

  test "behaviors/0 = view cap subject + 全局 crawl 动作工具面（零人工中继 round-3，email 先例）" do
    # crawler_render 仍是 cap-only view 面（段4 D2，照 kanban S4）；
    # crawl_now/search 是 Session Kind 全局 dispatchable 行为（email plugin
    # 同款声明车道）——给 orchestrator 的官方 CLI 工具面
    # `mix ezagent session crawl_now/search`（cc 真脑两轮拒绝裸 cookie
    # stand-in 后点名要的正规 dispatch 面；CapBAC 照常裁决）。
    assert EzagentPluginCrawler.Application.behaviors() == [
             {Ezagent.Entity.Session, :crawler_render, Ezagent.ActionSet.CrawlerRender},
             {Ezagent.Entity.Session, :crawl_now, Ezagent.ActionSet.Crawler},
             {Ezagent.Entity.Session, :search, Ezagent.ActionSet.Crawler}
           ]
  end
end
