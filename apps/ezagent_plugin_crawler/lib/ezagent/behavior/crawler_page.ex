defmodule Ezagent.ActionSet.CrawlerPage do
  @moduledoc """
  crawler 的**页面发布腿**——挂在 `page` 角色槽（recipe `"crawler-page"` ×
  native flavor，`EzagentPluginCrawler.Recipes`）上的 caller-dispatch
  ActionSet。声明单个 dispatchable action `:publish_page`：
  `Ezagent.ActionSet.Crawler` 在爬完注入新线索后按 `role_name` facet 解析出
  本 agent 的实例 URI 直接 dispatch 过来（kanban pm→board 同款 caller-dispatch，
  #1190 r2 已证——不走 receive 投递，native flavor 无 bridge 的平台 gap
  #1201 ② 与本腿无关）。

  handler 在 supervised Task（`EzagentPluginCrawler.TaskSupervisor`）里调
  `EzagentPluginCrawler.PagePublisher.publish/2`：读会话留存的结构化线索
  （真实爬取产物）→ 投影成 catalog 页树 → 驱动 turn.open/compose/settle 落
  **committed Surface 版本树**（approve + commit——`/socialware/external`
  匿名读的公开页）。**必须 Task**：publish 是对 session 的顺序 `:call`，而
  本 handler 往往正被 session 内 crawl 的 `:call` 同步等着——handler 内串行
  `:call` 回 session 即死锁；Task 秒回后 session 先完成当轮（`{:set, :items}`
  effect 落盘），Task 的读/写按 mailbox 顺序排在其后（时序天然正确）。

  `session_uri` 走 args 显式传（宿主是 agent Kind，`ctx.session_uri` 只在
  session:// 目标上派生——`Kind.Runtime.Context.derive_session_uri/1`）。
  防自环天然成立：本 action 只被显式 dispatch 触发，不收任何 session 投递。

  与业务无关（"换个 socialware 还能原样用吗"判据）：任何组合 crawler 能力的
  socialware 声明一个 `page` 角色槽引 `crawler-page` recipe 即接上本腿；
  发布内容 = 该会话自己的留存线索，零业务措辞。

  seam（app env，测试注入）：`:page_publish_fun`（默认
  `&EzagentPluginCrawler.PagePublisher.publish_async/2`，arity-2 收
  `(session_uri, summary)`）。
  """

  use Ezagent.Lifecycle
  require Logger

  action(:publish_page,
    args: %{summary: :string, session_uri: :string},
    returns: %{},
    caps: [:publish_page],
    modes: [:call],
    description:
      "Publish the session's retained crawl leads as a committed public page (caller-dispatched)"
  )

  # 无 durable state：触发方（Crawler）显式带全部输入，数据面是会话自己的
  # 线索 slice。空 state 即可。
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  caller-dispatch 的 `:publish_page`：解析 args 里的 `session_uri` → supervised
  Task 里跑 `page_publish_fun`（默认 `PagePublisher.publish_async/2`，
  fire-and-forget——发布结果经 Turn/Surface 落 committed 版本树）。`summary`
  为空时用缺省说明（信号本身就是"有新线索，重发布页面"的指令）。
  session_uri 解析不出来 → fail-loud（`{:error, ...}` 同步返回给 dispatch 方）。
  """
  def handle_publish_page(%{summary: summary, session_uri: session_uri_str}, _ctx) do
    case parse_session_uri(session_uri_str) do
      {:ok, %URI{} = session_uri} ->
        _ = page_publish_fun().(session_uri, publish_summary(summary))
        {:ok, %{}, []}

      {:error, reason} ->
        Logger.warning(
          "crawler publish_page got an unusable session_uri " <>
            "(no one else would know): #{inspect(reason)}"
        )

        {:error, {:bad_session_uri, reason}}
    end
  end

  # caps-data-ownership — dispatch-gated Behavior; no per-entity owner.
  @impl Ezagent.ActionSet
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  defp publish_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> "有新抓回的线索，已更新公开线索页"
      text -> text
    end
  end

  defp publish_summary(_), do: "有新抓回的线索，已更新公开线索页"

  # fail-closed 解析：必须是 session:// 实例 URI（Turn/Surface 的宿主）。
  defp parse_session_uri(s) when is_binary(s) do
    case Ezagent.URI.new!(s) do
      %URI{scheme: "session"} = uri -> {:ok, Ezagent.URI.instance(uri)}
      %URI{} = other -> {:error, {:not_a_session_uri, URI.to_string(other)}}
    end
  rescue
    e -> {:error, {:malformed_uri, Exception.message(e)}}
  end

  defp parse_session_uri(other), do: {:error, {:malformed_uri, other}}

  defp page_publish_fun do
    Application.get_env(
      :ezagent_plugin_crawler,
      :page_publish_fun,
      &EzagentPluginCrawler.PagePublisher.publish_async/2
    )
  end
end
