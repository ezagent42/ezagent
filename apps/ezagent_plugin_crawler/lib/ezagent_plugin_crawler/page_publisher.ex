defmodule EzagentPluginCrawler.PagePublisher do
  @moduledoc """
  把会话留存的结构化线索（`Ezagent.ActionSet.Crawler` slice 的 `:items`，
  真实爬取产物）发布成 **committed 公开页**——驱动一个 socialware Turn 落
  Surface 版本树（照 hello `TurnDriver` 的 chokepoint 流，crawler 自带、
  不再借 hello 的 Generator/LLM）：

      turn.open → turn.compose([%{kind: :chat, text: summary},
                                %{kind: :page, tree: render_tree(items)}]) → turn.settle

  `compose` 把 `kind: :page` ref 路由进 `Surface.put_version`；`settle` 推进
  approved 指针 + commit settlement——`ExternalFeed.snapshot/2` 的 `page`
  （`/socialware/external` 匿名读的 committed 页）随即返回这棵真数据树。
  树是 `Ezagent.ActionSet.CrawlerRender.render_tree/1` 的同一投影（view 与
  公开页单一投影源），**纯确定性、零 LLM、零假数据**（D6：committed 静态页）。

  这些是顺序 `:call` dispatch，必须跑在可阻塞的 caller 进程里——
  `Ezagent.ActionSet.CrawlerPage.handle_publish_page/2` 从 supervised Task
  （`EzagentPluginCrawler.TaskSupervisor`）里调 `publish/2`，绝不在 Behavior
  handler 进程内串行 `:call`（session 正被 crawl 的 `:call` 占着，回环即死锁）。

  ## Authority（Phase 0，照 hello TurnDriver 先例）

  以 `User.admin_uri()` + `Capability.admin_genesis_cap()` dispatch——与
  substrate 自己的 settlement-recovery 路（`Behavior.Turn.recovery_effects/3`）
  同一 system authority。更紧的 within-session delegation 是 TurnDriver
  moduledoc 里记录的同一 Phase-0 follow-up，这里不另起炉灶。

  失败问"谁会知道"：任何一步失败记 `[:crawler, :page_publish, :error]`
  telemetry + warning（页面不更新时运维从日志定位）；零留存线索时跳过
  （`[:crawler, :page_publish, :skipped]`——没有真数据就不发空页，fail-honest）。

  seam（app env，测试注入）：`:dispatch_fun`（与 `Ezagent.ActionSet.Crawler`
  同一 seam，默认 `Ezagent.Invocation.dispatch/1`）；`:items_read_fun`（默认
  `CrawlerRender.items_result/1`）+ `:publish_read_attempts` /
  `:publish_read_interval_ms`（发布读的有界重试，见 `publish/2`）。
  """

  require Logger

  alias Ezagent.ActionSet.CrawlerRender
  alias Ezagent.{Capability, Invocation}

  @doc """
  supervised-Task 入口（`CrawlerPage.handle_publish_page/2` 的缺省
  `:page_publish_fun`）：fire-and-forget 地跑 `publish/2`。
  """
  @spec publish_async(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def publish_async(%URI{} = session_uri, summary) do
    Task.Supervisor.start_child(EzagentPluginCrawler.TaskSupervisor, fn ->
      _ = publish(session_uri, summary)
    end)
  end

  @doc """
  读会话留存线索并发布 committed 页。零留存线索（**确定性读**到空）→
  `{:ok, :empty}`（telemetry `:skipped`，不发空页）；否则走 `publish_items/3`。

  ## 读侧耐心（2026-07-10 段5 真 e2e 实测修正）

  crawl/search 注入 burst 后，session Kind 要逐条消化几十条 `session.send`
  cast（每条带 snapshot 落盘），本 Task 的 `Kind.get_slice` 会撞 5s call
  超时——线索明明在，读却失败。原实现经 `items_for/1` 的 fail-safe 把读失败
  折叠成 `[]` → 静默跳过（telemetry-only），自动发布腿在真实时序下必跳。
  现在用可辨别的 `CrawlerRender.items_result/1`：读失败（非"确定为空"）按
  `@read_attempts` × `@read_interval_ms` 有界重试，等 Kind 消化完 burst 再读；
  重试耗尽仍失败 → fail-loud（error telemetry + warning + `{:error, reason}`），
  绝不把"读不到"谎报成"没有线索"。
  """
  @spec publish(URI.t(), String.t()) :: {:ok, String.t() | :empty} | {:error, term()}
  def publish(%URI{} = session_uri, summary) do
    case read_items_patiently(session_uri, read_attempts()) do
      {:ok, []} ->
        :telemetry.execute([:crawler, :page_publish, :skipped], %{count: 1}, %{
          session_uri: URI.to_string(session_uri)
        })

        {:ok, :empty}

      {:ok, items} ->
        publish_items(session_uri, items, summary)

      {:error, reason} ->
        :telemetry.execute([:crawler, :page_publish, :error], %{count: 1}, %{
          session_uri: URI.to_string(session_uri),
          reason: {:items_read_failed, reason}
        })

        Logger.warning(
          "crawler PagePublisher: retained-leads read failed after retries on " <>
            "#{URI.to_string(session_uri)} (no one else would know): #{inspect(reason)}"
        )

        {:error, {:items_read_failed, reason}}
    end
  end

  # 发布读的缺省耐心：10 次 × 3s ≈ 30s —— 覆盖注入 burst（几十条 send ×
  # snapshot 落盘，实测数秒到十几秒）的消化窗口。app env 是测试 seam。
  @read_attempts 10
  @read_interval_ms 3_000

  defp read_items_patiently(session_uri, attempts_left) do
    case items_read_fun().(session_uri) do
      {:ok, items} ->
        {:ok, items}

      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(read_interval_ms())
        read_items_patiently(session_uri, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # seam（app env，测试注入）：`:items_read_fun`（默认
  # `CrawlerRender.items_result/1`——可辨别读）。
  defp items_read_fun,
    do:
      Application.get_env(
        :ezagent_plugin_crawler,
        :items_read_fun,
        &CrawlerRender.items_result/1
      )

  defp read_attempts,
    do: Application.get_env(:ezagent_plugin_crawler, :publish_read_attempts, @read_attempts)

  defp read_interval_ms,
    do: Application.get_env(:ezagent_plugin_crawler, :publish_read_interval_ms, @read_interval_ms)

  @doc """
  把给定线索列表投影成 catalog 页树并驱动 turn.open → compose → settle。
  返回 `{:ok, turn_id}` | `{:error, reason}`（fail-loud，moduledoc §失败）。
  """
  @spec publish_items(URI.t(), [map()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def publish_items(%URI{} = session_uri, items, summary) when is_list(items) do
    tree = CrawlerRender.render_tree(items)

    with {:ok, %{turn_id: turn_id}} <-
           dispatch(session_uri, :turn, :open, %{
             trigger: %{source: "crawler-page"},
             opened_at: System.system_time(:millisecond)
           }),
         {:ok, _composed} <-
           dispatch(session_uri, :turn, :compose, %{
             turn_id: turn_id,
             result_refs: result_refs(tree, summary)
           }),
         {:ok, %{status: :settled}} <-
           dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}) do
      {:ok, turn_id}
    else
      other ->
        reason =
          case other do
            {:error, reason} -> reason
            unexpected -> {:unexpected, unexpected}
          end

        :telemetry.execute([:crawler, :page_publish, :error], %{count: 1}, %{
          session_uri: URI.to_string(session_uri),
          reason: reason
        })

        Logger.warning(
          "crawler PagePublisher: publish failed on #{URI.to_string(session_uri)} " <>
            "(no one else would know): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp result_refs(tree, summary) do
    chat =
      case String.trim(to_string(summary || "")) do
        "" -> []
        text -> [%{kind: :chat, text: text}]
      end

    chat ++ [%{kind: :page, tree: tree}]
  end

  defp dispatch(session_uri, behavior, action, args) do
    dispatch_fun().(%Invocation{
      target: Ezagent.URI.with_action(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp dispatch_fun,
    do:
      Application.get_env(
        :ezagent_plugin_crawler,
        :dispatch_fun,
        &Ezagent.Invocation.dispatch/1
      )
end
