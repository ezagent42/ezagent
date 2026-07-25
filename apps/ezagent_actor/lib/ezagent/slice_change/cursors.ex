defmodule Ezagent.SliceChange.Cursors do
  @moduledoc """
  Per-URI monotonic cursor for `Ezagent.SliceChange.emit/1`'s
  security-minimal broadcast envelope (PR-N3 codex r2 HIGH-1, Allen
  2026-05-25).

  ## Why a cursor on the broadcast envelope

  The security-minimal envelope (see
  `Ezagent.SliceChange` moduledoc §"Broadcast envelope shape") strips
  slice content. Subscribers re-fetch via `Ezagent.Kind.get_slice/2`
  to read the actual slice. Between "I received cursor N" and "I
  fetched the slice" there's a window where additional slice mutations
  may have committed — the cursor lets a subscriber detect this
  ("I last fetched at cursor X; this event is cursor Y; if Y > X+1
  then I missed events").

  The cursor is also a low-cost ordering hint for diagnostic logs and
  out-of-order delivery detection. It's NOT a persisted log primary
  key (that's `Ezagent.MessageStore` / `Ezagent.Kind.Snapshot`); it
  starts at 1 after EtsOwner restart and never reaches "wrap-around"
  in any practical timescale (atomic 64-bit ETS counter).

  ## Backing store

  Single `:set` ETS table `:ezagent_slice_change_cursors` keyed by URI
  string. `next/1` uses `:ets.update_counter/4` with a defaulted entry,
  giving lock-free atomic increment under concurrent emitters. The
  table is owned by `EzagentActor.EtsOwner` (same lifecycle as every
  other reliability primitive table).

  Reset-on-restart is intentional: cursors are transport-level. Per
  `feedback_let_it_crash_no_workarounds`, post-restart subscribers
  re-sync via cap-gated `Kind.get_slice/2`; the cursor wraps back to
  1 and that's fine — subscribers that need "did I miss any?"
  semantics across restarts wire `EzagentActor.EtsOwner` start as the
  observable epoch boundary.
  """

  @table :ezagent_slice_change_cursors

  @doc "ETS table name owned by EzagentActor.EtsOwner."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Atomic-increment + return the next cursor for `uri`.

  First call for a URI returns 1; each subsequent call returns the
  prior value + 1. Per-URI; counters do NOT share across URIs.
  """
  @spec next(URI.t() | String.t()) :: pos_integer()
  def next(%URI{} = uri), do: next(URI.to_string(uri))

  def next(uri_str) when is_binary(uri_str) do
    # `:ets.update_counter/4` with default `{key, 0}` is the canonical
    # "atomic increment, create if missing" idiom. The {2, 1} update_op
    # adds 1 to position 2 (the counter) and returns the NEW value.
    # First call: default {uri_str, 0} inserted, then incremented to 1,
    # returns 1. Subsequent calls: returns 2, 3, 4, ...
    :ets.update_counter(@table, uri_str, {2, 1}, {uri_str, 0})
  end

  @doc """
  Test-only: reset all cursors. NOT for production code paths.

  Used by `apps/ezagent_core/test/invariants/slice_change_event_carries_no_slice_content_test.exs`
  if a test wants to assert a known starting cursor; the production
  path never calls this.
  """
  @spec reset_all() :: :ok
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end
end
