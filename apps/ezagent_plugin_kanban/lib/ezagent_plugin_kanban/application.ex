defmodule EzagentPluginKanban.Application do
  @moduledoc """
  Kanban plugin OTP application — the `Ezagent.Plugin` contract module.

  df-prd 增量 1：看板双向打通。看板 = 一个 `EzagentPluginKanban.Kanban`
  Kind 实例（`resource://<ws>/kanban/<name>`，数据资源 Kind），节点树住在它的 state（真相源）；
  与 markmap markdown 文件双向同步。

  纯 plugin（路 A）：只声明 `kinds/0` / `behaviors/0` / `resource_kinds/0` / `children/0`，
  框架的 `Ezagent.Plugin.boot/1` 代为注册，作者不碰任何 `*Registry`。
  `:ezagent_plugin_check` 编译器是非旁路的强制 gate。

  本模块同时 `use Application`（OTP plumbing）与 `use Ezagent.Plugin`（声明契约），
  对齐 `EzagentPluginEcho.Application` 先例。

  ## 怎么起活（kanban-clean Plan B）

  kanban Kind 经 `resource://<ws>/kanban/<name>` 寻址。`resource` scheme 的 spawn
  dispatcher 由 **workspace domain** 独占（`EzagentDomainWorkspace.Application`），
  按 `Ezagent.URI.type/1` 查 `Ezagent.ResourceKindRegistry` 找回 Kind 模块——这正是
  session domain 的 `entity` dispatcher 查 user/agent（agent 经 `AgentFlavorRegistry`）的
  同构范式。plugin **永不**注册 scheme spawn fn（invariant 8），只在 `resource_kinds/0`
  声明自己的 type→Kind，`Ezagent.Plugin.boot/1` 代为登记进 ResourceKindRegistry。
  dispatch 到没 live 的 fresh kanban URI 仍只 `:no_such_actor`（无快照 → 不自动起），
  故 world 在 create/select/session-board 入口先 `SpawnRegistry.spawn`。
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

  # kanban-as-role (K1, RF-4)：看板 = 一个 agent，role `kanban-manager` × flavor
  # `native`。本 `roles/0` code-seed 该 role recipe，`Ezagent.Plugin.boot/1` 经
  # `RoleRegistry.register/1` 在 boot 时登记（作者只声明、框架代登记）。
  #
  #   * `behaviors: [Ezagent.Behavior.Kanban]` —— **仅** Kanban。`Connectors`
  #     不是 Behavior（无 `use Lifecycle` / 无 `actions/0`）；全部 24 个动作（含 9 个
  #     连接器动作）都在 `kanban.ex` 经 `action/3` 声明、薄转发给 `Connectors`，故全
  #     经 `Behavior.Kanban` 解析（RF-1 `BehaviorSet.resolve_action`）。
  #   * `requested_caps` = 每个动作一个 **cap-template map** `%{behavior:, action:}`
  #     —— 不是裸 atom（`Role.new/1` 的 `canon_cap` 拒非 map），也不带 `kind`（kind 是
  #     materialization 轴，由 `Role.CapMint` 按 flavor 注入 = `:agent`）。
  #   * `passive: true` —— 看板是**被动数据 actor**：不可被 @ / 不可 `:join` / 不收
  #     chat（RF-6 三闸），只在直接 `kanban.<action>` dispatch 上动作。
  @impl Ezagent.Plugin
  def roles, do: [kanban_manager_recipe()]

  @doc """
  The `kanban-manager` role recipe (also the K1 gate's subject).

  Public so the role test + future create wiring can assert the exact recipe
  without re-deriving the action list (single source of truth =
  `Ezagent.Behavior.Kanban.actions/0`).
  """
  @spec kanban_manager_recipe() :: map()
  def kanban_manager_recipe do
    %{
      name: "kanban-manager",
      passive: true,
      behaviors: [Ezagent.Behavior.Kanban],
      requested_caps:
        for action <- Ezagent.Behavior.Kanban.actions() do
          %{behavior: Ezagent.Behavior.Kanban, action: action}
        end
    }
  end

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
          :import_markmap,
          :sync_github,
          :push_pr,
          :register_pr,
          :attach_code_file,
          :sync_prs,
          :sync_miro,
          :set_board_config,
          :save_github_creds,
          :save_miro_creds
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

  # config_surface/0 — the `/plugins/kanban` world nav route is DELIBERATELY NOT
  # declared in this backend-only PR (K1–K3). The world plugin surfaces every
  # plugin's `config_surface/0` as a clickable nav entry
  # (`world/workspace_plugin_data.ex` list_plugins), but the world-side handler +
  # React (`Kanban.tsx`/`KanbanCanvas.tsx` + `world/kanban_{data,actions}.ex`)
  # are NOT on main yet — they land with the K4 world-rewire PR (read-model
  # list-by-role + the `entity://<ws>/agent/<id>?action=kanban.<a>` dispatch
  # target). Declaring the route now would ship a "看板" entry that 404s on click.
  # Re-add config_surface/0 in K4 together with that handler. (Default → nil.)
end
