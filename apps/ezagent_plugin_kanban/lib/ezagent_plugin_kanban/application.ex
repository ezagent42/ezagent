defmodule EzagentPluginKanban.Application do
  @moduledoc """
  Kanban plugin OTP application — the `Ezagent.Plugin` contract module.

  df-prd 增量 1：看板双向打通。看板 = 一个 `EzagentPluginKanban.Kanban`
  Kind 实例（`resource://<ws>/kanban/<name>`，数据资源 Kind），节点树住在它的 state（真相源）；
  与 markmap markdown 文件双向同步。

  纯 plugin（路 A）：只声明 `kinds/0` / `behaviors/0` / `children/0`，框架的
  `Ezagent.Plugin.boot/1` 代为注册，作者不碰任何 `*Registry`。
  `:ezagent_plugin_check` 编译器是非旁路的强制 gate。

  本模块同时 `use Application`（OTP plumbing）与 `use Ezagent.Plugin`（声明契约），
  对齐 `EzagentPluginEcho.Application` 先例。
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "kanban",
      name: "Kanban",
      description: "看板节点树 Kind + markmap 双向文件同步（df-prd 增量 1）。",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def kinds, do: [EzagentPluginKanban.Kanban]

  @impl Ezagent.Plugin
  def behaviors do
    b = Ezagent.Behavior.Kanban
    k = EzagentPluginKanban.Kanban

    for a <- [
          :add_node,
          :rename_node,
          :move_node,
          :remove_node,
          :set_stage,
          :claim_node,
          :unclaim_node,
          :set_status,
          :attach_artifact,
          :detach_artifact,
          :set_metric,
          :drop_subtree,
          :get_tree,
          :export_markmap,
          :import_markmap
        ],
        do: {k, a, b}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginKanban.InstanceSupervisor, strategy: :one_for_one},
      # Miro 双向同步轮询器：按 kanban URI 唯一注册 + 监督树下动态起停。
      {Registry, keys: :unique, name: EzagentPluginKanban.MiroSyncRegistry},
      {DynamicSupervisor, name: EzagentPluginKanban.MiroSyncSupervisor, strategy: :one_for_one}
    ]
  end

  # kanban 专属操作面（df-tech）：`/plugins/kanban` —— 在 world 里建树/认领/改状态/
  # 挂产物/设指标/一键推 Miro（前端 `components/Kanban.tsx` + `world/kanban_{data,actions}.ex`）。
  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/plugins/kanban", label: "看板"}
  end
end
