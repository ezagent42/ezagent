defmodule Ezagent.ActionSet.DealScoutCrawl do
  @moduledoc """
  手动触发爬取的 ActionSet（`:crawl_now`）。

  轮询（`Poller`）和手动触发走同一注入路径：抓回条目经 P14
  `Ezagent.Router.dispatch/1`（`apps/ezagent_core/lib/ezagent/router.ex:79`）投
  `session.send`。action URI 用 sanctioned `Ezagent.URI.with_action`（不裸拼
  `?action=`）。

  注入点问"失败了谁知道"（Ezagent 是 router 不是 req/resp app）：dispatch 失败
  记 `[:dealscout, :inject, :error]` telemetry + warning，不 silent drop。

  seams（app env，测试注入）：
    * `:fetch_fun`（默认 `Fetch.crawl/0`）；
    * `:dispatch_fun`（默认 `Ezagent.Router.dispatch/1`）。
  """
  use Ezagent.Lifecycle
  require Logger

  @impl Ezagent.ActionSet
  def actions, do: [:crawl_now]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [{:crawl_now, "Trigger a dealscout crawl and inject results into this session."}]

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{crawl_now: Ezagent.Capability.cap(:session, __MODULE__, :crawl_now)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  @doc "抓一次，把每条线索经 dispatch 注入本会话。返回注入成功计数。"
  def handle_crawl_now(_args, ctx) do
    {:ok, items} = fetch_fun().()

    injected =
      Enum.reduce(items, 0, fn item, acc ->
        if inject(ctx.session_uri, item), do: acc + 1, else: acc
      end)

    {:ok, %{injected: injected}, []}
  end

  defp inject(session_uri, item) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    cmd = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{body: format_item(item)},
      ctx: %{reply: :ignore}
    }

    case dispatch_fun().(cmd) do
      :ok ->
        true

      other ->
        :telemetry.execute([:dealscout, :inject, :error], %{count: 1}, %{
          item: item,
          reason: other
        })

        Logger.warning("DealScout inject failed (no one else would know): #{inspect(other)}")
        false
    end
  end

  defp format_item(%{source_type: st, title: t, url: u, summary: s}),
    do: "[#{st}] #{t} — #{s} (#{u})"

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_dealscout,
        :fetch_fun,
        &EzagentPluginDealScout.Fetch.crawl/0
      )

  defp dispatch_fun,
    do: Application.get_env(:ezagent_plugin_dealscout, :dispatch_fun, &Ezagent.Router.dispatch/1)
end
