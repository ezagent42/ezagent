defmodule EzagentPluginCrawler.Application do
  @moduledoc """
  crawler plugin — the `Ezagent.Plugin` contract module.

  ## 分层（2026-07-07 rename 拍板：plugin = 通用能力，socialware = 配置出来的名字）

  本 plugin 是**通用爬取能力**（fetch / config / crawl ActionSet），
  与业务无关；**"dealscout"（科技创业/新品动态的线索雷达 demo，
  数据源 = Hacker News 公开检索 API——D4 数据源诚实化，措辞与真数据相符）是
  socialware 的名字**——一份纯配置组合（deploy-seed 包
  `apps/ezagent_web/priv/socialware_seed/dealscout/manifest.yaml`：组合本
  plugin 的爬取后台 + 自带线索 view + 平台公开面组件），不是代码层的名字（Decision #156：
  socialware = config-only bundle，plugin 侧零 socialware 专属代码壳）。
  历史上 app 叫 `ezagent_plugin_dealscout` 把两层混了，故 rename。

  **显示自包含（2026-07-10 段4 D2，照 kanban BoardView 模具）**：本 plugin
  声明自己的结构化线索 view——`EzagentPluginCrawler.LeadsView`（SessionView）+
  `Ezagent.ActionSet.CrawlerRender`（cap-only render ActionSet）。view 渲染的
  是会话 `Ezagent.ActionSet.Crawler` slice 里留存的真实爬取产物（`:items`），
  与业务无关（任何组合本能力的 socialware 在 manifest `views:
  [crawler_render]` 一行接入）；world 通用消费 registry（#1192/#1199），
  零 world 改动。

  agent 间用**内容协议 routing** 连（跟 kanban-team relay 一样）：
  发现 agent 的带信号回复（`Ezagent.ActionSet.Crawler.update_signal/0`，缺省
  `"__dealscout_update__"`，像 kanban 的 `__done__`）→ Definition 的
  routing_rules matcher 命中 → 转给 `{:role, "orchestrator"}`（编排脑，
  2026-07-10 零人工中继修正——照 kanban"信号给操作员、操作员 dispatch 工具
  动作"先例），由它 dispatch 会话的 `:search`/`:crawl_now` 正式入库。零实例
  URI、不数据直推；页面发布的生产腿是 Crawler 的 caller-dispatch 直呼到
  `page` 成员（native 工具从不收 chat：receive 投递到 native 成员是平台 gap
  #1201 ②，绕开不修）。

  ## Plugin authoring contract

  Per the plugin authoring contract the OTP `Application` module IS the plugin
  contract module: it `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`, which starts `children/0` FIRST then publishes every
  declaration — the author never touches a `*Registry` API. The
  `:ezagent_plugin_check` Mix compiler is the non-bypassable gate.

  ## Declared surface

  `plugin_info/0` + `roles/0`（dealscout 业务 recipes——demo socialware 的
  agent 配方，随 demo 一起 ship 在本 plugin）+ `behaviors/0`（LeadsView 的
  `{Session, :crawler_render}` render cap subject，照 kanban S4 先例）。
  **零周期后台**（2026-07-10 段2：`Poller` 抓完即丢、`RetentionSweeper` 是
  no-op stub——durable 批次 slice 从未接线——两条空转腿都删了；爬取 =
  agent 驱动 `:crawl_now`，数据保留 = 会话消息历史 + 结构化 `:items`
  slice）；`children/0` 只有页面发布腿的 `Task.Supervisor`（段4 D2，非
  轮询件）。其余 `Ezagent.Plugin`
  callback 保持 `use`-macro 默认（`[]` / `nil` / `:ok`）。dealscout demo
  socialware **不在本 plugin boot 发布**：它以 deploy-seed 包形式随发布箱走
  （`apps/ezagent_web/priv/socialware_seed/dealscout/manifest.yaml`，与
  autoservice / hello / kanban 同架），由 `Ezagent.Home.SocialwareSeed` 拷进
  部署 home、late boot scan `Ezagent.Socialware.ManifestSeed.scan_all!/1` 经
  governed import lane 发布（hello #162 / kanban deploy-seed 迁移套路）。
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    result = Ezagent.Plugin.boot(__MODULE__)

    # dealscout-assistant（cc-headless 入库操作员）的工作目录。cc-headless
    # 物化的缺省 cwd = `~/.ezagent/<recipe名>`（`DefaultAgentSeed.
    # default_project_cwd/1`，recipe 无 config[:project_cwd] 时的回落），但
    # 平台不替 role agent 建目录——sidecar spawn `Cannot chdir` 必崩（2026-07-10
    # 零人工中继 e2e 实测）。照 `CcOrchestratorSeed.ensure_sandbox_files`
    # mkdir 自己 sandbox base 的先例，声明该 recipe 的插件负责保证目录在。
    _ =
      File.mkdir_p(
        Path.join([System.user_home() || System.tmp_dir!(), ".ezagent", "dealscout-assistant"])
      )

    # 仓库根指针（部署运行时数据，非 shipped 常量）：SDK sidecar 车道不给
    # agent cwd 写 .mcp.json（那是 PTY 车道 McpConfigWriter 的三处写之一），
    # 09m 实测 assistant 在空 cwd 里定位不到仓库根、CLI 跑不起来。boot 时把
    # 本运行时的仓库根写成 cwd 里的 REPO_ROOT 指针文件，skill/persona 第 1 步
    # `cat ./REPO_ROOT` 读它——与 McpConfigWriter 往 agent cwd 写共享配置的
    # 先例同类（机器相关的值在运行时落盘，不进代码/manifest）。
    _ =
      File.write(
        Path.join([
          System.user_home() || System.tmp_dir!(),
          ".ezagent",
          "dealscout-assistant",
          "REPO_ROOT"
        ]),
        File.cwd!()
      )

    # 段4 D2（照 kanban S4）——register the leads SessionView (declaration side;
    # world consumes the registry generically per world-views #1192/#1199, so
    # this needs ZERO world changes). The registry is init'd by
    # ezagent_domain_ui, which boots before this plugin (a declared dep).
    _ = Ezagent.UI.SessionViewRegistry.register(EzagentPluginCrawler.LeadsView)

    # NOTE: the dealscout DEMO socialware is NOT published here. It ships as a
    # deploy-seed package (`apps/ezagent_web/priv/socialware_seed/dealscout/
    # manifest.yaml`, like `autoservice` / `hello` / `kanban`):
    # `Ezagent.Home.SocialwareSeed` copies it into the deployment home and the
    # late boot scan `Ezagent.Socialware.ManifestSeed.scan_all!/1` (run from the
    # last-booting transport app, AFTER this plugin registered its plugin_info +
    # `LeadsView` so the `uses` + the `crawler_render` view resolve) publishes
    # it through the governed import lane.
    # Zero call from this plugin's boot AND zero plugin-side wrapper module —
    # tests drive the SAME shipped file directly via
    # `Ezagent.Socialware.ShippedManifest.load!/2` (deploy-seed SPEC §2/§4, the
    # hello #162 play; Decision #156).
    result
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "crawler",
      name: "crawler",
      description: "generic crawl capability plugin (ships the dealscout demo socialware)",
      version: "0.1.0"
    }
  end

  # 唯一 child 是页面发布腿的 Task.Supervisor（段4 D2：`CrawlerPage`
  # handler 秒回，publish 的顺序 `:call` 串在 supervised Task 里跑）——
  # 不是周期后台（`Poller` / `RetentionSweeper` 两条空转腿 2026-07-10 段2
  # 删除，零轮询 GenServer 的纪律不变；Task.Supervisor 只监督显式触发的
  # fire-and-forget 发布任务）。
  @impl Ezagent.Plugin
  def children do
    [
      {Task.Supervisor, name: EzagentPluginCrawler.TaskSupervisor}
    ]
  end

  # Discovery-leg recipes (role-as-data, RF-4): boot seeds each into
  # `Ezagent.Agent.RecipeRegistry` by `name`. Flavor-agnostic — flavor is chosen
  # per-agent on the Definition role-slot (a later Stage), never on the recipe.
  @impl Ezagent.Plugin
  def roles, do: EzagentPluginCrawler.Recipes.all()

  # 段4 D2（照 kanban S4 的 ONE static binding）：leads view 的
  # `<sw>_render` cap subject on the Session Kind. Cap-only
  # (`dispatchable?/0 → false`) so this writes only the
  # `{Session, :crawler_render}` cap subject — no dispatch route. This is the
  # cap `SessionView.authorize_view/3` (T2-2b) checks for the leads view, and
  # what the socialware conformance gate (views_exist_caps_registered /
  # view_caps_gate_ready) requires for `Definition.views: [CrawlerRender]`.
  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Session, :crawler_render, Ezagent.ActionSet.CrawlerRender},
      # 2026-07-10 零人工中继 round-3：把爬取动作注册成 Session Kind 的全局
      # dispatchable 行为（email plugin 先例——`{SessionKind, action,
      # EmailAllow}`，插件契约的 sanctioned 车道）。这给 orchestrator 一个
      # **正规 CLI 工具面**：`mix ezagent session crawl_now/search`（identity
      # → runtime 内 Exec → Router.dispatch，cookie 由官方 CLI 内部处理）。
      # 真 e2e 实测（docs/e2e/2026-07-10/dealscout-rework-final 09e/09g）：
      # cc 真脑两轮拒绝"消息教它拿集群 cookie 起节点"的 stand-in 机制
      # （拒得对——cookie = 集群根凭证），点名要正规工具面；本注册就是
      # 那个工具面。CapBAC 不变：caller 无 crawl/search cap 照拒
      # （orchestrator 的 within-session delegation 只覆盖自己会话）。
      {Ezagent.Entity.Session, :crawl_now, Ezagent.ActionSet.Crawler},
      {Ezagent.Entity.Session, :search, Ezagent.ActionSet.Crawler}
    ]
  end
end
