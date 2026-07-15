defmodule EzagentPluginCrawler.LeadsView do
  @moduledoc """
  crawler 留存线索的 `Ezagent.UI.SessionView`（照 kanban `BoardView` 模具）。

  这是 **DECLARE，自包含** —— view 声明 + json-render 投影归 crawler 插件自己
  （`Ezagent.ActionSet.CrawlerRender`），组合本能力的 socialware（如 dealscout）
  在 Definition 的 `views` 字段引它（manifest `views: [crawler_render]`）。经
  `EzagentPluginCrawler.Application.start/2` 里
  `SessionViewRegistry.register/1` 注册；world 通用消费 registry（world-views
  #1192/#1199：`applicable_views/2` 枚举 tab + 按 mode 渲染），所以本片
  **零 world 改动** —— "plugin 声明 → world 通用消费 → 自动接入" 的 kanban
  落地在 crawler 的复刻。

  ## 契约实现

    * `id/0 → :crawler_leads`、`label/0 → "线索"`、`icon/0`：view-switcher 按钮
      元数据（icon 是 lucide 名，world 侧 icon lookup + fallback）。
    * `view_behavior/0 → Ezagent.ActionSet.CrawlerRender`：cap-gated（T2-2b），
      `SessionView.authorize_view/3` 检查 caller 持 `{Session, :crawler_render}`。
    * `applies_to?/1`：本 session 装了声明 crawler view 的 Definition 才 true
      （看 installed Definition 的 `views` 含 `CrawlerRender`）—— **fail-safe**
      （任何异常 → false，坏插件不拖垮整个 session 渲染）。
    * `external_render?/0 → true` + `external_render/1`：EXTERNAL json-render
      target（P2 unified view contract），委托 `CrawlerRender.external_tree/1`
      （只读线索投影；无留存线索 → nil = "nothing to render yet"）。
    * `render/1`：internal LiveView 渲染（同一投影渲成简单卡片列 HEEx，供
      world console 内嵌读；触发爬取另在会话动作面，本 view 只读——D6：
      committed 静态/只读渲染，非交互页面）。

  数据面：线索留存在会话自身 `Ezagent.ActionSet.Crawler` slice 的 `:items`
  （crawl/search 注入成功后的 `{:set, ...}` effect，真实爬取产物）——view 读
  的就是这份真数据，无任何演示假数据源。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.ActionSet.CrawlerRender

  @impl true
  def id, do: :crawler_leads

  @impl true
  def label, do: "线索"

  @impl true
  def icon, do: "radar"

  # T2-2b — cap-gated on the `{Session, :crawler_render}` cap (declared by
  # CrawlerRender). `authorize_view/3` reads this to gate applicable/render.
  @impl true
  def view_behavior, do: CrawlerRender

  @impl true
  def applies_to?(%URI{} = session_uri) do
    session_uri
    |> Ezagent.Socialware.Installation.installed_definitions()
    |> Enum.any?(fn definition -> CrawlerRender in definition.views end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def applies_to?(_), do: false

  # P2 — this view declares an EXTERNAL json-render target (the catalog page
  # tree the SPA consumes), in addition to the internal LiveView render.
  @impl true
  def external_render?, do: true

  @impl true
  def external_render(%URI{} = session_uri), do: CrawlerRender.external_tree(session_uri)
  def external_render(_), do: nil

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :leads, fn -> load_items(assigns[:session_uri]) end)

    ~H"""
    <div id="crawler-leads-view" class="flex-1 overflow-auto min-h-0 p-5">
      <div
        :if={@leads == []}
        id="crawler-leads-empty"
        class="h-full min-h-64 flex items-center justify-center text-sm text-zinc-500 dark:text-zinc-400"
      >
        还没有留存线索 —— 在会话里 @ 发现角色或触发 crawl_now 爬一轮。
      </div>

      <ul :if={@leads != []} id="crawler-leads-list" class="space-y-2">
        <li
          :for={lead <- @leads}
          class="rounded-lg bg-zinc-50 dark:bg-zinc-900 px-4 py-3 text-sm text-zinc-800 dark:text-zinc-200"
        >
          <div class="flex items-baseline gap-2">
            <span class="font-medium">{lead["title"]}</span>
            <span
              :if={lead["source_type"] != ""}
              class="text-xs uppercase text-zinc-500 dark:text-zinc-400"
            >
              {lead["source_type"]}
            </span>
          </div>
          <div :if={lead["summary"] != ""} class="text-xs text-zinc-500 dark:text-zinc-400">
            {lead["summary"]}
          </div>
          <a
            :if={lead["url"] != ""}
            href={lead["url"]}
            target="_blank"
            rel="noopener noreferrer"
            class="text-xs text-blue-600 dark:text-blue-400 break-all"
          >
            {lead["url"]}
          </a>
        </li>
      </ul>
    </div>
    """
  end

  # 内嵌读用同一只读投影（external 同源）；fail-safe [] → 空态。
  defp load_items(%URI{} = session_uri), do: CrawlerRender.items_for(session_uri)
  defp load_items(_), do: []
end
