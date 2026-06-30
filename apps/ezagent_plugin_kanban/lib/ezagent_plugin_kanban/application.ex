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
  `RecipeRegistry.register/1` 登记 `kanban-manager` recipe；create 走 RF-5a role-create
  路径（`Workspace.create_agent` flavor `native` × role `kanban-manager`），24 个 kanban
  behaviors 经 RF-1 在通用 `Entity.Agent` 宿主上 per-instance 加载。dispatch 到没 live 的
  agent 经 `SpawnRegistry.spawn` 从快照 rehydrate 起活（world 读模型在 dispatch 前
  `KanbanData.ensure_spawned/1`，保 dormant 的 passive kanban-manager 复活）。
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # NOTE: the `pm-coordinator` default agent's template-seed moved OUT of this
  # plugin's `after_boot/0` into the generic `Ezagent.Agent.DefaultRecipeSeed`
  # (domain-agent boot). pm is a generic cc-headless agent config, NOT the
  # kanban plugin's definitional agent (that is `kanban-manager`, below), so it
  # no longer rides this plugin's boot. `after_boot/0` falls back to the
  # `use Ezagent.Plugin` default (`:ok`).

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
  # `RecipeRegistry.register/1` 在 boot 时登记（作者只声明、框架代登记）。
  #
  #   * `behaviors: [Ezagent.Behavior.Kanban]` —— **仅** Kanban。`Connectors`
  #     不是 Behavior（无 `use Lifecycle` / 无 `actions/0`）；全部 24 个动作（含 9 个
  #     连接器动作）都在 `lib/ezagent/behavior/kanban.ex` 经 `action/3` 声明、薄转发给
  #     `Connectors`，故全经 `Behavior.Kanban` 解析（RF-1 `BehaviorSet.resolve_action`）。
  #   * `requested_caps` = 每个动作一个 **cap-template map** `%{behavior:, action:}`
  #     —— 不是裸 atom（`Recipe.new/1` 的 `canon_cap` 拒非 map），也不带 `kind`（kind 是
  #     materialization 轴，由 `Recipe.CapMint` 按 flavor 注入 = `:agent`）。
  #   * `passive: true` —— 看板是**被动数据 actor**：不可被 @ / 不可 `:join` / 不收
  #     chat（RF-6 三闸），只在直接 `kanban.<action>` dispatch 上动作。
  @impl Ezagent.Plugin
  def roles, do: [kanban_manager_recipe()]

  @doc """
  The `kanban-manager` role recipe (also the K1 gate's subject).

  Public so the role test + future create wiring can assert the exact recipe
  without re-deriving the action list (single source of truth =
  `Ezagent.Behavior.Kanban.actions/0`).

  ## `config` — the 9-stage product-dev chain as LAYER-2 DATA (taxonomy §4.1)

  The specific 9-stage product-development relay chain + its CI/import defaults
  are BUSINESS semantics — they live HERE as recipe `config` data (layer 2), NOT
  hardcoded in `Behavior.Kanban` (layer 1). The Behavior reads them at runtime
  via `RecipeRegistry.lookup/1` (see `Ezagent.Behavior.Kanban.Shared.stages/1`).
  The Behavior itself stays generic board MECHANISM (columns/cards/stage/claim/
  PR actions + the state machine) with ZERO specific stage names.

    * `stages` — the ordered 9-stage chain (order = relay order; index drives the
      `stage_fits?` monotonic-progress rule).
    * `ci_stage` — the stage whose nodes get CI-gate evaluation (`Ci.check_pr_gate`).
    * `import_default_stage` — the default stage assigned to markmap-imported nodes.
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
        end,
      # Layer-2 business semantics (taxonomy red line 1+2): the specific 9-stage
      # product-dev chain + CI/import defaults. Data, NOT Behavior.Kanban code.
      config: %{
        stages: [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr],
        ci_stage: :pr,
        import_default_stage: :feature
      }
    }
  end

  # The `pm-coordinator` recipe moved to `Ezagent.Agent.DefaultRecipes` (the
  # generic role-as-data source for cc-headless default agents). pm is NOT the
  # kanban plugin's definitional agent — `kanban-manager` is. What STAYS kanban:
  # the per-session pm materialize TRIGGER (`Connectors.bind_session`) + the
  # board-scoping grant (`PmCoordinatorSeed.materialize/4`'s
  # `cap_instance_overrides`), since landing pm onto a CONCRETE board is the
  # kanban-aware piece.

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

  # config_surface/0 — `/plugins/kanban` world nav 入口（Phase 1 A）。K4(#1007) 已落地
  # world-side handler + React（`world/kanban_{data,actions}.ex` + `Kanban.tsx` 列表态，
  # `routes.ex:100` `path == "/plugins/kanban"`），点击不再 404，故现在声明。world
  # `workspace_plugin_data.ex` `list_plugins` 经 `config_target/1`（认 `%{kind: :route}`）
  # 把它渲染成 Plugins 页可点入口。
  @impl Ezagent.Plugin
  def config_surface, do: %{kind: :route, path: "/plugins/kanban", label: "看板"}

  # nav_surfaces/0 — DELETED（2026-06-30）。看板 = 一个 agent（native ×
  # `kanban-manager` role），不占左栏一级 nav，本就返 `[]`（2026-06-27 决策）。
  # 加之 `nav_surfaces/0` 已不再是 core `Ezagent.Plugin` 契约 callback —— 它是
  # World-UI 概念，搬到了 `Ezagent.World.UiSurfaceProvider`（duck-typed 约定）。
  # 在该模型下「没有这个函数」= 「不贡献顶层 nav」，与原先返 `[]` 语义等价，故整段删除。
  # `/plugins/kanban`（`config_surface/0`，上方）仍是**配置**入口，不变。

  @doc """
  session_tabs/0 — Layer-3 会话内 kanban tab（实现 World 的
  `Ezagent.World.UiSurfaceProvider` 约定）。

  一个 session **bind 一块板后**，那个 session 的会话视图多一个 kanban tab，显示绑定的
  板。`condition` = 该 session 绑了板才出——便宜的 `BoardConfig.session_bound?/1` 文件读
  （反扫 boards_for_session），world 经它对当前 session 算可见性、通用渲染（没装 kanban
  插件就没这 tab）。tab body 复用 world 已有 KanbanData/get_tree/Kanban renderer（P13 UI
  住 world），本插件只声明入口存在。

  这是一个**普通 public 函数**（无 `@impl`）：`nav_surfaces/0` / `session_tabs/0` 已不在
  core `Ezagent.Plugin` 契约里，world 经 `function_exported?/3` duck-typed 读取。不加
  `@behaviour Ezagent.World.UiSurfaceProvider`——那会逼出 kanban→world 的反向 compile
  依赖（world 是 UI 宿主，住在插件之上），靠函数名约定即可，保 kanban 零 plugin→plugin 依赖。
  """
  def session_tabs do
    [%{id: "kanban", label: "看板", condition: &EzagentPluginKanban.BoardConfig.session_bound?/1}]
  end
end
