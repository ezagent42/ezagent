defmodule EzagentPluginDealScout.Demo do
  @moduledoc """
  The **dealscout demo socialware** — the one source of truth for the dealscout
  manifest and its boot-time publish (the hello #162 golden-template play, the
  same shape as `EzagentPluginKanban.Demo`).

  A fresh stack ships a discoverable, installable **dealscout** socialware,
  seeded by DOGFOODING the real publish path (`Ezagent.Socialware
  .ConfigGovernance.Socialware`: `open_cr → stage_definition → publish_cr`),
  NOT a hard-coded direct ConfigStore write. Every boot exercises the real
  governance flow, so a broken publish path fails LOUD at boot. This module
  supersedes the retired `EzagentPluginDealScout.DefinitionSeed` imperative
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
    * **声明 dealscout 后台** —— `uses: ["hello", "dealscout"]`（依赖两个
      plugin 已装，非组合轴）+ `discover` 角色槽（`dealscout-discover` recipe
      × `cc-headless`，持 crawl cap 的发现副驾）。
    * **routing_rules** —— ONLY the content-triggered update-signal rule
      (`text_contains "__dealscout_update__"` → the `page` role, like the
      kanban `__done__` relay)。**绝不带 hello 的 `always → chat` 规则**
      （kanban handoff 同款红线）。
    * **visibility_policy** —— `scope: public` + `publish_policy: supervised`
      像 hello/kanban，且 `web_anon_access: true`（**与 kanban 的 false 不同**：
      dealscout 的公开面是给匿名访客看的线索页，产品语义要匿名可读）。

  ## The "page" role slot（现读判定，Stage E 收口）

  hello 自己的页面前台（`orch_<name>` orchestrator）**不是 role 槽**：它由
  hello 命令式按名重挂（`EzagentPluginHello.App.ensure_session_orchestrator`），
  hello 自己的 Definition `roles: []`。所以这里不声明（也声明不了）那个
  orchestrator；改为声明一个 `"page"` 角色槽（`hello.builder` recipe ×
  `native` flavor —— hello 真实声明的页面生成 recipe），作为更新信号的声明式
  receiver —— conformance `routing_receivers_resolve`（只认已声明角色名）下
  最干净的写法。

  **已知 runtime 缺口（诚实标）**：今天 `HelloBuilder.handle_receive` 有
  `from_user?` 门（只对 USER-sender 消息触发生成，防自环），而更新信号的
  sender 是爬取 agent —— 信号到达 "page" 成员后今天不会自动触发页面重建。
  信号→页面刷新的 runtime 腿是 Stage E 的 e2e 活，**不在本 Stage 私改 hello**。

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
  @page_role "page"
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
      is pinned `hello.builder × native` by the hello composition (unlike
      kanban, where BOTH slots are cc-headless and both swap).

  The returned map is `ManifestResolver.resolve/1`-ready (name refs, not
  modules): `views: ["hello_render"]` resolves through hello's registered
  `PageView` to `Ezagent.ActionSet.HelloRender`; `uses: ["hello",
  "dealscout"]` requires both plugins registered — true once both apps booted
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
      "uses" => ["hello", "dealscout"],
      # hello 公开面配置逐项复制（hello `app.ex` `seed_hello_definition`）：
      # 会话有 Surface（页面）+ Turn（生成回合）→ 是 page session。
      "bases" => [
        "Elixir.Ezagent.ActionSet.Session",
        "Elixir.Ezagent.ActionSet.Publisher.SessionImpl"
      ],
      "shape" => [
        "Elixir.Ezagent.ActionSet.Turn",
        "Elixir.Ezagent.ActionSet.Surface"
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
        # hello 页面 agent 槽：更新信号的声明式 receiver（moduledoc §The
        # "page" role slot —— hello 的 orch_<name> 前台是命令式 ensure，不走
        # role 槽；这里声明的是 hello.builder 页面生成 recipe）。
        %{
          "role_name" => @page_role,
          "fill" => "agent",
          "recipe" => "hello.builder",
          "flavor" => "native"
        }
      ],
      # ONLY the content-triggered update rule（kanban relay `__done__` 同款）：
      # 爬完的更新信号 → "page" 角色。标记从 update_signal/0 取（单一契约点），
      # 不硬编码。NEVER hello's `always → chat` rule.
      "routing_rules" => [
        %{
          "matcher" => %{
            "type" => "text_contains",
            "arg" => Ezagent.ActionSet.DealScoutCrawl.update_signal()
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
