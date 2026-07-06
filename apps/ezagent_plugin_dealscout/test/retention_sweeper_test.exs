defmodule EzagentPluginDealScout.RetentionSweeperTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.RetentionSweeper

  test "prune keeps the 10 most recent batches plus any pinned older batch" do
    batches = for i <- 1..15, do: %{id: "b#{i}", seq: i}
    # b1 is the oldest, but pinned.
    kept = RetentionSweeper.prune(batches, ["b1"])
    ids = Enum.map(kept, & &1.id)

    assert "b1" in ids
    assert "b15" in ids and "b6" in ids
    refute "b2" in ids
    assert length(kept) == 11
  end

  test "prune with no pins keeps exactly the 10 most recent" do
    batches = for i <- 1..15, do: %{id: "b#{i}", seq: i}
    kept = RetentionSweeper.prune(batches, [])
    assert length(kept) == 10
    assert Enum.map(kept, & &1.id) |> Enum.sort() == Enum.map(6..15, &"b#{&1}") |> Enum.sort()
  end

  test "prune never duplicates a pinned batch that is also within the recent window" do
    batches = for i <- 1..12, do: %{id: "b#{i}", seq: i}
    kept = RetentionSweeper.prune(batches, ["b12"])
    ids = Enum.map(kept, & &1.id)
    assert Enum.count(ids, &(&1 == "b12")) == 1
    assert length(kept) == 10
  end

  test "prune keeps everything when under the retention limit" do
    batches = for i <- 1..3, do: %{id: "b#{i}", seq: i}
    assert length(RetentionSweeper.prune(batches, [])) == 3
  end
end
