defmodule EzagentPluginCrawler.FetchTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCrawler.Fetch

  test "parse_items tags each item with the given source_type and keeps UTF-8 titles intact" do
    body = ~s([{"title":"某基金完成融资","url":"https://x/1","summary":"摘要"}])
    [item] = Fetch.parse_items(body, :public)
    assert item.title == "某基金完成融资"
    assert item.source_type == :public
    assert is_binary(item.title)
  end

  test "directed source_type is preserved for login-gated fetches" do
    body = ~s([{"title":"deal","url":"https://x/2","summary":"s"}])
    [item] = Fetch.parse_items(body, :directed)
    assert item.source_type == :directed
  end

  test "non-list / malformed body yields an empty item list (no crash)" do
    assert Fetch.parse_items("not json", :public) == []
    assert Fetch.parse_items(~s({"title":"single-object-not-list"}), :public) == []
  end

  # 2026-07-07 真出网 e2e 修正：真源形状两例（Algolia envelope + 混入非 map 条目）。
  test "parses the HN Algolia `hits` envelope (the real default public source shape)" do
    body =
      ~s({"hits":[{"title":"Show HN: deal","url":"https://x/3","points":42,"author":"a1","objectID":"9"}]})

    [item] = Fetch.parse_items(body, :public)
    assert item.title == "Show HN: deal"
    assert item.url == "https://x/3"
    # 无显式 summary → points/author 拼可读摘要（页面展示不空白）
    assert item.summary == "42 points by a1"
  end

  test "null url falls back to the HN discussion page; non-map entries are dropped (id arrays don't crash)" do
    body = ~s({"hits":[{"title":"Ask HN","url":null,"objectID":"123"}]})
    [item] = Fetch.parse_items(body, :public)
    assert item.url == "https://news.ycombinator.com/item?id=123"

    # topstories.json 形状（纯 id 数组）——真跑曾 FunctionClauseError 崩爬取路径
    assert Fetch.parse_items("[48804297, 48804298]", :public) == []
  end
end
