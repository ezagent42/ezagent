defmodule Ezagent.Idempotency.Sweeper do
  @moduledoc """
  Periodic LRU prune for `Ezagent.Idempotency`.

  Wakes every `@interval_ms` (default 30 seconds), and if the table
  size exceeds the high-water mark, prunes back down to `keep_count`.

  This GenServer carries state (the prune timer) and benefits from
  independent restart semantics — its supervisor child position is
  separate from `EzagentActor.EtsOwner` so a Sweeper crash doesn't take
  the ETS tables with it.

  ## High-water configuration

  `@max` is the trigger; `@keep` is the floor we prune down to. The
  gap (`@max - @keep`) absorbs burst writes between sweeps so we
  don't thrash. Phase 1 uses the defaults; Phase 2+ can override via
  `start_link(opts)` if needed.
  """

  use GenServer

  @interval_ms 30_000
  @max 10_000
  @keep 8_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    if Ezagent.Idempotency.size() > @max do
      _evicted = Ezagent.Idempotency.prune(@keep)
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @interval_ms)
end
