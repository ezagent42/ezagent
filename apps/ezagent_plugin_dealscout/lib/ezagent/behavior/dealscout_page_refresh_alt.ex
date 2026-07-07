defmodule Ezagent.ActionSet.DealScoutPageRefreshAlt do
  @moduledoc """
  【显式临时 ALT —— A①（#1201 ③，hello 暴露可 dispatch 的页面重建 action）
  落地后本模块**整体删除**，dealscout Demo 的 `page` 槽替换回 `hello.builder`
  （`demo.ex` page 槽注释里的一行回切）。】

  ## v2：caller-dispatch 式（kanban 板动作同款），不再走 receive 投递

  v1 是 receive 式（`handle_receive` 等 session 投递 fan-out）。真 e2e 实测
  该腿走不通（#1201 ②）：canonical `agent.receive` 只会把消息塞 bridge
  （`apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex`
  moduledoc），native flavor 无 bridge —— 投递必丢，`handle_receive` 永远
  跑不到。v2 改成 **caller-dispatch 式**：dispatch 按 action 在实例行为集
  解析后直接跑 handler（`Ezagent.Kind.BehaviorSet.resolve_action/3`），
  不经 bridge —— kanban 的 pm→board 生产路已证（#1190 r2 e2e）。

  ## 干什么

  一个挂在 `native` flavor role agent 上的 ActionSet（recipe
  `"dealscout-page-alt"`，`EzagentPluginDealScout.Recipes`）。声明单个
  dispatchable action `:refresh_page`（caps 形状照 kanban 板动作）：
  `Ezagent.ActionSet.DealScoutCrawl` 在爬完注入新线索后，按 `role_name`
  facet 解析出本 agent 的实例 URI，直接 dispatch 过来。handler 调 hello 的
  公开生成入口 `EzagentPluginHello.Generator.start/2`（supervised Task 里
  跑 LLM → TurnDriver → Surface）触发页面重建。

  `session_uri` 走 args 显式传（宿主是 agent Kind，`ctx.session_uri` 只在
  session:// 目标上派生 —— `Kind.Runtime.Context.derive_session_uri/1`）。
  防自环天然成立：本 action 只被 crawl 的显式 dispatch 触发，不再收任何
  session 投递（v1 的"标记即门"随 receive 腿一起删了）。

  hello 是本插件的已声明 umbrella dep（`mix.exs`），只调它的**公开模块**，
  不改 hello 任何文件（自包含红线）。

  seam（app env，测试注入）：`:page_refresh_fun`（默认
  `&EzagentPluginHello.Generator.start/2`，arity-2 收 `(session_uri, text)`）。
  """

  use Ezagent.Lifecycle
  require Logger

  action(:refresh_page,
    args: %{summary: :string, session_uri: :string},
    returns: %{},
    caps: [:refresh_page],
    modes: [:call],
    description: "ALT: rebuild the hello page for the given session (caller-dispatched)"
  )

  # 无 durable state：触发方（DealScoutCrawl）显式带全部输入，生成入口是
  # hello 的公开模块。空 slice 即可（照 HelloBuilder）。
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  caller-dispatch 的 `:refresh_page`：解析 args 里的 `session_uri` → 调
  `page_refresh_fun`（默认 hello `Generator.start/2`）触发页面重建（fire-and-
  forget，生成结果经 TurnDriver 落 Surface）。`summary` 为空时用缺省刷新指令
  （信号本身就是"有新线索，重建页面"的指令，摘要只是生成 prompt 的补充语境）。
  session_uri 解析不出来 → fail-loud（`{:error, ...}` 同步返回给 dispatch 方）。
  """
  def handle_refresh_page(%{summary: summary, session_uri: session_uri_str}, _ctx) do
    case parse_session_uri(session_uri_str) do
      {:ok, %URI{} = session_uri} ->
        _ = page_refresh_fun().(session_uri, refresh_text(summary))
        {:ok, %{}, []}

      {:error, reason} ->
        Logger.warning(
          "DealScout ALT refresh_page got an unusable session_uri " <>
            "(no one else would know): #{inspect(reason)}"
        )

        {:error, {:bad_session_uri, reason}}
    end
  end

  # caps-data-ownership — admin-only Behavior; no per-entity owner（照 HelloBuilder）。
  @impl Ezagent.ActionSet
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  defp refresh_text(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> "有新抓回的线索，请刷新展示页"
      text -> text
    end
  end

  defp refresh_text(_), do: "有新抓回的线索，请刷新展示页"

  # fail-closed 解析：必须是 session:// 实例 URI（Generator.start/2 的目标）。
  defp parse_session_uri(s) when is_binary(s) do
    case Ezagent.URI.new!(s) do
      %URI{scheme: "session"} = uri -> {:ok, Ezagent.URI.instance(uri)}
      %URI{} = other -> {:error, {:not_a_session_uri, URI.to_string(other)}}
    end
  rescue
    e -> {:error, {:malformed_uri, Exception.message(e)}}
  end

  defp parse_session_uri(other), do: {:error, {:malformed_uri, other}}

  defp page_refresh_fun do
    Application.get_env(
      :ezagent_plugin_dealscout,
      :page_refresh_fun,
      &EzagentPluginHello.Generator.start/2
    )
  end
end
