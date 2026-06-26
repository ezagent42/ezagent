defmodule EzagentPluginKanban.Application do
  @moduledoc """
  Kanban plugin OTP application — the `Ezagent.Plugin` contract module.

  **kanban-as-role**：看板 = 一个 **agent**（role `kanban-manager` × flavor `native`），
  board = 该 agent 的 `:kanban` snapshot slice（真相源），与 markmap markdown 文件双向同步。
  看板**不是** `resource://` 独立 Kind：`resource://` 回归纯 FS 数据引用（`uri-design.md`），
  绝不承载 live 可起活 Kind / GenServer。这条由 `mix ezagent.arch.scan` 的
  `resource_kind_as_genserver`（cap 0）AST gate 永久锁死（K5），防 Plan-B 模式回归。

  纯 plugin（路 A）：只声明 `behaviors/0` / `roles/0` / `children/0` / `config_surface/0`，
  框架的 `Ezagent.Plugin.boot/1` 代为注册，作者不碰任何 `*Registry`。
  `:ezagent_plugin_check` 编译器是非旁路的强制 gate。

  本模块同时 `use Application`（OTP plumbing）与 `use Ezagent.Plugin`（声明契约），
  对齐 `EzagentPluginEcho.Application` 先例。

  ## 怎么起活

  看板经 `entity://<ws>/agent/<id>` 寻址（agent 的 URI）。`roles/0` 在 boot 经
  `RoleRegistry.register/1` 登记 `kanban-manager` recipe；create 走 RF-5a role-create
  路径（`Workspace.create_agent` flavor `native` × role `kanban-manager`），24 个 kanban
  behaviors 经 RF-1 在通用 `Entity.Agent` 宿主上 per-instance 加载。dispatch 到没 live 的
  agent 经 `SpawnRegistry.spawn` 从快照 rehydrate 起活（world 读模型在 dispatch 前
  `KanbanData.ensure_spawned/1`，保 dormant 的 passive kanban-manager 复活）。
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

  # kanban-as-role (K5)：DELETED standalone `resource://` Kanban Kind
  # (`EzagentPluginKanban.Kanban`). The role × native agent fully replaces it —
  # the plugin declares NO `kinds/0` (defaults to `[]`); board state lives on the
  # generic `Entity.Agent` `:kanban` snapshot slice. (Plan-B's `resource_kinds/0`
  # never landed on main; the `resource_kind_as_genserver` arch gate locks it out.)

  # kanban-as-role (K1, RF-4)：看板 = 一个 agent，role `kanban-manager` × flavor
  # `native`。本 `roles/0` code-seed 该 role recipe，`Ezagent.Plugin.boot/1` 经
  # `RoleRegistry.register/1` 在 boot 时登记（作者只声明、框架代登记）。
  #
  #   * `behaviors: [Ezagent.Behavior.Kanban]` —— **仅** Kanban。`Connectors`
  #     不是 Behavior（无 `use Lifecycle` / 无 `actions/0`）；全部 24 个动作（含 9 个
  #     连接器动作）都在 `lib/ezagent/behavior/kanban.ex` 经 `action/3` 声明、薄转发给
  #     `Connectors`，故全经 `Behavior.Kanban` 解析（RF-1 `BehaviorSet.resolve_action`）。
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

  # kanban-as-role (K5)：DELETED the static `behaviors/0` `{kind, action, behavior}`
  # declarations. They registered `(EzagentPluginKanban.Kanban, action) → behavior`
  # rows in `CapabilityRegistry` for the now-deleted resource Kind. Under the role
  # model the kanban behaviors load PER-INSTANCE via the `kanban-manager` recipe
  # (RF-1 `BehaviorSet.resolve_action` on the generic `Entity.Agent` host); the
  # host declares NOTHING kanban-specific (K2's invariant), so those static rows
  # are dead (`Entity.Agent` is the resolution key, never the Kanban Kind). The
  # recipe (`roles/0`) is now the sole behavior declaration. Defaults to `[]`.

  @impl Ezagent.Plugin
  def children do
    [
      # Miro 双向同步轮询器：按 kanban URI 唯一注册 + 监督树下动态起停。
      # （`InstanceSupervisor` was the deleted resource Kanban Kind's `supervisor:`
      # and is dropped with it — nothing else references it.）
      {Registry, keys: :unique, name: EzagentPluginKanban.MiroSyncRegistry},
      {DynamicSupervisor, name: EzagentPluginKanban.MiroSyncSupervisor, strategy: :one_for_one}
    ]
  end

  # config_surface/0 — K4 world-rewire 已在 main（`world/kanban_{data,actions}.ex`
  # + `Kanban.tsx` 均已落地，`/plugins/kanban` 正常渲染、不再 404）。按上一版注释的
  # 约定「Re-add config_surface/0 in K4 together with that handler」，此处补回：
  # world 的 list_plugins 据此把 Kanban 卡片渲染成指向 `/plugins/kanban` 的可点入口
  # （FP5 S9 续 —— 此前 Kanban 卡显示 "no config"、无操作面入口）。
  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/plugins/kanban", label: "看板"}
  end
end
