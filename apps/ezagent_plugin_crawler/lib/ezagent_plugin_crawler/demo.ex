defmodule EzagentPluginCrawler.Demo do
  @moduledoc """
  The **dealscout demo socialware** — the one source of truth for the dealscout
  manifest and its boot-time publish (the hello #162 golden-template play, the
  same shape as `EzagentPluginKanban.Demo`).

  A fresh stack ships a discoverable, installable **dealscout** socialware,
  seeded by DOGFOODING the real publish path (`Ezagent.Socialware
  .ConfigGovernance.Socialware`: `open_cr → stage_definition → publish_cr`),
  NOT a hard-coded direct ConfigStore write. Every boot exercises the real
  governance flow, so a broken publish path fails LOUD at boot. This module
  supersedes the retired `EzagentPluginCrawler.DefinitionSeed` imperative
  code-seed (`DefinitionRegistry.seed_definition_if_absent`) — publish is now
  the ONLY boot seeding path (hello/kanban parity).

  ## One definition of truth

  `manifest_attrs/1` returns the config-authored manifest shape (string
  name-refs, `ManifestResolver.resolve/1`-ready). Tests source their fixture
  manifests from here with per-run unique names / a stub flavor
  (parallel-test isolation, no cc SDK sidecar); the boot path calls it with
  the stable demo defaults (`name: "dealscout"`).

  ## What dealscout composes (职责重划，2026-07-06 拍板)

  dealscout = 后台数据（爬取 plugin + discover agent 用 crawl 能力爬线索），
  hello = 显示 + concierge。本 manifest 是把两者**组合成一个 socialware**的
  那份纯数据：

    * **组合 hello 公开面（零改 hello）** —— `bases`/`shape` 复制 hello 的
      公开面配置（`Session` + `Publisher.SessionImpl` / `Turn` + `Surface`），
      `adapters` 带 `external_feed`（外部只读投影）；`views: ["hello_render"]`
      经 registered `PageView` 解析到 `Ezagent.ActionSet.HelloRender` —— hello
      的 `PageView` 以 `"hello" in definition.uses or HelloRender in
      definition.views` 认领渲染（`page_view.ex` `manifest_installed_hello?`），
      dealscout 自己**不声明任何 view / render**。
    * **声明爬取后台** —— `uses: ["hello", "crawler"]`（依赖两个 plugin 已装，
      非组合轴；rename 后爬取 plugin 的 slug 是 `crawler`，"dealscout" 只是
      本 socialware 的名字）+ `discover` 角色槽（`dealscout-discover` recipe
      × `cc-headless`，持 crawl cap 的发现副驾）。
    * **routing_rules** —— ONLY the content-triggered update-signal rule
      (`and(text_contains "__dealscout_update__", from_role "discover")` →
      the `page` role, like the kanban `__done__` relay；from_role 硬锁是
      #1212 落地后的 #1201 ⑥ 预案加固)。**绝不带 hello 的 `always → chat`
      规则**（kanban handoff 同款红线）。
    * **visibility_policy** —— `scope: public` + `publish_policy: supervised`
      像 hello/kanban，且 `web_anon_access: true`（**与 kanban 的 false 不同**：
      dealscout 的公开面是给匿名访客看的线索页，产品语义要匿名可读）。

  ## The "page" role slot（现读判定，Stage E 收口）

  hello 自己的页面前台（`orch_<name>` orchestrator）**不是 role 槽**：它由
  hello 命令式按名重挂（`EzagentPluginHello.App.ensure_session_orchestrator`），
  hello 自己的 Definition `roles: []`。所以这里不声明（也声明不了）那个
  orchestrator；改为声明一个 `"page"` 角色槽（× `native` flavor），作为更新
  信号的声明式 receiver —— conformance `routing_receivers_resolve`（只认已
  声明角色名）下最干净的写法。

  **【显式临时 ALT】page 槽当前指 `dealscout-page-alt`**（本插件自己的
  `Ezagent.ActionSet.DealScoutPageRefreshAlt`，v2 caller-dispatch 式：crawl
  完成后直接 dispatch `:refresh_page` 到 page 成员 → 调 hello 公开生成入口
  `EzagentPluginHello.Generator.start/2` 重建页面）。本意的写法是 hello 真实
  声明的页面生成 recipe `hello.builder`，但真 e2e 实测 receive 腿到 native
  成员是断的（#1201 ② —— canonical `agent.receive` 只塞 bridge，native 无
  bridge 必丢），且 `HelloBuilder.handle_receive` 的 `from_user?` 门也会丢
  agent-sender 信号（#1201 ③）。**A①（hello 暴露 dispatchable rebuild
  action）落地后：删除 ALT ActionSet + `dealscout-page-alt` recipe，page 槽
  一行回切 `hello.builder`**（槽声明处的注释）。不在本插件私改 hello
  （自包含红线）。routing_rules 的更新信号规则保留（会话内可见的声明式痕迹）。

  ## Where it publishes

  Into `workspace://system` as a `scope: :public` definition — cross-workspace
  discoverable via `DefinitionRegistry.list/1` from EVERY workspace; users
  self-install through the normal discover→install flow.

  ## Authority

  `caller` = the bootstrap admin URI (`user://system/admin`), `caps` = the
  socialware `manage` cap for `dealscout` in the system workspace +
  `Ezagent.Capability.admin_genesis_cap/0` (the admin gate `publish_cr/2`
  requires for a `:public` scope).

  ## Idempotency

  `publish/0` routes through the shared idempotency RULE
  (`ConfigGovernance.Socialware.publish_or_upgrade/2`, P0 §5): first publish →
  `{:ok, :published}`; an unchanged redeploy no-ops to `{:ok, :exists}` WITHOUT
  opening a CR; an EDITED manifest re-promotes to `{:ok, :upgraded}`. Combined
  with the fail-loud boot guard at the call site, a partial publish crashes the
  boot rather than silently accumulating CRs.
  """

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, ManifestResolver}
  alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance

  @name "dealscout"
  @discover_role "discover"
  # page 角色槽名从 Crawler.page_role/0 取（单一契约点，照
  # update_signal/0）—— crawl 的直接 dispatch 腿按同一个名字解析 page 成员。
  @page_role Ezagent.ActionSet.Crawler.page_role()
  @default_discover_flavor "cc-headless"
  @update_rule_set "dealscout-update"

  @doc "The stable demo socialware name (`\"dealscout\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

  @doc """
  The dealscout demo manifest attributes (config-authored, string name-refs).

  Options (all default to the stable demo values):
    * `:name` — the socialware/definition name (default `"dealscout"`; tests
      pass per-run unique names for parallel-test isolation)
    * `:flavor` — the flavor the `discover` agent role-slot materializes on
      (default `"cc-headless"`; integration tests can swap in a bare-spawn
      stub so no cc SDK sidecar starts). The `page` slot is NOT swapped — it
      is pinned `dealscout-page-alt × native`（临时 ALT，A① 落地后回切
      `hello.builder`，moduledoc §The "page" role slot）(unlike kanban,
      where BOTH slots are cc-headless and both swap).

  The returned map is `ManifestResolver.resolve/1`-ready (name refs, not
  modules): `views: ["hello_render"]` resolves through hello's registered
  `PageView` to `Ezagent.ActionSet.HelloRender`; `uses: ["hello",
  "crawler"]` requires both plugins registered — true once both apps booted
  (hello is a declared dep of this plugin).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    flavor = Keyword.get(opts, :flavor, @default_discover_flavor)

    %{
      "name" => name,
      "version" => "0.1.0",
      "title" => "DealScout",
      "description" => "商业/投融资线索侦察：AI 千人千面发现 deal + 组合 hello 公开面撮合。",
      "uses" => ["hello", "crawler"],
      # hello 公开面配置逐项复制（hello `app.ex` `seed_hello_definition`）：
      # 会话有 Surface（页面）+ Turn（生成回合）→ 是 page session。
      "bases" => [
        "Elixir.Ezagent.ActionSet.Session",
        "Elixir.Ezagent.ActionSet.Publisher.SessionImpl"
      ],
      "shape" => [
        "Elixir.Ezagent.ActionSet.Turn",
        "Elixir.Ezagent.ActionSet.Surface",
        # 2026-07-07 真浏览器 e2e 发现并修正：`:crawl_now` 的 handler 读
        # `ctx.session_uri`（只在 session:// 目标上派生）+ `ctx[:read]`（session
        # 的 config slice）→ 宿主必须是 **session 本体**。此前 shape 没带
        # Crawler，任何 live dispatch 都 `{:unknown_action, :crawl_now}`
        # （发现 recipe 的 `requested_caps` 只管 agent 作为 caller 的持权，不给
        # session 装 handler）。单测直接调 handle_crawl_now 掩盖了这个缺口。
        "Elixir.Ezagent.ActionSet.Crawler"
      ],
      # 显示归 hello：引 hello 的 render view（页面读权限门），dealscout 无
      # 自有 view / render。
      "views" => ["hello_render"],
      # #1180 role-slot：只声明角色槽，绝不声明参与者实例 URI。
      "roles" => [
        # 发现副驾（dealscout 后台的 agent）：持 crawl cap，主动爬取 + 千人
        # 千面挑机会；cc-headless（真 brain，能收 agent 消息主动干活）。
        %{
          "role_name" => @discover_role,
          "fill" => "agent",
          "recipe" => "dealscout-discover",
          "flavor" => flavor
        },
        # hello 页面 agent 槽：页面重建的宿主（moduledoc §The "page" role
        # slot —— hello 的 orch_<name> 前台是命令式 ensure，不走 role 槽）。
        # 【显式临时 ALT，v2 caller-dispatch 式】receive 腿到 native 成员是
        # 断的（#1201 ②），所以槽指本插件的 ALT recipe：crawl 完成后按
        # role_name 解析本槽成员，直接 dispatch `:refresh_page`（→ 调
        # `EzagentPluginHello.Generator.start/2` 重建页面）。
        # A①（hello 暴露 dispatchable rebuild action）落地后一行回切
        # （并删除 ALT ActionSet + recipe）：
        #   "recipe" => "hello.builder",
        %{
          "role_name" => @page_role,
          "fill" => "agent",
          "recipe" => "dealscout-page-alt",
          "flavor" => "native"
        }
      ],
      # ONLY the content-triggered update rule（kanban relay `__done__` 同款）：
      # 爬完的更新信号 → "page" 角色。标记从 update_signal/0 取（单一契约点），
      # 不硬编码。NEVER hello's `always → chat` rule.
      #
      # 注意：page 槽当前走 ALT v2 的 **dispatch 直呼腿**（crawl 完成后按
      # role_name 直接 dispatch `:refresh_page`，不经这条 routing）——本规则是
      # **声明痕迹 + A① 落地后回切 receive 式的靶子**（Crawler moduledoc
      # §页面重建的直接 dispatch 腿），加固照做以免回切时才补硬锁。
      "routing_rules" => [
        %{
          # #1212 from_role 落地后的硬锁加固（#1201 ⑥ 预案，kanban 同款）：
          # 内容标记（软锁）AND 发件人必须是 discover 角色成员——其他成员
          # 发同标记不再误触发。
          "matcher" => %{
            "type" => "and",
            "items" => [
              %{
                "type" => "text_contains",
                "arg" => Ezagent.ActionSet.Crawler.update_signal()
              },
              %{"type" => "from_role", "arg" => @discover_role}
            ]
          },
          "receivers" => [@page_role],
          "rule_set" => @update_rule_set,
          "position" => 0
        }
      ],
      "prompt_templates" => %{},
      "legends" => %{
        "dealscout" => %{
          "member_set" => [@discover_role, @page_role],
          "bound_rule_set" => @update_rule_set,
          "fold" => false
        }
      },
      # 公开面外部只读投影（匿名访客经 socialware external SPA 看页 + 线索流）。
      "adapters" => [%{"adapter_id" => "external_feed", "role" => "customer", "config" => %{}}],
      # scope public（全域跨 ws 可发现，admin-gated —— publish ctx 带
      # admin_genesis_cap）+ 匿名可读（dealscout 公开面要匿名可看，产品语义，
      # 与 kanban 的 web_anon_access: false 不同）。
      "visibility_policy" => %{
        "scope" => "public",
        "publish_policy" => "supervised",
        "web_anon_access" => true
      }
    }
  end

  @doc """
  Publish the dealscout demo as a PUBLIC socialware in `workspace://system` via
  the real governance flow, through the shared idempotency RULE (P0 §5): a
  first publish is `:published`, an unchanged redeploy no-ops to `:exists` (no
  CR opened), and an EDITED manifest re-promotes to `:upgraded`.
  """
  @spec publish() :: {:ok, :published | :upgraded | :exists} | {:error, term()}
  def publish do
    ws = Ezagent.URI.workspace(:system)
    admin = Ezagent.URI.user(:system, :admin)
    ctx = admin_ctx(admin, ws)

    with {:ok, %Definition{} = definition} <- ManifestResolver.resolve(manifest_attrs()) do
      Governance.publish_or_upgrade(definition, ctx)
    end
  end

  @doc """
  Whether the dealscout demo is already present as a PUBLIC definition (the
  idempotency predicate).
  """
  @spec published?() :: boolean()
  def published?, do: already_public?(Ezagent.URI.workspace(:system))

  defp admin_ctx(admin, ws) do
    %{
      caller: admin,
      workspace_uri: ws,
      caps:
        MapSet.new([
          Governance.manage_cap(@name, ws, admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  defp already_public?(ws) do
    case DefinitionRegistry.lookup(ws, @name) do
      {:ok, %Definition{visibility_policy: %{scope: :public}}, _object} -> true
      _ -> false
    end
  end
end
