defmodule Ezagent.Idempotency do
  @moduledoc """
  Idempotency — ETS-backed bounded LRU dedup set.

  Per Decision #69, `Ezagent.Invocation.dispatch/1` consults this before
  invoking a Behavior. If an idempotency key has been seen, the dispatch
  short-circuits to "already done" (return the previous result if it
  was retained, otherwise a `:duplicate` marker).

  Bounded at `@max_entries` (default 10_000) with LRU eviction by
  `Ezagent.Idempotency.Sweeper` GenServer running periodic prune.

  Owned by `EzagentActor.EtsOwner`. Sweeper is its own child of the
  application supervisor (it carries state — the prune cursor — so
  benefits from supervisor restart semantics independent of the ETS
  owner).
  """

  @table :ezagent_idempotency
  @max_entries 10_000

  def table, do: @table
  def max_entries, do: @max_entries

  @doc "Has this key been recorded? O(1)."
  @spec seen?(term()) :: boolean()
  def seen?(key) do
    case :ets.lookup(@table, key) do
      [_] -> true
      [] -> false
    end
  end

  @doc """
  Record a key with its observation timestamp. Idempotent — replaces
  any prior entry with the new timestamp (refreshes LRU position).

  Returns `:ok` regardless of whether the key was already present.
  """
  @spec record(term()) :: :ok
  def record(key) do
    :ets.insert(@table, {key, monotonic_now()})
    :ok
  end

  @doc """
  Current entry count — for the Sweeper to decide whether to prune.
  """
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @doc """
  Prune to leave at most `keep_count` of the most-recently-recorded
  entries. Called by `Ezagent.Idempotency.Sweeper`.

  Returns the number of entries evicted.
  """
  @spec prune(non_neg_integer()) :: non_neg_integer()
  def prune(keep_count) do
    all = :ets.tab2list(@table)
    excess = length(all) - keep_count

    if excess <= 0 do
      0
    else
      # Sort oldest-first (ascending ts), drop `excess` oldest entries.
      all
      |> Enum.sort_by(fn {_k, ts} -> ts end)
      |> Enum.take(excess)
      |> Enum.each(fn {k, _ts} -> :ets.delete(@table, k) end)

      excess
    end
  end

  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
