defmodule EzagentPluginDealScout.FetchTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.Fetch

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
end
