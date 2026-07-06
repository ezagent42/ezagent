defmodule EzagentPluginDealScout.Application do
  @moduledoc """
  dealscout socialware plugin — the `Ezagent.Plugin` contract module.

  DealScout = 商业 / 投融资线索的搜索与撮合平台（deal 侦察兵）。

  ## 职责边界（2026-07-06 拍板）

  层级 plugin → socialware → ezagent。DealScout 整体是一个 **socialware（纯配置
  组合）**，本 plugin 是它唯一的真代码件——**爬取后台**（poller / fetch / config /
  crawl ActionSet / recipes / sweeper）。**显示是 hello 的活**：本 plugin **不声明**
  任何 SessionView / render ActionSet（曾有的 `DealScoutView` / `DealScoutRender`
  已删）；DealScout Definition 的 `views` 引 hello 的 `hello_render`。

  两个 socialware 的 agent 用**内容协议 routing** 连（跟 kanban-team relay 一样）：
  dealscout 的爬取 agent 爬完注入新线索后 emit 一个更新信号
  （`Ezagent.ActionSet.DealScoutCrawl.update_signal/0`，`"__dealscout_update__"`，
  像 kanban 的 `__done__`）→ Definition 的 routing_rules 用 `text_contains`
  matcher 命中 → 转给 `{:role, <hello 页面 agent 角色>}` → hello 的 agent 更新
  json-render 页。零实例 URI、不数据直推、dealscout 自己不渲染。

  ## Plugin authoring contract

  Per the plugin authoring contract the OTP `Application` module IS the plugin
  contract module: it `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`, which starts `children/0` FIRST then publishes every
  declaration — the author never touches a `*Registry` API. The
  `:ezagent_plugin_check` Mix compiler is the non-bypassable gate.

  ## Declared surface

  `plugin_info/0` + `children/0`（爬取 `Poller` + `RetentionSweeper`）+ `roles/0`
  （发现腿 recipes）。不声明 `behaviors/0` / view —— 其余 `Ezagent.Plugin`
  callback 保持 `use`-macro 默认（`[]` / `nil` / `:ok`）。boot 时经真 governance
  flow **publish** dealscout demo socialware（`Demo.publish/0`，hello #162 /
  kanban 黄金样板 —— 取代了早期 imperative `DefinitionSeed` code-seed）。
  """

  use Application
  use Ezagent.Plugin

  # Compile-time env (works in stripped OTP releases where `Mix` is unavailable).
  @compile_env Mix.env()

  @impl Application
  def start(_type, _args) do
    # 不注册任何 SessionView / render ActionSet —— 显示归 hello（见 moduledoc
    # 职责边界）。本 plugin 只 boot 爬取后台。
    result = Ezagent.Plugin.boot(__MODULE__)

    # Boot-publish the dealscout DEMO socialware as a PUBLIC catalog entry via
    # the REAL governance flow (`ConfigGovernance.Socialware`), the hello #162
    # golden-template play — a fresh stack ships a discoverable/installable
    # dealscout AND every boot dogfoods the publish path (a broken publish path
    # fails LOUD here at boot). This REPLACES the earlier imperative
    # `DefinitionSeed.seed_definition` code-seed (`seed_definition_if_absent`):
    # publish is the only boot seeding path now (hello/kanban parity). Runs in
    # `start/2` AFTER `Ezagent.Plugin.boot/1` — the publish resolves
    # `uses: ["hello", "dealscout"]` + the `hello_render` view, which need THIS
    # plugin's plugin_info registered (hello booted earlier as a declared dep).
    # Idempotent (`publish_or_upgrade`: :published / :exists / :upgraded);
    # fail-loud in dev/prod (mirrors hello `maybe_publish_hello_demo` / kanban
    # `maybe_publish_kanban_demo`), skipped in `:test` (the DB write at plugin
    # boot contends with the per-test Ecto sandbox — ExUnit drives
    # `Demo.publish/0` inside a checked-out sandbox instead, see
    # `demo_publish_test.exs`).
    :ok = maybe_publish_dealscout_demo()

    result
  end

  defp maybe_publish_dealscout_demo do
    if @compile_env == :test do
      :ok
    else
      case EzagentPluginDealScout.Demo.publish() do
        {:ok, _published_exists_or_upgraded} ->
          :ok

        {:error, reason} ->
          raise "EzagentPluginDealScout boot aborted — the dealscout demo socialware " <>
                  "could not be published via the governance flow (fail-loud dogfood, " <>
                  "hello #162 play): #{inspect(reason)}"
      end
    end
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "dealscout",
      name: "dealscout",
      description: "dealscout discovery + matchmaking socialware",
      version: "0.1.0"
    }
  end

  # The crawl `Poller` GenServer. Skipped in `:test` (and any env where
  # `:skip_poller` is set) so the test suite never starts a real timer that
  # would hit the network — mirrors `Ezagent.Email.Inbound`'s test-boot skip.
  @impl Ezagent.Plugin
  def children do
    if Application.get_env(:ezagent_plugin_dealscout, :skip_poller, @compile_env == :test) do
      []
    else
      [EzagentPluginDealScout.Poller, EzagentPluginDealScout.RetentionSweeper]
    end
  end

  # Discovery-leg recipes (role-as-data, RF-4): boot seeds each into
  # `Ezagent.Agent.RecipeRegistry` by `name`. Flavor-agnostic — flavor is chosen
  # per-agent on the Definition role-slot (a later Stage), never on the recipe.
  @impl Ezagent.Plugin
  def roles, do: EzagentPluginDealScout.Recipes.all()
end
