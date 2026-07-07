defmodule EzagentPluginCrawler.Poller do
  @moduledoc """
  周期爬取 GenServer（照 `Ezagent.Email.Inbound` 的 poll 循环）。

  仓里没有 cron 框架，`Process.send_after(self(), :poll, interval)` 是标准写法。
  seams（app env，测试注入）：
    * `:poll_interval_ms`（默认 30s）—— 定时周期；
    * `:fetch_fun`（默认 `Fetch.crawl_auto/1`，收 sources 列表）—— 一次爬取动作；
    * `:sources`（默认 `[]`）—— 定向源清单（每项 `%{url, source}`）。

  轮询走跟手动触发（`Crawler` `:crawl_now`）同一个 `Fetch.crawl_auto/1`
  分流决策点（配了源 = 公开 + 定向；没配 = 纯公开）。差异只在 sources 的来源：
  ActionSet 路有 session ctx，从 **config slice** 读（`ctx[:read]`）；Poller 是
  无 session 的全局 timer，读 **operator 级 app env `:sources`**（同形状，经
  `Config.normalize_sources/1` 归一）。

  抓取失败是可恢复的：记 warning、返回 `:ok`，让下一个 tick 重试（不 silent
  drop —— 有日志出口）。
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

  @doc "跑一次爬取周期（`crawl_auto` 分流：app-env `:sources` 有源加抓定向）。public，operator / test 可不等 timer 触发。"
  @spec poll_once() :: :ok
  def poll_once do
    case fetch_fun().(configured_sources()) do
      {:ok, _items} ->
        :ok

      {:error, reason} ->
        Logger.warning("Crawler.Poller: crawl failed (recoverable): #{inspect(reason)}")
        :ok
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, interval_ms())

  defp interval_ms,
    do: Application.get_env(:ezagent_plugin_crawler, :poll_interval_ms, @default_interval_ms)

  # operator 级定向源清单（moduledoc：Poller 无 session ctx，读 app env 而非
  # config slice）。归一同一形状，坏条目丢弃。
  defp configured_sources do
    EzagentPluginCrawler.Config.normalize_sources(
      Application.get_env(:ezagent_plugin_crawler, :sources, [])
    )
  end

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_crawler,
        :fetch_fun,
        &EzagentPluginCrawler.Fetch.crawl_auto/1
      )
end
