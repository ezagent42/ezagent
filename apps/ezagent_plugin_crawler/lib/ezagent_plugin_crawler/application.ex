defmodule EzagentPluginCrawler.Application do
  @moduledoc """
  crawler plugin — the `Ezagent.Plugin` contract module.

  ## 分层（2026-07-07 rename 拍板：plugin = 通用能力，socialware = 配置出来的名字）

  本 plugin 是**通用爬取能力**（poller / fetch / config / crawl ActionSet /
  sweeper），与业务无关；**"dealscout"（商业 / 投融资线索的搜索与撮合平台）是
  socialware 的名字**——一份纯配置组合（`EzagentPluginCrawler.Demo` 的
  manifest：组合 hello 公开面 + 本 plugin 的爬取后台），不是代码层的名字。
  历史上 app 叫 `ezagent_plugin_dealscout` 把两层混了，故 rename。

  **显示是 hello 的活**：本 plugin **不声明**任何 SessionView / render
  ActionSet（曾有的 `DealScoutView` / `DealScoutRender` 已删）；dealscout
  Definition 的 `views` 引 hello 的 `hello_render`。

  两个 socialware 的 agent 用**内容协议 routing** 连（跟 kanban-team relay 一样）：
  爬取 agent 爬完注入新线索后 emit 一个更新信号
  （`Ezagent.ActionSet.Crawler.update_signal/0`，缺省 `"__dealscout_update__"`，
  像 kanban 的 `__done__`）→ Definition 的 routing_rules matcher 命中 → 转给
  `{:role, <hello 页面 agent 角色>}` → hello 的 agent 更新 json-render 页。
  零实例 URI、不数据直推、本 plugin 自己不渲染。

  ## Plugin authoring contract

  Per the plugin authoring contract the OTP `Application` module IS the plugin
  contract module: it `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`, which starts `children/0` FIRST then publishes every
  declaration — the author never touches a `*Registry` API. The
  `:ezagent_plugin_check` Mix compiler is the non-bypassable gate.

  ## Declared surface

  `plugin_info/0` + `children/0`（爬取 `Poller` + `RetentionSweeper`）+ `roles/0`
  （dealscout 业务 recipes——demo socialware 的 agent 配方，随 demo 一起
  ship 在本 plugin）。不声明 `behaviors/0` / view —— 其余 `Ezagent.Plugin`
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
      case EzagentPluginCrawler.Demo.publish() do
        {:ok, _published_exists_or_upgraded} ->
          :ok

        {:error, reason} ->
          raise "EzagentPluginCrawler boot aborted — the dealscout demo socialware " <>
                  "could not be published via the governance flow (fail-loud dogfood, " <>
                  "hello #162 play): #{inspect(reason)}"
      end
    end
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

  # The crawl `Poller` GenServer. Skipped in `:test` (and any env where
  # `:skip_poller` is set) so the test suite never starts a real timer that
  # would hit the network — mirrors `Ezagent.Email.Inbound`'s test-boot skip.
  @impl Ezagent.Plugin
  def children do
    if Application.get_env(:ezagent_plugin_crawler, :skip_poller, @compile_env == :test) do
      []
    else
      [EzagentPluginCrawler.Poller, EzagentPluginCrawler.RetentionSweeper]
    end
  end

  # Discovery-leg recipes (role-as-data, RF-4): boot seeds each into
  # `Ezagent.Agent.RecipeRegistry` by `name`. Flavor-agnostic — flavor is chosen
  # per-agent on the Definition role-slot (a later Stage), never on the recipe.
  @impl Ezagent.Plugin
  def roles, do: EzagentPluginCrawler.Recipes.all()
end
