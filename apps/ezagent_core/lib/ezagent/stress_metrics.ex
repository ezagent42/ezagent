defmodule Ezagent.StressMetrics do
  @moduledoc """
  V1 acceptance stress-test metrics collector.

  Companion to `mix ezagent.stress` (V1 stress-test plan §6). NOT part
  of any supervision tree and NOT started in a normal boot — the
  `mix ezagent.stress` task starts it explicitly and stops it at the
  end of a run. It does not affect `mix compile` / `mix test` / a
  production release; nothing references it outside the stress task.

  ## What it collects

  * **Dispatch latency** — attaches a handler to `[:ezagent, :invoke,
    :stop]` and `[:ezagent, :invoke, :error]`; accumulates every
    `duration_us` into a list, from which p50 / p99 / max are computed
    per ramp step.
  * **Persistence writes** — counts `[:ezagent, :persistence, :written]`
    events (snapshot-write rate, plan §2.4).
  * **Repo query timing** — attaches to `[:ezagent_core, :repo, :query]`
    and accumulates `queue_time` + `query_time` (DB contention,
    plan §2.3 / H1).
  * **System sampler** — a process that every `sample_ms` records
    `:erlang.system_info(:process_count)`, `:erlang.memory/0`, the
    KindRegistry / ReadyGate ETS sizes and the BEAM scheduler
    utilisation.

  All counters live in an Agent so the stress task can `reset/0` between
  ramp steps and `snapshot/0` at the end of each hold window.
  """

  use Agent

  @handler_id "ezagent-stress-metrics"
  @invoke_events [[:ezagent, :invoke, :stop], [:ezagent, :invoke, :error]]
  @repo_event [:ezagent_core, :repo, :query]
  @persist_event [:ezagent, :persistence, :written]

  # --- lifecycle ---------------------------------------------------------

  @doc "Start the collector + attach telemetry handlers. Idempotent."
  def start_link(_opts \\ []) do
    case Agent.start_link(&initial_state/0, name: __MODULE__) do
      {:ok, pid} ->
        attach_handlers()
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  @doc "Detach handlers + stop the collector."
  def stop do
    :telemetry.detach(@handler_id)
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    :ok
  end

  defp initial_state do
    %{
      invoke_durations_us: [],
      invoke_count: 0,
      invoke_error_count: 0,
      repo_query_count: 0,
      repo_queue_time_us: [],
      repo_query_time_us: [],
      persist_count: 0
    }
  end

  defp attach_handlers do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @invoke_events ++ [@repo_event, @persist_event],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:ezagent, :invoke, :stop], %{duration_us: us}, _meta, _cfg) do
    Agent.cast(__MODULE__, fn s ->
      %{
        s
        | invoke_durations_us: [us | s.invoke_durations_us],
          invoke_count: s.invoke_count + 1
      }
    end)
  end

  def handle_event([:ezagent, :invoke, :error], %{duration_us: us}, _meta, _cfg) do
    Agent.cast(__MODULE__, fn s ->
      %{
        s
        | invoke_durations_us: [us | s.invoke_durations_us],
          invoke_count: s.invoke_count + 1,
          invoke_error_count: s.invoke_error_count + 1
      }
    end)
  end

  def handle_event(@repo_event, measurements, _meta, _cfg) do
    # ecto telemetry timings are native units — convert to microseconds.
    queue = native_to_us(Map.get(measurements, :queue_time, 0))
    query = native_to_us(Map.get(measurements, :query_time, 0))

    Agent.cast(__MODULE__, fn s ->
      %{
        s
        | repo_query_count: s.repo_query_count + 1,
          repo_queue_time_us: [queue | s.repo_queue_time_us],
          repo_query_time_us: [query | s.repo_query_time_us]
      }
    end)
  end

  def handle_event(@persist_event, _measurements, _meta, _cfg) do
    Agent.cast(__MODULE__, fn s -> %{s | persist_count: s.persist_count + 1} end)
  end

  def handle_event(_event, _m, _meta, _cfg), do: :ok

  defp native_to_us(0), do: 0
  defp native_to_us(native), do: System.convert_time_unit(native, :native, :microsecond)

  # --- aggregation -------------------------------------------------------

  @doc "Reset all counters (between ramp steps)."
  def reset do
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  @doc """
  Snapshot of the aggregated counters since the last `reset/0`.

  Returns a map with dispatch latency percentiles (microseconds),
  counts, and Repo query timings.
  """
  def snapshot do
    Agent.get(__MODULE__, fn s ->
      %{
        invoke_count: s.invoke_count,
        invoke_error_count: s.invoke_error_count,
        dispatch_p50_us: percentile(s.invoke_durations_us, 50),
        dispatch_p99_us: percentile(s.invoke_durations_us, 99),
        dispatch_max_us: max_of(s.invoke_durations_us),
        repo_query_count: s.repo_query_count,
        repo_queue_p50_us: percentile(s.repo_queue_time_us, 50),
        repo_queue_p99_us: percentile(s.repo_queue_time_us, 99),
        repo_query_p50_us: percentile(s.repo_query_time_us, 50),
        repo_query_p99_us: percentile(s.repo_query_time_us, 99),
        persist_count: s.persist_count
      }
    end)
  end

  defp percentile([], _p), do: 0

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    n = length(sorted)
    idx = min(n - 1, max(0, round(p / 100 * n) - 1))
    Enum.at(sorted, idx)
  end

  defp max_of([]), do: 0
  defp max_of(list), do: Enum.max(list)

  # --- system sampling ---------------------------------------------------

  @doc """
  One point-in-time system sample: process count, memory breakdown,
  ETS sizes, scheduler utilisation.

  `scheduler_util` requires `:scheduler.sample_all/0` to have been
  called earlier (the caller wraps a hold window in
  `:scheduler.utilization/1`); here we only read the cheap counters.
  """
  def system_sample do
    mem = :erlang.memory()

    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      mem_total_mb: bytes_to_mb(mem[:total]),
      mem_processes_mb: bytes_to_mb(mem[:processes]),
      mem_ets_mb: bytes_to_mb(mem[:ets]),
      mem_binary_mb: bytes_to_mb(mem[:binary]),
      rss_mb: rss_mb(),
      kind_registry_size: ets_size(Ezagent.KindRegistry),
      ready_gate_size: ets_size(:ezagent_ready_gate),
      run_queue: :erlang.statistics(:total_run_queue_lengths)
    }
  end

  defp bytes_to_mb(nil), do: 0.0
  defp bytes_to_mb(b), do: Float.round(b / 1_048_576, 1)

  # OS-level RSS for the BEAM process. `:erlang.memory(:total)` is the
  # BEAM-managed heap; RSS includes the VM itself + unreclaimed pages.
  defp rss_mb do
    case :os.type() do
      {:unix, _} ->
        pid = System.pid()

        case System.cmd("ps", ["-o", "rss=", "-p", pid], stderr_to_stdout: true) do
          {out, 0} ->
            out |> String.trim() |> String.to_integer() |> Kernel./(1024) |> Float.round(1)

          _ ->
            0.0
        end

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  # KindRegistry is a stdlib `Registry` (partitioned ETS). `Registry`
  # exposes a `count/1`; ReadyGate is a plain named ETS table.
  defp ets_size(Ezagent.KindRegistry) do
    Registry.count(Ezagent.KindRegistry)
  rescue
    _ -> 0
  end

  defp ets_size(table) when is_atom(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      n -> n
    end
  end
end
