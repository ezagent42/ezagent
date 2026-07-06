defmodule EzagentPluginDealScout.DealScoutView do
  @moduledoc """
  DealScout 发现流的 `Ezagent.UI.SessionView`（照 hello `PageView`）。

  这是 **DECLARE，自包含**——view 声明 + json-render 归 dealscout 插件自己声明，
  DealScout Definition 的 `views` 字段引 `Ezagent.ActionSet.DealScoutRender`。经
  `EzagentPluginDealScout.Application.start/2` 里 `SessionViewRegistry.register/1`
  注册，world 泛化渲染任何已注册的 SessionView（不需改 world）。

  **边界（按用户定的分离）**：本模块只做 DECLARE。"让它在 world 会话面板冒成可切
  tab" 是 world-views 分支（系统层）改 world owner `switch_view` 白名单的活，**不
  在本片、不碰 world**。

  ## 契约实现

    * `id/0` → `:dealscout_feed`、`label/0`、`icon/0`：view-switcher 按钮元数据。
    * `applies_to?/1`：本 session 是否装了 dealscout（看 installed Definition 的
      `views` 是否含 `DealScoutRender`）——fail-safe（任何异常 → false）。
    * `view_behavior/0` → `Ezagent.ActionSet.DealScoutRender`：cap-gated，
      `SessionView.authorize_view/3` 检查 `{Session, :dealscout_render}` cap。
    * `external_render?/0` → true + `external_render/1`：产 json-render tree
      （委托 `DealScoutRender.render_tree/1`，按 `source_type` 分组，spec §3.2）。
    * `render/1`：internal LiveView 渲染（同款分类，供 world console 内嵌读）。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.ActionSet.DealScoutRender

  @impl true
  def id, do: :dealscout_feed

  @impl true
  def label, do: "DealScout"

  @impl true
  def icon, do: "radar"

  # T2-2b — cap-gated on the `{Session, :dealscout_render}` cap (declared by
  # DealScoutRender). `authorize_view/3` reads this to gate applicable/render.
  @impl true
  def view_behavior, do: DealScoutRender

  @impl true
  def applies_to?(%URI{} = session_uri) do
    session_uri
    |> Ezagent.Socialware.Installation.installed_definitions()
    |> Enum.any?(fn definition -> DealScoutRender in definition.views end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def applies_to?(_), do: false

  # P2 — this app declares an EXTERNAL json-render target (the discovery feed the
  # SPA / an ExternalAdapter consumes), in addition to the internal LiveView render.
  @impl true
  def external_render?, do: true

  @impl true
  def external_render(%URI{} = session_uri) do
    session_uri
    |> load_discoveries()
    |> DealScoutRender.render_tree()
  end

  def external_render(_), do: DealScoutRender.render_tree([])

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:discoveries, fn -> load_discoveries(assigns[:session_uri]) end)
      |> then(fn a -> assign(a, :tree, DealScoutRender.render_tree(a[:discoveries] || [])) end)

    ~H"""
    <div id="dealscout-feed-view" class="flex-1 overflow-auto min-h-0 p-5">
      <div
        :for={group <- @tree.groups}
        id={"dealscout-group-#{group.source_type}"}
        class="mb-6"
      >
        <h3 class="text-sm font-semibold text-zinc-500 dark:text-zinc-400 mb-2">
          {group.label} ({length(group.items)})
        </h3>
        <ul class="space-y-1">
          <li :for={item <- group.items} class="text-sm text-zinc-800 dark:text-zinc-200">
            {Map.get(item, :title, "")}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # Discoveries live in the session's `:discoveries` slice when present (best-effort,
  # fail-safe empty). The crawl leg injects finds via `session.send` message history;
  # a durable feed slice is a later wiring — the render/grouping contract holds today
  # against whatever the slice carries.
  defp load_discoveries(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :discoveries) do
      {:ok, items} when is_list(items) -> items
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp load_discoveries(_), do: []
end
