defmodule EzagentPluginContent.Kb.KbStoreTest do
  use ExUnit.Case
  alias EzagentPluginContent.Kb.KbStore

  test "search returns empty when Python unavailable" do
    result = KbStore.search("/nonexistent", "test query")
    assert result == []
  end

  test "upsert and delete never crash regardless of Python presence" do
    upsert_result = KbStore.upsert("/tmp", %{id: "test", content: "test"})
    assert match?(:ok, upsert_result) or match?({:error, _}, upsert_result)
    assert :ok = KbStore.delete("/tmp", "test")
  end
end
