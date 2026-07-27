defmodule EzagentPluginKanban.BoardView do
  @moduledoc """
  kanban-team board 的 `Ezagent.UI.SessionView`（照 hello `PageView` 先例）。

  这是 **DECLARE，自包含** —— view 声明 + json-render 投影归 kanban 插件自己
  （`Ezagent.ActionSet.KanbanRender`），kanban-team Definition 的 `views` 字段引
  它。经 `EzagentPluginKanban.Application.start/2` 里
  `SessionViewRegistry.register/1` 注册；world 通用消费 registry（world-views
  #1192/#1199：`applicable_views/2` 枚举 tab + 按 mode 渲染），所以本片
  **零 world 改动** —— "plugin 声明 → world 通用消费 → 自动接入" 的 kanban 落地。

  ## 契约实现

    * `id/0 → :kanban_board`、`label/0 → "看板"`、`icon/0`：view-switcher 按钮
      元数据（icon 是 lucide 名，world 侧 icon lookup + fallback）。
    * `view_behavior/0 → Ezagent.ActionSet.KanbanRender`：cap-gated（T2-2b），
      `SessionView.authorize_view/3` 检查 caller 持 `{Session, :kanban_render}`。
    * `applies_to?/1`：**D3 tab 恒显**（Allen option a，2026-07-19）——系统装了
      kanban plugin，**所有 session** 都显示 kanban tab（任何 session URI →
      true）；被门控的是板内容/钥匙（cap gate + dispatch chokepoint），不是 tab
      显隐——这也让「分享链接在任何会话点开」有意义。非 session 输入仍 false
      （fail-safe）。（供给半件：全体登录成员按 plugin 基线发 `kanban_render`
      cap 归 D1 membership 供给机制，domain 面，随 join/backfill 路走。）
    * `external_render?/0 → true` + `external_render/1`：EXTERNAL json-render
      target（P2 unified view contract），委托 `KanbanRender.external_tree/1`
      （只读 board 投影；无 board → nil = "nothing to render yet"）。
    * `render/1`：internal LiveView 渲染（同一投影渲成简单列/卡 HEEx，供 world
      console 内嵌读；board 操作面另在 `/plugins/kanban`，本 view 只读）。

  Board 是 workspace 级 actor（非 session 成员，S2 建模修正）——投影按 session
  的 workspace 找 board（`KanbanRender.boards_for/1`），不经 session 成员表。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.ActionSet.KanbanRender

  @impl true
  def id, do: :kanban_board

  @impl true
  def label, do: "看板"

  @impl true
  def icon, do: "square-kanban"

  # T2-2b — cap-gated on the `{Session, :kanban_render}` cap (declared by
  # KanbanRender). `authorize_view/3` reads this to gate applicable/render.
  @impl true
  def view_behavior, do: KanbanRender

  # D3 tab 恒显（Allen option a，2026-07-19）：任何 session → true，不再按
  # installed Definition 判（旧读法：installed_definitions 含 KanbanRender 才
  # true）。非 session 输入 false（fail-safe）。
  @impl true
  def applies_to?(%URI{scheme: "session"}), do: true
  def applies_to?(_), do: false

  # P2 — this view declares an EXTERNAL json-render target (the board tree the
  # SPA consumes), in addition to the internal LiveView render.
  @impl true
  def external_render?, do: true

  @impl true
  def external_render(%URI{} = session_uri), do: KanbanRender.external_tree(session_uri)
  def external_render(_), do: nil

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :board_tree, fn -> load_tree(assigns[:session_uri]) end)

    ~H"""
    <div id="kanban-board-view" class="flex-1 overflow-auto min-h-0 p-5">
      <div
        :if={is_nil(@board_tree)}
        id="kanban-board-empty"
        class="h-full min-h-64 flex items-center justify-center text-sm text-zinc-500 dark:text-zinc-400"
      >
        这里还没有看板 —— 在会话的「看板」标签新建一块，或点别人分享的看板链接把它领进来（只读钥匙发给你本人）。

      </div>

      <div :if={not is_nil(@board_tree)} id="kanban-board-columns" class="flex gap-4 items-start">
        <div
          :for={column <- @board_tree["columns"]}
          class="min-w-48 flex-1 rounded-lg bg-zinc-50 dark:bg-zinc-900 p-3"
        >
          <h3 class="text-xs font-semibold uppercase text-zinc-500 dark:text-zinc-400 mb-2">
            {column["stage"]} ({length(column["cards"])})
          </h3>
          <ul class="space-y-2">
            <li
              :for={card <- column["cards"]}
              class="rounded bg-white dark:bg-zinc-800 px-3 py-2 text-sm text-zinc-800 dark:text-zinc-200 shadow-sm"
            >
              <div class="font-medium">{card["title"]}</div>
              <div :if={card["status"]} class="text-xs text-zinc-500 dark:text-zinc-400">
                {card["status"]}
              </div>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # 内嵌读用同一只读投影（external 同源）；fail-safe nil → 空态。
  defp load_tree(%URI{} = session_uri), do: KanbanRender.external_tree(session_uri)
  defp load_tree(_), do: nil
end
