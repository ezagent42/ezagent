defmodule Ezagent.ActionSet.DealScoutPageRefreshAlt do
  @moduledoc """
  【显式临时 ALT —— A①（#1201 ③）落地后本模块**整体删除**，dealscout Demo 的
  `page` 槽替换回 `hello.builder`（`demo.ex` page 槽注释里的一行回切）。】

  背景：hello builder 的 `from_user?` 门（`apps/ezagent_plugin_hello/lib/
  ezagent/behavior/hello_builder.ex:55,74`）只对 USER-sender 消息触发页面生成
  （防自环），会丢弃 agent-sender 消息。dealscout 的更新信号
  （`Ezagent.ActionSet.DealScoutCrawl.update_signal/0`，`"__dealscout_update__"`）
  的 sender 是爬取 agent —— Definition routing 把信号送到 `page` 槽成员后，
  `hello.builder` 今天不会重建页面。hello 作者认领的修法（A①）是"`from_user?`
  门放行带标记的 agent 信号"，落地前 dealscout 用本 ALT 补上闭环腿。

  ## 干什么

  一个挂在 `native` flavor role agent 上的 ActionSet（recipe
  `"dealscout-page-alt"`，`EzagentPluginDealScout.Recipes`）。`handle_receive`
  收 session 投递 fan-out（`args: %{message: %Ezagent.Message{}}`，
  `ctx.caller` = 发起 session URI —— 与 `Ezagent.ActionSet.HelloBuilder` 同一
  投递契约）：

    * 消息文本**带更新信号标记** → 提取爬取摘要文本（剥掉标记后的
      "新线索 N 条（crawl/search）"），调 hello 的公开生成入口
      `EzagentPluginHello.Generator.start/2`（supervised Task 里跑 LLM →
      TurnDriver → Surface）触发页面重建；
    * 其余消息（用户聊天 / 注入的线索条目 / builder 自己的 narration）一律
      忽略 —— 标记即门，天然防自环（Generator 的叙事与线索条目都不含标记）。

  hello 是本插件的已声明 umbrella dep（`mix.exs`），只调它的**公开模块**，
  不改 hello 任何文件（自包含红线）。

  seam（app env，测试注入）：`:page_refresh_fun`（默认
  `&EzagentPluginHello.Generator.start/2`，arity-2 收 `(session_uri, text)`）。
  """

  use Ezagent.Lifecycle

  alias Ezagent.Message

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "ALT: rebuild the hello page when a dealscout update signal arrives"
  )

  # 无 durable state：标记来自 DealScoutCrawl 的单一契约点，生成入口是 hello 的
  # 公开模块。空 slice 即可（照 HelloBuilder）。
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  投递 fan-out 的 `:receive`：带更新信号标记的消息 → 提取摘要文本 → 调
  `page_refresh_fun`（默认 hello `Generator.start/2`）触发页面重建（fire-and-
  forget，生成结果经 TurnDriver 落 Surface）。不带标记的消息直接忽略。
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    with summary when is_binary(summary) <- signal_summary(msg),
         %URI{} = session_uri <- session_uri(ctx) do
      _ = page_refresh_fun().(session_uri, summary)
    end

    {:ok, %{}, []}
  end

  # caps-data-ownership — admin-only Behavior; no per-entity owner（照 HelloBuilder）。
  @impl Ezagent.ActionSet
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  # 标记即门：文本含 `update_signal/0` 才算更新信号；返回剥掉标记后的爬取摘要
  # （如 "新线索 3 条（crawl）"）。剥完为空（裸标记）也照发 —— 信号本身就是
  # "有新线索，重建页面" 的指令，摘要只是给生成 prompt 的补充语境。
  defp signal_summary(%Message{body: body}) do
    text = Message.Body.body_text(body)
    marker = Ezagent.ActionSet.DealScoutCrawl.update_signal()

    if String.contains?(text, marker) do
      case text |> String.replace(marker, "") |> String.trim() do
        "" -> "有新抓回的线索，请刷新展示页"
        summary -> summary
      end
    end
  end

  # session 投递 fan-out 的 ctx.caller 恒为发起 session 的 %URI{}
  # （`Ezagent.Behavior.Session.Delivery.dispatch_receive_call/3`）。
  defp session_uri(%{caller: %URI{} = uri}), do: uri
  defp session_uri(_), do: nil

  defp page_refresh_fun do
    Application.get_env(
      :ezagent_plugin_dealscout,
      :page_refresh_fun,
      &EzagentPluginHello.Generator.start/2
    )
  end
end
