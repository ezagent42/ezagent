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
  路径（`Workspace.create_agent` flavor `native` × role `kanban-manager`），20 个 kanban
  behaviors 经 RF-1 在通用 `Entity.Agent` 宿主上 per-instance 加载。dispatch 到没 live 的
  agent 经 `SpawnRegistry.spawn` 从快照 rehydrate 起活（world 读模型在 dispatch 前
  `EzagentPluginKanban.WorldData.ensure_spawned/1`，保 dormant 的 passive kanban-manager 复活）。
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    result = Ezagent.Plugin.boot(__MODULE__)
    # S4 — register the board SessionView (declaration side; world consumes the
    # registry generically per world-views #1192/#1199, so this needs ZERO world
    # changes — the hello PageView play). The registry is init'd by
    # ezagent_domain_ui, which boots before this plugin (a declared dep).
    _ = Ezagent.UI.SessionViewRegistry.register(EzagentPluginKanban.BoardView)

    # NOTE: the kanban DEMO socialware is NOT published here. It ships as a
    # deploy-seed package (`apps/ezagent_web/priv/socialware_seed/kanban/
    # manifest.yaml`, like `autoservice` / `hello`): `Ezagent.Home.SocialwareSeed`
    # copies it into the deployment home and the late boot scan
    # `Ezagent.Socialware.ManifestSeed.scan_all!/1` (run from the last-booting
    # transport app, AFTER this plugin registered its plugin_info + `BoardView`
    # so `uses: ["kanban"]` + the `kanban_render` view resolve) publishes it
    # through the governed import lane. Zero call from this plugin's boot;
    # tests drive the SAME shipped file directly via
    # `Ezagent.Socialware.ShippedManifest` — no plugin-side socialware module
    # at all (Decision #156; deploy-seed SPEC §2/§4, the hello #162 play).
    result
  end

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
  #   * `behaviors: [Ezagent.ActionSet.Kanban]` —— **仅** Kanban。`Connectors`
  #     不是 Behavior（无 `use Lifecycle` / 无 `actions/0`）；全部 20 个动作（含 5 个
  #     连接器动作：register_pr/attach_code_file/sync_miro/set_board_config/save_miro_creds，
  #     GitHub 主动连接器已删）都在 `lib/ezagent/behavior/kanban.ex` 经 `action/3` 声明、
  #     薄转发给 `Connectors`，故全经 `Behavior.Kanban` 解析（RF-1 `BehaviorSet.resolve_action`）。
  #   * `requested_caps` = 每个动作一个 **cap-template map** `%{behavior:, action:}`
  #     —— 不是裸 atom（`Recipe.new/1` 的 `canon_cap` 拒非 map），也不带 `kind`（kind 是
  #     materialization 轴，由 `Recipe.CapMint` 按 flavor 注入 = `:agent`）。
  #   * `passive: true` —— 看板是**被动数据 actor**：不可被 @ / 不可 `:join` / 不收
  #     chat（RF-6 三闸），只在直接 `kanban.<action>` dispatch 上动作。
  #
  # 提纯(Task 1):`kanban-assistant` / `dev-together` 两个"脑"配方已从这里搬到
  # sw seed 数据 `apps/ezagent_web/priv/socialware_seed/kanban/recipes.yaml`。
  # 部署时 late boot 扫描(`ManifestSeed.scan_dir!`)在发布 kanban manifest 之前先
  # 读同目录 recipes.yaml 注册这两个 data-role,manifest 的 role slot 仍以 name-ref
  # 解析。plugin 这里只留 board 工具(`kanban-manager` behaviors),不再声明脑。
  @impl Ezagent.Plugin
  def roles, do: [kanban_manager_recipe()]

  @doc """
  The `kanban-manager` role recipe (also the K1 gate's subject).

  Public so the role test + future create wiring can assert the exact recipe
  without re-deriving the action list (single source of truth =
  `Ezagent.ActionSet.Kanban.actions/0`).

  ## `config` — the 9-stage product-dev chain as LAYER-2 DATA (taxonomy §4.1)

  The specific 9-stage product-development relay chain + its CI/import defaults
  are BUSINESS semantics — they live HERE as recipe `config` data (layer 2), NOT
  hardcoded in `Behavior.Kanban` (layer 1). The Behavior reads them at runtime
  via `RecipeRegistry.lookup/1` (see `Ezagent.ActionSet.Kanban.Shared.stages/1`).
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
      behaviors: [Ezagent.ActionSet.Kanban],
      requested_caps:
        for action <- Ezagent.ActionSet.Kanban.actions() do
          %{behavior: Ezagent.ActionSet.Kanban, action: action}
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

  # kanban-as-role (K5)：DELETED the static `behaviors/0` `{kind, action, behavior}`
  # declarations. They registered `(EzagentPluginKanban.Kanban, action) → behavior`
  # rows in `CapabilityRegistry` for the now-deleted resource Kind. Under the role
  # model the kanban behaviors load PER-INSTANCE via the `kanban-manager` recipe
  # (RF-1 `BehaviorSet.resolve_action` on the generic `Entity.Agent` host); the
  # host declares NOTHING kanban-specific (K2's invariant), so those static rows
  # are dead (`Entity.Agent` is the resolution key, never the Kanban Kind).
  #
  # S4 — the ONE static binding that returned (the hello play): the board view's
  # `<sw>_render` cap subject on the Session Kind. Cap-only (`dispatchable?/0 →
  # false`) so this writes only the `{Session, :kanban_render}` cap subject —
  # no dispatch route. This is the cap `SessionView.authorize_view/3` (T2-2b)
  # checks for the kanban board view, and what the socialware conformance gate
  # (assertions 2/9) requires for `Definition.views: [KanbanRender]`.
  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Session, :kanban_render, Ezagent.ActionSet.KanbanRender}
    ]
  end

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

  @doc """
  The kanban plugin's world-page SELF-declaration (#1472).

  Optional, duck-typed plugin extension point (NOT a formal `Ezagent.Plugin`
  callback): world's `Ezagent.World.PluginPageRegistry.load/0` discovers it via
  `function_exported?(mod, :pages, 0)` across every registered plugin, then
  validates each returned declaration fail-closed through
  `Ezagent.World.UiSurfaceProvider.validate_page/1` before mounting it. This is
  the de-hardcoding #1472 performs — the `/plugins/kanban` board page is
  contributed BY this plugin instead of being baked into the world host.

  Returns the single board page declaration: the index + detail routes, the nav
  entry, `WorldData` as both data/state builder, the `kanban` renderer family
  rendered by `assets/src/world_page.tsx` (`KanbanWorldPage`), and the board's
  `kanban.*` actions dispatched through `WorldActions`.
  """
  @spec pages() :: [map()]
  def pages do
    [
      %{
        key: "kanban",
        route: {"/plugins/kanban", :index},
        detail_route: {"/plugins/kanban/:id", :detail},
        nav: %{label: "看板", path: "/plugins/kanban"},
        data_builder: EzagentPluginKanban.WorldData,
        renderer_families: [{"kanban", "看板"}],
        session_view: %{
          id: "kanban_board",
          state_builder: EzagentPluginKanban.WorldData
        },
        actions:
          ~w(kanban.add_node kanban.rename_node kanban.move_node kanban.remove_node kanban.set_stage kanban.claim_node kanban.unclaim_node kanban.set_status kanban.attach_artifact kanban.detach_artifact kanban.set_metric kanban.create kanban.sync_miro kanban.save_miro_creds kanban.select_board kanban.drop_subtree kanban.set_board_config kanban.attach_upload kanban.register_pr kanban.attach_code_file kanban.share_board kanban.share_to_session kanban.request_edit kanban.approve_edit kanban.receive_shared kanban.delete_board),
        actions_module: EzagentPluginKanban.WorldActions,
        renderer: %{
          source: "assets/src/world_page.tsx",
          export: "KanbanWorldPage",
          full_bleed: true
        }
      }
    ]
  end
end
