defmodule EzagentPluginDealScout.DefinitionSeed do
  @moduledoc """
  The `socialware:dealscout` Definition（Stage D，**纯配置 config-as-data**，照
  kanban `EzagentPluginKanban.KanbanTeam` 的结构）。经 code-seed（imperative
  `DefinitionRegistry.seed_definition_if_absent/2`，hello / kanban 同款）发布，
  **不打进 plugin 包 manifest**（`core/manifest.ex` 有意拒 `:socialware`
  seed_ref，Allen 决策 #1147/#1152）。

  ## 职责重划（2026-07-06 返工拍板）

  dealscout = 后台数据（爬取 plugin + discover agent 用 crawl 能力爬线索），
  hello = 显示 + concierge。本 Definition 是把两者**组合成一个 socialware**
  的那份纯数据：

    * **组合 hello 公开面（零改 hello 代码）** —— `bases`/`shape` 逐项复制
      hello 的 `seed_hello_definition`（`Session` + `Publisher.SessionImpl` /
      `Turn` + `Surface`），`adapters` 带 `external_feed`（外部只读投影），
      `visibility_policy.web_anon_access: true`（匿名可看，发布者自助）+
      `scope: :private`（不进全域 catalog，不触发 admin 门）。
      `views: [Ezagent.ActionSet.HelloRender]` —— hello 的 `PageView` 以
      `"hello" in definition.uses or HelloRender in definition.views` 认领
      渲染（`page_view.ex` `manifest_installed_hello?`），dealscout 自己
      **不声明任何 view / render**。
    * **声明 dealscout 后台** —— `uses: ["hello", "dealscout"]`（依赖两个
      plugin 已装，非组合轴）+ `discover` 角色槽（`dealscout-discover` recipe
      × `cc-headless` flavor，持 crawl cap 的发现副驾）。
    * **wiring = 内容协议 routing（像 kanban-team relay `__done__`）** —— 见下。

  ## 更新信号 routing（内容协议，零实例 URI）

  爬取 ActionSet（`Ezagent.ActionSet.DealScoutCrawl`）注入新线索后 emit
  `update_signal/0`（`"__dealscout_update__"`）消息；这里的 routing rule 用
  `text_contains` 命中它，转给声明的 `"page"` 角色（`{:role, name}` 在投递期经
  `:member_by_role` 解析成该 session 成员的 URI）。规则**内容触发、无
  sender-lock、零参与者实例 URI**——materialize 在随机 UUID URI spawn 成员后，
  live rule（以及 snapshot 回读成 Definition）仍干净，过
  `reject_participant_instance_uris`（round-trip 安全，kanban S3 同款论证）。

  ## "page" 槽的现读判定（open decision，Stage E 收口）

  hello 自己的页面前台（`orch_<name>` orchestrator）**不是 role 槽**：它由
  hello 命令式按名重挂（`EzagentPluginHello.App.ensure_session_orchestrator`，
  对任何经 world 路径建的 page session 都补），hello 自己的 Definition
  `roles: []`。所以这里不声明（也声明不了）那个 orchestrator；改为声明一个
  `"page"` 角色槽（`hello.builder` recipe × `native` flavor —— hello 真实声明
  的页面生成 recipe，`EzagentPluginHello.Application.hello_builder_recipe/0`），
  作为更新信号的声明式 receiver —— 这是 conformance
  `routing_receivers_resolve`（只认已声明角色名）下最干净的写法。

  **已知 runtime 缺口（诚实标）**：今天 `HelloBuilder.handle_receive` 有
  `from_user?` 门（只对 USER-sender 消息触发生成，防自环），而更新信号的
  sender 是爬取 agent —— 信号到达 "page" 成员后今天不会自动触发页面重建。
  信号→页面刷新的 runtime 腿是 Stage E 的 e2e 活（方案：hello 侧放行带标记的
  agent 信号，或 dealscout 侧以 user-authority 转发），**不在本 Stage 私改
  hello**。声明面（roles / routing / views）按目标形态落定，不用返工。
  """

  @definition_name "dealscout"

  @doc """
  The `dealscout` Definition body (config-as-data)。17 字段 struct 的子集；
  `Definition.new/1` 是校验边界（拒退休 `agents`/`members` 字段、拒参与者/
  owner 实例 URI、拒 `:fixed` owner）。
  """
  @spec definition_body() :: map()
  def definition_body do
    %{
      name: @definition_name,
      title: "DealScout",
      description: "商业/投融资线索侦察：AI 千人千面发现 deal + 组合 hello 公开面撮合。",
      # 依赖声明（manifest_resolver ensure_plugins_installed）：hello 出显示
      # 面（HelloRender / builder recipe），dealscout 出爬取后台 + discover。
      uses: ["hello", "dealscout"],
      # hello 公开面配置逐项复制（hello `app.ex` `seed_hello_definition`）：
      # 会话有 Surface（页面）+ Turn（生成回合）→ 是 page session。
      bases: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Publisher.SessionImpl
      ],
      shape: [
        Ezagent.ActionSet.Turn,
        Ezagent.ActionSet.Surface
      ],
      # 显示归 hello：引 hello 的 render view（页面读权限门），dealscout 无
      # 自有 view / render（曾有的 DealScoutView / DealScoutRender 已删）。
      views: [Ezagent.ActionSet.HelloRender],
      # #1180 role-slot：只声明角色槽，绝不声明参与者实例 URI。
      roles: [
        # 发现副驾（dealscout 后台的 agent）：持 crawl cap，主动爬取 + 千人
        # 千面挑机会；cc-headless（真 brain，能收 agent 消息主动干活）。
        %{
          role_name: "discover",
          fill: :agent,
          recipe: "dealscout-discover",
          flavor: "cc-headless"
        },
        # hello 页面 agent 槽：更新信号的声明式 receiver（见 moduledoc
        # §"page" 槽的现读判定 —— hello 的 orch_<name> 前台是命令式 ensure，
        # 不走 role 槽；这里声明的是 hello.builder 页面生成 recipe）。
        %{role_name: "page", fill: :agent, recipe: "hello.builder", flavor: "native"}
      ],
      # 内容协议 routing（kanban relay `__done__` 同款）：爬完的更新信号 →
      # "page" 角色。标记从 update_signal/0 取（单一契约点），不硬编码。
      routing_rules: [
        %{
          "matcher" => %{
            "type" => "text_contains",
            "arg" => Ezagent.ActionSet.DealScoutCrawl.update_signal()
          },
          "receivers" => ["page"],
          "rule_set" => "dealscout-update",
          "position" => 0
        }
      ],
      legends: %{},
      prompt_templates: %{},
      # 公开面外部只读投影（匿名访客经 socialware external SPA 看页 + 白板）。
      adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
      # 匿名可读自助开（发布者自助，不需 admin）；scope :private（全域跨 ws
      # 发现才要 admin 门，本 Definition 不触发）。
      visibility_policy: %{publish_policy: :auto, web_anon_access: true, scope: :private},
      # #1180：owner 只准 install 时由 caller 派生（`:fixed` 被拒）。
      owner_policy: %{type: :installer}
    }
  end

  @doc """
  Code-seed the `dealscout` Definition into `ws`（默认 `workspace://system`），
  幂等（`seed_definition_if_absent/2`，不覆盖已有 override）。`actor_uri` 结构化
  派生 system admin（`Ezagent.URI.user(:system, :admin)`），不依赖 identity 域
  —— kanban `KanbanTeam.seed_definition/1` 同款。
  """
  @spec seed_definition(URI.t()) :: {:ok, term()} | {:error, term()}
  def seed_definition(ws \\ Ezagent.URI.workspace(:system)) do
    Ezagent.Socialware.DefinitionRegistry.seed_definition_if_absent(
      definition_body(),
      workspace_uri: ws,
      actor_uri: Ezagent.URI.user(:system, :admin)
    )
  end
end
