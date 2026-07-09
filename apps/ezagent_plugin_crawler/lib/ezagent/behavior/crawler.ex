defmodule Ezagent.ActionSet.Crawler do
  @moduledoc """
  手动触发爬取的 ActionSet（`:crawl_now` / `:search`）。

  ## 分层（2026-07-07 rename 拍板）

  本模块属 **通用能力层**（`:ezagent_plugin_crawler`，爬取能力，与业务无关）；
  "dealscout" 是**组合本能力的 socialware 的名字**（纯配置，deploy-seed 包
  `apps/ezagent_web/priv/socialware_seed/dealscout/manifest.yaml`）。判据：
  "换个 socialware 还能原样用吗"——crawl_now/search/信号 emit/page 直呼腿
  都能，留在这里；业务 persona prompt、routing 规则等业务件留在 manifest
  YAML / Recipes 的 dealscout 命名侧。

  轮询（`Poller`）和手动触发走同一注入路径：抓回条目经 P14 的 legacy 路
  `Ezagent.Invocation.dispatch/1`（本模块构造 `%Ezagent.Invocation{}`；
  `Ezagent.Router.dispatch/1` 只收 `%Cmd{}`，2026-07-07 真 e2e 修正）投
  `session.send`。action URI 用 sanctioned `Ezagent.URI.with_action`（不裸拼
  `?action=`）。

  注入点问"失败了谁知道"（Ezagent 是 router 不是 req/resp app）：dispatch 失败
  记 `[:crawler, :inject, :error]` telemetry + warning，不 silent drop。

  ## 更新信号（内容协议，像 kanban 的 `__done__`）

  爬完/搜完**注入了新线索**（injected > 0）时，除了逐条 `session.send` 注入，
  再 emit 一条**内容标记**消息（缺省 `update_signal/0` = `"__dealscout_update__"`，
  socialware 可经 config slice 的 `:update_signal` key 覆写——见
  `@update_signal` 注释）到同一会话。它是 agent 间的**内容协议**：dealscout
  Definition（纯配置）的 routing_rules 用 `text_contains("__dealscout_update__")`
  matcher（`apps/ezagent_core/lib/ezagent/routing/matcher.ex:74`）命中它 →
  receiver `{:role, <hello 页面 agent 角色>}` → hello 的 agent 收信号后更新
  json-render 页。**零实例 URI、不数据直推、本插件自己不渲染**——显示是
  hello 的活。信号 dispatch 失败同样 fail-loud（`[:crawler, :update_signal, :error]`）。

  ## 页面重建的直接 dispatch 腿（v2，绕 #1201 ②）

  真 e2e 实测：上面的 chat 信号腿到 native page 成员是断的 —— canonical
  `agent.receive` 只会把投递塞 bridge，native flavor 无 bridge 必丢。所以在
  发完更新信号之后，再走一条 **kanban caller-dispatch 同款**的直接腿
  （#1190 r2 pm→board 已证）：按 `role_name` facet 从 `:session` sibling
  slice（`reads_siblings [:session]`，本 handler 跑在 session Kind 上，不能
  `Kind.get_slice` 自呼死锁）解析出 `page_role/0`（`"page"`）成员的实例
  URI，直接 dispatch `:refresh_page`（`Ezagent.ActionSet
  .DealScoutPageRefreshAlt`）—— dispatch 按 action 在实例行为集解析直接跑
  handler，不经 bridge。找不到 page 成员 / dispatch 失败 → fail-loud
  （`[:crawler, :page_refresh, :error]` telemetry + warning），不静默。
  chat 信号腿保留（会话内可见的声明式痕迹 + A① 落地后回切 receive 式的靶子）。

  ## source/token 自动分流（Stage B 接线，live 路径）

  `:crawl_now` 走 `Fetch.crawl_auto/1`（source 有无自动分流的决策点，spec
  §3.1）：定向源清单从 **config slice** 的 `:sources` key 读（framework 注入的
  `ctx[:read]` reader；写入侧是 `Config.set_sources/2` 的 `{:set, ...}`
  effect）——配了源走"公开 + 定向（有 token）"，没配纯公开。`:search` 不走
  crawl_auto（它是 query 参数化检索，走 `search_fun` 的独立腿）。

  seams（app env，测试注入）：
    * `:fetch_fun`（默认 `Fetch.crawl_auto/1`，收 sources 列表）；
    * `:dispatch_fun`（默认 `Ezagent.Invocation.dispatch/1`）。
  """
  use Ezagent.Lifecycle
  require Logger

  # 内容协议标记（像 kanban 的 __done__）：routing 规则按文本命中，不带任何实例 URI。
  #
  # 归属说明（2026-07-07 rename）：这是**缺省信号名**。字面量带 "dealscout" 是
  # 历史沿用（dealscout socialware 的 Definition / 演示 / 证据都引用它，改字面量
  # 会破内容协议），不代表本模块属业务层。契约锁方向（Decision #156 反转后）：
  # manifest YAML（`socialware_seed/dealscout/manifest.yaml` routing 的
  # `text_contains` arg）是权威载体，本常量是 emit 侧必须匹配的镜像——
  # `dealscout_manifest_test.exs` 从 parse 后的 manifest 读出 arg 断言 == 本
  # 常量。别的 socialware 组合本能力时可在 session config slice 写
  # `:update_signal` key 覆写（emit 侧经 `ctx[:read]` 读，见
  # `signal_marker/1`），并在自己的 routing_rules 里声明匹配的 matcher。
  @update_signal "__dealscout_update__"

  # page 角色槽名（单一契约点，照 update_signal/0）：manifest 的角色槽声明
  # （receivers 权威载体）+ 直接 dispatch 腿的 role_name 解析都对齐这里。
  # "page" 本身是通用词（任何组合本能力的 socialware 声明一个 "page" 角色槽
  # 即可接上直呼腿）。
  @page_role "page"

  @doc "更新信号的**缺省**内容标记（Definition routing_rules 的 `text_contains` 靶子；socialware 可经 config slice `:update_signal` 覆写）。"
  @spec update_signal() :: String.t()
  def update_signal, do: @update_signal

  @doc "page 角色槽名（manifest 角色槽声明 + 直接 dispatch 腿共用的单一契约点）。"
  @spec page_role() :: String.t()
  def page_role, do: @page_role

  # 直接 dispatch 腿要按 role_name 解析 page 成员 —— members 住 session Kind 的
  # `:session` slice（`Ezagent.ActionSet.Session` 的 members map）。本 handler
  # 跑在 session Kind 进程内，`Kind.get_slice`（GenServer.call）会自呼死锁，
  # 走 sanctioned 的 sibling-slice 声明（runtime 注入只读 `ctx.siblings`）。
  reads_siblings([:session])

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
    description: "Trigger a crawl and inject results into this session."
  )

  action(:search,
    args: %{query: :string, source: {:option, :string}},
    returns: %{injected: :integer},
    caps: [:search],
    modes: [:call],
    description: "Run an active search (query) and inject results into this session."
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
        if inject(ctx.session_uri, item, ctx), do: acc + 1, else: acc
      end)

    emit_update_signal(ctx.session_uri, injected, "crawl", ctx)
    dispatch_page_refresh(ctx, injected, "crawl")
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
        if inject(ctx.session_uri, tagged, ctx), do: acc + 1, else: acc
      end)

    emit_update_signal(ctx.session_uri, injected, "search", ctx)
    dispatch_page_refresh(ctx, injected, "search")
    {:ok, %{injected: injected}, []}
  end

  # 内容协议更新信号：injected > 0 才发（没新线索不打扰 hello 的页面 agent）。
  # body 只有标记 + 计数 + 来源腿——零实例 URI，routing 靠 text_contains 命中。
  defp emit_update_signal(_session_uri, 0, _origin, _ctx), do: :ok

  defp emit_update_signal(session_uri, injected, origin, ctx) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    cmd = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: send_args("#{signal_marker(ctx)} 新线索 #{injected} 条（#{origin}）", ctx),
      ctx: delegated_ctx(ctx)
    }

    case dispatch_fun().(cmd) do
      :ok ->
        :ok

      other ->
        :telemetry.execute([:crawler, :update_signal, :error], %{count: 1}, %{
          injected: injected,
          origin: origin,
          reason: other
        })

        Logger.warning(
          "Crawler update signal dispatch failed (no one else would know): #{inspect(other)}"
        )

        :ok
    end
  end

  # 页面重建的直接 dispatch 腿（moduledoc §直接 dispatch 腿）：injected > 0 才发
  # （与更新信号同门）。mode `:call`（kanban 板动作同款）—— 同步拿到
  # `{:ok, _}` / `{:error, _}`，失败 fail-loud。目标是 page 成员的 agent Kind
  # （另一进程），无自呼死锁；handler 只 spawn supervised Task，秒回。
  defp dispatch_page_refresh(_ctx, 0, _origin), do: :ok

  defp dispatch_page_refresh(ctx, injected, origin) do
    case page_member_uri(ctx) do
      {:ok, %URI{} = page_uri} ->
        # 行为段 `:crawler` 只是 `?action=<behavior>.<action>` 的命名段——runtime
        # 解析只按 action 原子在实例行为集找 handler（BehaviorSet.resolve_action），
        # 去业务词后不影响解析（rename 前是 :dealscout）。
        target = Ezagent.URI.with_action(page_uri, :crawler, :refresh_page)

        cmd = %Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{
            summary: "新线索 #{injected} 条（#{origin}）",
            # 宿主是 agent Kind，`ctx.session_uri` 在那边派生不出来 —— 走 args
            # 显式传（DealScoutPageRefreshAlt moduledoc）。
            session_uri: URI.to_string(ctx.session_uri)
          },
          ctx: delegated_ctx(ctx)
        }

        case dispatch_fun().(cmd) do
          :ok -> :ok
          {:ok, _} -> :ok
          other -> page_refresh_error(other, injected, origin)
        end

      {:error, reason} ->
        page_refresh_error(reason, injected, origin)
    end
  end

  # 按 role_name facet 解析 page 成员（照 hello `Members.role_uri/2` 的查询模式，
  # 但读 sibling slice 而非 `Kind.get_slice` —— 本 handler 就跑在 session Kind
  # 进程内）。`Ezagent.ActionSet.Session.Members.role_name_to_uri/2` 是 canonical
  # 的 role_name → uri 解析器（domain_session 是已声明 umbrella dep）。
  defp page_member_uri(ctx) do
    case ctx[:siblings] do
      %{session: session_slice} when is_map(session_slice) ->
        members = Map.get(session_slice, :members, %{})

        case Ezagent.ActionSet.Session.Members.role_name_to_uri(members, @page_role) do
          %URI{} = uri -> {:ok, uri}
          nil -> {:error, :no_page_member}
        end

      _ ->
        {:error, :members_unreadable}
    end
  end

  # 谁会知道原则：page 成员缺失 / dispatch 失败都有人知道（telemetry + warning），
  # 不静默吞 —— 页面不刷新时运维能从日志定位到这条腿。
  defp page_refresh_error(reason, injected, origin) do
    :telemetry.execute([:crawler, :page_refresh, :error], %{count: 1}, %{
      injected: injected,
      origin: origin,
      reason: reason
    })

    Logger.warning(
      "Crawler page refresh dispatch failed (no one else would know): #{inspect(reason)}"
    )

    :ok
  end

  defp inject(session_uri, item, ctx) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    cmd = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: send_args(format_item(item), ctx),
      ctx: delegated_ctx(ctx)
    }

    case dispatch_fun().(cmd) do
      :ok ->
        true

      other ->
        :telemetry.execute([:crawler, :inject, :error], %{count: 1}, %{
          item: item,
          reason: other
        })

        Logger.warning("Crawler inject failed (no one else would know): #{inspect(other)}")
        false
    end
  end

  # 2026-07-07 真浏览器 e2e 修正：`session.send` 的 args 契约是
  # `%{message: %Ezagent.Message{}}`（session.ex:148 `args: %{message: :map}` +
  # handle_send 的 %Message{} 匹配），不是裸 `%{body: text}`——真 dispatch 被
  # validate_args 拒 `{:invalid_args, [{[:message], :missing}]}`（hello
  # `TurnDriver.say_nav` 同款 idiom）。sender 取触发者（ctx.caller），无触发者
  # 身份时回落 session 本体（爬取后台以会话名义投递）。
  defp send_args(text, ctx) do
    %{message: Ezagent.Message.new(sender_uri(ctx), %{text: text, attachments: []})}
  end

  defp sender_uri(%{caller: %URI{} = caller}), do: caller
  defp sender_uri(%{session_uri: %URI{} = session_uri}), do: session_uri

  # 2026-07-07 真浏览器 e2e 修正：内层 `session.send` 的 authz 需要真实身份——
  # 裸 `%{reply: :ignore}`（无 caller / caps）在 Kind 的 cap-check 下必
  # `:unauthorized`（fire-and-forget cast，只有日志能看见）。透传**外层触发者**
  # 的 caller/caps（admin 或持 `session.send` cap 的发现 agent）：注入线索以
  # 触发者身份落进会话，CapBAC 不绕过——触发者没有 send cap 时注入照样被拒。
  defp delegated_ctx(ctx) do
    %{reply: :ignore}
    |> maybe_put(:caller, ctx[:caller])
    |> maybe_put(:caps, ctx[:caps])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_item(%{source_type: st, title: t, url: u, summary: s} = item) do
    origin = Map.get(item, :source)
    origin_tag = if origin in [nil, ""], do: "", else: " {#{origin}}"
    "[#{st}]#{origin_tag} #{t} — #{s} (#{u})"
  end

  # 更新信号标记：config slice 的 `:update_signal` key 可覆写（socialware 级
  # 配置，@update_signal 注释）；未配置 / 无 reader / 非法值回落缺省标记。
  defp signal_marker(ctx) do
    case ctx[:read] do
      read when is_function(read, 2) ->
        case read.(:update_signal, @update_signal) do
          marker when is_binary(marker) and marker != "" -> marker
          _ -> @update_signal
        end

      _ ->
        @update_signal
    end
  end

  # 定向源清单从 config slice 读（framework 经 `ctx[:read]` 注入 slice reader，
  # plugin 作者不见底层存储）。无 reader（如裸测试 ctx）降级为 []（纯公开爬）。
  defp config_sources(ctx) do
    case ctx[:read] do
      read when is_function(read, 2) ->
        EzagentPluginCrawler.Config.normalize_sources(read.(:sources, []))

      _ ->
        []
    end
  end

  defp fetch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_crawler,
        :fetch_fun,
        &EzagentPluginCrawler.Fetch.crawl_auto/1
      )

  defp search_fun,
    do: Application.get_env(:ezagent_plugin_crawler, :search_fun, &default_search/1)

  # 参数化搜索：把 query 转成对公开搜索源的检索（HN Algolia，公开、无 token），
  # 结果标 `:public`。指定源检索走 `Fetch.fetch_directed/2`（Task 5 token 注入）。
  defp default_search(query),
    do: EzagentPluginCrawler.Fetch.fetch(search_url(query), [], :public)

  defp search_url(query),
    do: "https://hn.algolia.com/api/v1/search?query=#{URI.encode(query)}"

  # 2026-07-07 真浏览器 e2e 修正：本模块构造的是 `%Ezagent.Invocation{}`，但
  # `Ezagent.Router.dispatch/1` 只收 `%Ezagent.Cmd{}`（router.ex:79 的
  # `def dispatch(%Cmd{} = cmd)`）→ 真 dispatch 必 FunctionClauseError（单测
  # stub 了 :dispatch_fun 掩盖）。P14 的 legacy 路 `Ezagent.Invocation.dispatch/1`
  # 直接收 `%Invocation{}`（hello `TurnDriver` 同款 idiom）。
  defp dispatch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_crawler,
        :dispatch_fun,
        &Ezagent.Invocation.dispatch/1
      )
end
