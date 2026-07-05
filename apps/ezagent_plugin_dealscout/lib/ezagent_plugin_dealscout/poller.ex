defmodule EzagentPluginDealScout.Poller do
  @moduledoc """
  周期爬取 GenServer（照 `Ezagent.Email.Inbound` 的 poll 循环）。

  仓里没有 cron 框架，`Process.send_after(self(), :poll, interval)` 是标准写法。
  seams（app env，测试注入）：
    * `:poll_interval_ms`（默认 30s）—— 定时周期；
    * `:fetch_fun`（默认 `Fetch.crawl/0`）—— 一次爬取动作。

  轮询和手动触发（`poll_once/0`）走同一条抓取路径。抓取失败是可恢复的：
  记 warning、返回 `:ok`，让下一个 tick 重试（不 silent drop —— 有日志出口）。
  """
  use GenServer
  require Logger

  @default_interval_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_once()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "跑一次爬取周期。public，operator / test 可不等 timer 触发。"
  @spec poll_once() :: :ok
  def poll_once do
    case fetch_fun().() do
      {:ok, _items} ->
        :ok

      {:error, reason} ->
        Logger.warning("DealScout.Poller: crawl failed (recoverable): #{inspect(reason)}")
        :ok
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, interval_ms())

  defp interval_ms,
    do: Application.get_env(:ezagent_plugin_dealscout, :poll_interval_ms, @default_interval_ms)

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_dealscout,
        :fetch_fun,
        &EzagentPluginDealScout.Fetch.crawl/0
      )
end
