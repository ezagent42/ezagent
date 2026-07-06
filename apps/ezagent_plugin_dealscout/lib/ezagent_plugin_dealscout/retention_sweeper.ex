defmodule EzagentPluginDealScout.RetentionSweeper do
  @moduledoc """
  DealScout 数据保留 sweeper（周期 GenServer，照 `Ezagent.Email.Inbound` 的
  `schedule` + `handle_info` 循环 + `Ezagent.Idempotency.Sweeper` 的定时清理先例）。

  仓里没有 cron 框架，`Process.send_after(self(), :sweep, interval)` 是标准写法。
  默认保留**最近 10 次爬取批次** + **pin 的批次**（`Config.pin_batch/2` 写进
  `:pinned_batches` slice），丢弃超期且未 pin 的。

  `prune/2` 是纯函数（好测、无副作用）；`sweep_once/0` 是运行期接线点（读 slice →
  `prune` → `{:set, :discoveries, kept}` 写回），失败要 telemetry，不 silent drop
  （Ezagent 是 router 不是 req/resp app）。

  seams（app env，测试注入）：`:sweep_interval_ms`（默认 1h）、`:skip_sweeper`
  （test-boot skip，照 `Poller`）。
  """
  use GenServer
  require Logger

  @keep_recent 10
  @default_interval_ms 3_600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_once()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  纯函数：保留最近 `@keep_recent`（10）批 + `pinned` 里的批次（去重，pinned 若已在
  最近窗口内不重复计）。批次按 `:seq` 降序取最近。
  """
  @spec prune([map()], [String.t()]) :: [map()]
  def prune(batches, pinned) when is_list(batches) and is_list(pinned) do
    sorted = Enum.sort_by(batches, & &1.seq, :desc)
    recent = Enum.take(sorted, @keep_recent)
    recent_ids = MapSet.new(recent, & &1.id)

    pinned_extra =
      Enum.filter(sorted, fn b -> b.id in pinned and not MapSet.member?(recent_ids, b.id) end)

    recent ++ pinned_extra
  end

  @doc """
  跑一次保留清理。运行期读发现流批次 slice → `prune` → 写回。当前发现流条目走
  `session.send` 历史注入、尚无独立 durable 批次 slice（later wiring），故此处为
  安全 no-op（返回 `:ok`），slice reader 接线后填充。**不 silent 失败**：一旦接线，
  写回失败记 `[:dealscout, :sweep, :error]` telemetry。
  """
  @spec sweep_once() :: :ok
  def sweep_once, do: :ok

  defp schedule_sweep, do: Process.send_after(self(), :sweep, interval_ms())

  defp interval_ms,
    do: Application.get_env(:ezagent_plugin_dealscout, :sweep_interval_ms, @default_interval_ms)
end
