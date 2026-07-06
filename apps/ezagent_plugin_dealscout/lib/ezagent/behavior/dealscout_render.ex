defmodule Ezagent.ActionSet.DealScoutRender do
  @moduledoc """
  DealScout 发现流的 **view read ActionSet**（cap-only，照 `Ezagent.ActionSet.HelloRender`）。

  ## 两个职责

    * **看的权限门（cap-only）**：声明全仓唯一的 `:dealscout_render` read-action。
      `dispatchable?/0 → false`（无 dispatch interface）——它存在只为让
      `{Session, :dealscout_render}` 这个 cap subject 被 DECLARE + 注册到 Session
      Kind 上，供 `Ezagent.UI.SessionView.authorize_view/3` 检查（`DealScoutView`
      的 `view_behavior/0` 指回本模块）。`{Session, :dealscout_render}` 全仓唯一，
      否则 `CapabilityRegistry.check_conflict!` RAISE（业务前缀 `dealscout_` 活在
      产品插件层，非平台层）。

    * **产出 json-render tree（`render_tree/1`，纯函数）**：把发现流条目按
      `source_type`（`:public` 自己爬公开网页 / `:directed` 用 token 抓登录源，
      spec §3.2）分组成一棵可序列化的 json-render map。`DealScoutView.external_render/1`
      委托本函数——渲染逻辑归 dealscout 插件自包含声明，"world 把它冒成 tab" 是
      world-views 分支（系统层）的活，本片不碰 world。

  注册在 `EzagentPluginDealScout.Application.behaviors/0`
  （`{Ezagent.Entity.Session, :dealscout_render, __MODULE__}`）。
  """

  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:dealscout_render]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [{:dealscout_render, "Read (render) the dealscout discovery-feed view for this session."}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{dealscout_render: Ezagent.Capability.cap(:session, __MODULE__, :dealscout_render)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  @doc """
  纯函数：把发现流条目按 `source_type` 分组成 json-render tree（serializable map，
  非 `Phoenix.Component`）。恒返回 `:public` + `:directed` 两组（可为空），
  `DealScoutView.external_render/1` 委托本函数。
  """
  @spec render_tree([map()]) :: %{component: :dealscout_feed, groups: [map()]}
  def render_tree(items) when is_list(items) do
    %{
      component: :dealscout_feed,
      groups: [
        %{source_type: :public, label: "公开发现", items: filter(items, :public)},
        %{source_type: :directed, label: "定向发现", items: filter(items, :directed)}
      ]
    }
  end

  defp filter(items, source_type),
    do: Enum.filter(items, &(Map.get(&1, :source_type) == source_type))
end
