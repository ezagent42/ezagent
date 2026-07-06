defmodule Ezagent.ActionSet.DealScoutCrawl do
  @moduledoc """
  手动触发爬取的 ActionSet（`:crawl_now`）。

  轮询（`Poller`）和手动触发走同一注入路径：抓回条目经 P14
  `Ezagent.Router.dispatch/1`（`apps/ezagent_core/lib/ezagent/router.ex:79`）投
  `session.send`。action URI 用 sanctioned `Ezagent.URI.with_action`（不裸拼
  `?action=`）。

  注入点问"失败了谁知道"（Ezagent 是 router 不是 req/resp app）：dispatch 失败
  记 `[:dealscout, :inject, :error]` telemetry + warning，不 silent drop。

  ## 更新信号（内容协议，像 kanban 的 `__done__`）

  爬完/搜完**注入了新线索**（injected > 0）时，除了逐条 `session.send` 注入，
  再 emit 一条**内容标记**消息 `update_signal/0`（`"__dealscout_update__"`）到
  同一会话。它是 agent 间的**内容协议**：DealScout Definition（Stage D，纯配置）
  的 routing_rules 用 `text_contains("__dealscout_update__")` matcher
  （`apps/ezagent_core/lib/ezagent/routing/matcher.ex:74`）命中它 → receiver
  `{:role, <hello 页面 agent 角色>}` → hello 的 agent 收信号后更新 json-render
  页。**零实例 URI、不数据直推、dealscout 自己不渲染**——显示是 hello 的活。
  信号 dispatch 失败同样 fail-loud（`[:dealscout, :update_signal, :error]`）。

  seams（app env，测试注入）：
    * `:fetch_fun`（默认 `Fetch.crawl/0`）；
    * `:dispatch_fun`（默认 `Ezagent.Router.dispatch/1`）。
  """
  use Ezagent.Lifecycle
  require Logger

  # 内容协议标记（像 kanban 的 __done__）：routing 规则按文本命中，不带任何实例 URI。
  @update_signal "__dealscout_update__"

  @doc "更新信号的内容标记（Definition routing_rules 的 `text_contains` 靶子）。"
  @spec update_signal() :: String.t()
  def update_signal, do: @update_signal

  @impl Ezagent.ActionSet
  def actions, do: [:crawl_now, :search]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [
      {:crawl_now, "Trigger a dealscout crawl and inject results into this session."},
      {:search, "Run a dealscout active search (query) and inject results into this session."}
    ]

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{
      crawl_now: Ezagent.Capability.cap(:session, __MODULE__, :crawl_now),
      search: Ezagent.Capability.cap(:session, __MODULE__, :search)
    }

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  @doc """
  抓一次，把每条线索经 dispatch 注入本会话；注入了新线索（injected > 0）时
  再 emit 一条更新信号（`update_signal/0`，moduledoc §更新信号）。返回注入成功计数。
  """
  def handle_crawl_now(_args, ctx) do
    {:ok, items} = fetch_fun().()

    injected =
      Enum.reduce(items, 0, fn item, acc ->
        if inject(ctx.session_uri, item), do: acc + 1, else: acc
      end)

    emit_update_signal(ctx.session_uri, injected, "crawl")
    {:ok, %{injected: injected}, []}
  end

  @doc """
  主动搜索（`:search`）——把 `%{query, source}` 参数化抓取的候选注入发现流，标记为
  搜索结果（`source: "search:<source>"`，hello 侧分类展示时可辨来源）。
  走跟 `:crawl_now` 完全相同的 P14 注入路径，失败同样 fail-loud（telemetry）；
  注入了新线索时同样 emit 更新信号（`update_signal/0`）。

  seam（app env，测试注入）：`:search_fun`（默认 `default_search/1`，参数化打
  `Fetch.fetch/3`）。
  """
  def handle_search(%{query: query} = args, ctx) do
    {:ok, items} = search_fun().(query)
    source = Map.get(args, :source, "public")

    injected =
      Enum.reduce(items, 0, fn item, acc ->
        tagged = Map.put(item, :source, "search:#{source}")
        if inject(ctx.session_uri, tagged), do: acc + 1, else: acc
      end)

    emit_update_signal(ctx.session_uri, injected, "search")
    {:ok, %{injected: injected}, []}
  end

  # 内容协议更新信号：injected > 0 才发（没新线索不打扰 hello 的页面 agent）。
  # body 只有标记 + 计数 + 来源腿——零实例 URI，routing 靠 text_contains 命中。
  defp emit_update_signal(_session_uri, 0, _origin), do: :ok

  defp emit_update_signal(session_uri, injected, origin) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    cmd = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{body: "#{@update_signal} 新线索 #{injected} 条（#{origin}）"},
      ctx: %{reply: :ignore}
    }

    case dispatch_fun().(cmd) do
      :ok ->
        :ok

      other ->
        :telemetry.execute([:dealscout, :update_signal, :error], %{count: 1}, %{
          injected: injected,
          origin: origin,
          reason: other
        })

        Logger.warning(
          "DealScout update signal dispatch failed (no one else would know): #{inspect(other)}"
        )

        :ok
    end
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

  defp format_item(%{source_type: st, title: t, url: u, summary: s} = item) do
    origin = Map.get(item, :source)
    origin_tag = if origin in [nil, ""], do: "", else: " {#{origin}}"
    "[#{st}]#{origin_tag} #{t} — #{s} (#{u})"
  end

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_dealscout,
        :fetch_fun,
        &EzagentPluginDealScout.Fetch.crawl/0
      )

  defp search_fun,
    do: Application.get_env(:ezagent_plugin_dealscout, :search_fun, &default_search/1)

  # 参数化搜索：把 query 转成对公开搜索源的检索（HN Algolia，公开、无 token），
  # 结果标 `:public`。指定源检索走 `Fetch.fetch_directed/2`（Task 5 token 注入）。
  defp default_search(query),
    do: EzagentPluginDealScout.Fetch.fetch(search_url(query), [], :public)

  defp search_url(query),
    do: "https://hn.algolia.com/api/v1/search?query=#{URI.encode(query)}"

  defp dispatch_fun,
    do: Application.get_env(:ezagent_plugin_dealscout, :dispatch_fun, &Ezagent.Router.dispatch/1)
end
