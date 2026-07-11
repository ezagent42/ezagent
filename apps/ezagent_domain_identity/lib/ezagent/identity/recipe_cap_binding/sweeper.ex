defmodule Ezagent.Identity.RecipeCapBinding.Sweeper do
  @moduledoc """
  Supervised GC for Phase 3 recipe-cap binding tombstones.

  Definitive materialization failures leave a version-conditional tombstone so
  no startup reader can absorb the abandoned artifacts. This sweeper retains
  that forensic marker for a bounded interval (24 hours by default), then
  scrubs its issued-artifact payload while retaining the version ledger that
  prevents stale-compensation ABA. `init/1` performs no DB work; the first pass
  runs only after the configured interval, keeping application boot and SQL
  sandbox setup safe.
  """
  use GenServer

  require Logger

  alias Ezagent.Identity.RecipeCapBinding

  @default_interval_ms 60 * 60 * 1000
  @default_retention_ms 24 * 60 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    interval_ms = opts[:interval_ms] || configured_interval_ms()
    retention_ms = opts[:retention_ms] || configured_retention_ms()
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms, retention_ms: retention_ms}}
  end

  @impl true
  def handle_info(:sweep, state) do
    run_sweep(DateTime.utc_now(), state.retention_ms)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @doc "Run one synchronous GC pass relative to `now`; primarily an ops/test seam."
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()}
  def sweep(%DateTime{} = now) do
    {:ok, run_sweep(now, configured_retention_ms())}
  end

  defp run_sweep(now, retention_ms) do
    cutoff = DateTime.add(now, -retention_ms, :millisecond)
    count = RecipeCapBinding.prune_tombstoned(cutoff)

    if count > 0 do
      Logger.info("recipe-cap binding GC pruned #{count} expired tombstone(s)")
    end

    count
  rescue
    error ->
      Logger.warning("recipe-cap binding GC failed; retrying next tick: #{inspect(error)}")
      0
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp configured_interval_ms do
    Application.get_env(
      :ezagent_domain_identity,
      :recipe_cap_binding_gc_interval_ms,
      @default_interval_ms
    )
  end

  defp configured_retention_ms do
    Application.get_env(
      :ezagent_domain_identity,
      :recipe_cap_binding_gc_retention_ms,
      @default_retention_ms
    )
  end
end
