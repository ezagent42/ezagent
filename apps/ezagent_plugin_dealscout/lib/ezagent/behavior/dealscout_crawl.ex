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

  ## source/token 自动分流（Stage B 接线，live 路径）

  `:crawl_now` 走 `Fetch.crawl_auto/1`（source 有无自动分流的决策点，spec
  §3.1）：定向源清单从 **config slice** 的 `:sources` key 读（framework 注入的
  `ctx[:read]` reader；写入侧是 `Config.set_sources/2` 的 `{:set, ...}`
  effect）——配了源走"公开 + 定向（有 token）"，没配纯公开。`:search` 不走
  crawl_auto（它是 query 参数化检索，走 `search_fun` 的独立腿）。

  seams（app env，测试注入）：
    * `:fetch_fun`（默认 `Fetch.crawl_auto/1`，收 sources 列表）；
    * `:dispatch_fun`（默认 `Ezagent.Router.dispatch/1`）。
  """
  use Ezagent.Lifecycle
  require Logger

  # 内容协议标记（像 kanban 的 __done__）：routing 规则按文本命中，不带任何实例 URI。
  @update_signal "__dealscout_update__"

  @doc "更新信号的内容标记（Definition routing_rules 的 `text_contains` 靶子）。"
  @spec update_signal() :: String.t()
  def update_signal, do: @update_signal

  # `action/2` 宏声明（照 `Ezagent.ActionSet.Kanban`）：`actions/0` /
  # `cap_subjects/0` / `required_caps/0` / `interface/0` 全由宏生成——
  # cap-check 形状留在 core 契约里（invariant p4：插件不手写 `cap_subjects`）。
  # 生成的 needed-cap kind 轴是 `:any`：运行时（`Kind.Runtime` check 11b）按
  # 目标宿主 type_name 替换后授权（硬写 kind 会让 role×flavor 路的 recipe
  # 铸出的 held cap 必拒——照 kanban 的注释先例）。
  action(:crawl_now,
    args: %{},
    returns: %{injected: :integer},
    caps: [:crawl_now],
    modes: [:call],
    description: "Trigger a dealscout crawl and inject results into this session."
  )

  action(:search,
    args: %{query: :string, source: {:option, :string}},
    returns: %{injected: :integer},
    caps: [:search],
    modes: [:call],
    description: "Run a dealscout active search (query) and inject results into this session."
  )

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  @doc """
  抓一次（`Fetch.crawl_auto/1`，sources 从 config slice 读 —— moduledoc
  §source/token 自动分流），把每条线索经 dispatch 注入本会话；注入了新线索
  （injected > 0）时再 emit 一条更新信号（`update_signal/0`，moduledoc
  §更新信号）。返回注入成功计数。
  """
  def handle_crawl_now(_args, ctx) do
    {:ok, items} = fetch_fun().(config_sources(ctx))

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

  # 定向源清单从 config slice 读（framework 经 `ctx[:read]` 注入 slice reader，
  # plugin 作者不见底层存储）。无 reader（如裸测试 ctx）降级为 []（纯公开爬）。
  defp config_sources(ctx) do
    case ctx[:read] do
      read when is_function(read, 2) ->
        EzagentPluginDealScout.Config.normalize_sources(read.(:sources, []))

      _ ->
        []
    end
  end

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_dealscout,
        :fetch_fun,
        &EzagentPluginDealScout.Fetch.crawl_auto/1
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
