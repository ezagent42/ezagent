defmodule Ezagent.IdempotencyTest do
  use ExUnit.Case
  alias Ezagent.Idempotency

  setup do
    # Unique key prefix per test — table is shared, sweeper may run.
    prefix = "idem-test-#{System.unique_integer([:positive])}"
    {:ok, prefix: prefix}
  end

  test "seen? false for unseen keys, true after record", %{prefix: p} do
    key = "#{p}-a"
    refute Idempotency.seen?(key)
    :ok = Idempotency.record(key)
    assert Idempotency.seen?(key)
  end

  test "record/1 is idempotent (returns :ok on repeat)", %{prefix: p} do
    key = "#{p}-b"
    :ok = Idempotency.record(key)
    :ok = Idempotency.record(key)
    assert Idempotency.seen?(key)
  end

  test "size/0 increases as keys are recorded", %{prefix: p} do
    s0 = Idempotency.size()
    :ok = Idempotency.record("#{p}-c1")
    :ok = Idempotency.record("#{p}-c2")
    # At least 2 more (other tests/setup may have inserted concurrently).
    assert Idempotency.size() >= s0 + 2
  end

  test "prune/1 evicts oldest entries down to keep_count", %{prefix: p} do
    # Insert 10 keys with distinct timestamps; prune to keep 3.
    keys =
      for i <- 1..10 do
        k = "#{p}-prune-#{i}"
        :ok = Idempotency.record(k)
        # Force timestamp separation so LRU ordering is deterministic.
        Process.sleep(1)
        k
      end

    # All 10 should be present.
    assert Enum.all?(keys, &Idempotency.seen?/1)

    # Capture pre-prune total, then prune table to keep 3 of OUR keys —
    # since other tests may share the table, we instead just verify the
    # 7 oldest of our keys are gone after pruning to a small total.
    # Easier path: prune to keep only our most-recent-3.
    excess_before = Idempotency.size() - 3
    _evicted = Idempotency.prune(3)

    # Most-recent 3 of ours should survive (their ts are newest globally).
    surviving = Enum.filter(keys, &Idempotency.seen?/1)
    # We expect at most 3 of our keys (the 3 latest), and definitely the
    # very last one we recorded.
    assert length(surviving) <= 3
    assert List.last(keys) in surviving
    assert excess_before >= 7
  end
end
