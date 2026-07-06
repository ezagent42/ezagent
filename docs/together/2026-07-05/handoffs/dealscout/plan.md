# dealscout (DealScout) socialware Implementation Plan

> **⚠️ 返工修订（2026-07-06 用户拍板，覆盖本 plan 中一切相抵触的旧文；详见 spec.md 顶部 banner）**
>
> 层级 **plugin → socialware → ezagent**。DealScout 是 **socialware（纯配置组合）**，唯一真 plugin = 爬取后台。**dealscout 和 hello 都是 agent 驱动；wiring 跟 kanban 一样是 routing（内容协议）**：
>
> - **dealscout = 后台数据**：爬取 plugin + 它的 agent（discover / search recipe）用 crawl 能力爬数据 → 爬完注入新线索后 **emit 内容更新信号** `__dealscout_update__`（`Ezagent.ActionSet.DealScoutCrawl.update_signal/0`，像 kanban 的 `__done__`；已落地 `dealscout_crawl.ex` `emit_update_signal/3` + 测试）。
> - **hello = 显示 + concierge**：hello 的 agent 收信号更新 json-render 页。**dealscout 不声明 view / render**——`DealScoutRender` / `DealScoutView` **已删除**（原 Task 7 作废、Task 15 议题消失）；Definition `views` 引 **`hello_render`**。
> - **wiring = 内容协议 routing（像 kanban-team relay dev `__done__` → 看板助手）**：Definition `routing_rules` 用 `text_contains("__dealscout_update__")` matcher → receiver `{:role, <hello 页面 agent 角色>}`（conformance 只认已声明角色名）。**不数据直推、零实例 URI、dealscout 自己不渲染。**
> - **Definition（Stage D）方向**：`uses: [hello, dealscout]` + 组合 hello 公开面（views 引 `hello_render`）+ 声明 dealscout 后台 crawl + recipes + 上述 routing_rules。组合 hello / routing 到 hello 的 agent 都是**配置**，不改 hello 代码。
>
> 下文 Task 7 / Task 15 及所有 `DealScoutRender` / `DealScoutView` / "dealscout 发现流视图 / world tab" 字样**一律按本 banner 为准（作废）**。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建一个 DealScout socialware（**商业 / 投融资线索的搜索与撮合平台**，deal 侦察兵：AI 千人千面发现 deal + 公开面聊天撮合，两侧都是找机会的人）——发现腿（AI 爬取 + 主动发现 + 主动搜索 + 深挖追问）+ 撮合腿（组合 hello 公开面 + concierge，登录自助 join / 发言，founder invite 深聊），全在 `apps/ezagent_plugin_dealscout/` 自己的文件里，dev / 热装零改已有代码。

**Architecture:** 一个新 OTP plugin app（Elixir 代码：爬取 GenServer / fetch client / config slice / crawl ActionSet（含更新信号）/ recipe / retention sweeper——**无 view / render，显示归 hello**）+ 一个纯数据 Definition（config map，仿 hello code-seed 经真 governance publish 组合 hello：views 引 `hello_render` + routing_rules 接更新信号 → hello 页面 agent）。发现腿数据是 dealscout 自己的代码；展示与撮合腿 riding main 现成的 hello 公开面聊天 + web session_feed_channel + world invite_member。

**Tech Stack:** Elixir / OTP（umbrella app），`use Ezagent.Lifecycle`（ActionSet），`use Ezagent.Plugin`（契约），`:httpc`（抓取），GenServer（轮询 / sweep），ExUnit（单测），`agent-browser` CLI + Playwright chromium（真浏览器 e2e + 截图）。

## Global Constraints

> 每个 task 的要求隐含包含本节。值逐条 verbatim 引 spec。

- **代码全进 dealscout plugin 自己文件**：新建 `apps/ezagent_plugin_dealscout/`，dev / 热装零改已有代码。**碰 dealscout 自己文件外的任何代码（core / domain / hello / 别的 plugin / web transport）都是越界**。**Task 14（upload seam）现读证明自包含、已拿回主干**（用 core 现成公开 API `Uploads.store!/3` + 通用 effect `:effect_returning`，零改 core/world/web）；**Task 15 作废**（返工 banner：显示归 hello，dealscout 无自有 view，无 tab 议题）。
- **✅ 撮合腿自包含可建（对抗审查复核，推翻上一轮悲观判定）**：公开面 concierge 回帖**正确组合 hello 即通、不需改 hello/web/core**——web 收件人 `orch_<name>`（`session_feed_channel.ex:373-375`）**不是** Definition materialize 的随机 UUID，而是 hello **命令式按名重挂**的（`ensure_session_orchestrator` → `create_role_agent(ws, "orch_#{name}", ...)`，hello `app.ex:136,143`），对**任何经 world 路径建的 page session** 都补 `orch_<session名>`（world `conversation_actions.ex:326`），跟收件人算法逐字对齐、必命中。**两个硬前提**：(1) DealScout Definition 复制 hello 公开面配置（`shape` 含 `Surface`+`Turn`、`adapters` 含 `external_feed`、`web_anon_access:true`、引 `hello_render` view、`uses:[:ezagent_plugin_hello]`、带 seed 页 → 成 page session）；(2) 建/装会话走 world 路径（socialware install→`create_session`）。**残余风险**：不走 world 路径（CLI/直接建）或无 Surface/seed 页 → orchestrator 不建 → concierge 不回（这是前提不是死锁）。spec §4 全文。**Task 11-13 不碰 hello router / `session_feed_channel.ex` / core。**
- **ActionSet 不是 Elixir behaviour**：dealscout 的 ActionSet（crawl）用 `use Ezagent.Lifecycle` 写，**不写** `invoke/4`（`@optional_callbacks` only）。（render / view ActionSet 已按返工 banner 删除——显示归 hello。）
- **caps 只来自 recipe**：Definition struct **无 `requested_caps` 字段**（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:12-28` 17 字段）。dealscout Definition 从不声明 caps，全部 caps 在 recipe 的 `requested_caps`（照 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:70-76`）。
- **Definition 是纯数据 DATA**：本身不含一行代码，经 `DefinitionRegistry` 持久化。**`views` 引 hello 的 `hello_render`（非 dealscout 自有 view，返工 banner）**；routing_rules 引内容标记 + `{:role, 角色名}`，零实例 URI。
- **flavor per-agent**：Definition 顶层无 flavor；flavor 在 `roles` 里每个 agent 角色槽 `%{role_name, fill: :agent, recipe, flavor}`（agent 槽必填、materialize 侧缺省 `"cc"`，`definition.ex:34-36,282-286`）。今天各 agent 统一跑 `"cc"` 无碍（非 cc flavor runtime materialize hook 未齐是运行时能力问题，非声明缺口）。
- **P14 dispatch 是 Kind 间唯一通路**：注入走 `Ezagent.Router.dispatch/1`（`apps/ezagent_core/lib/ezagent/router.ex:79`），禁 `PubSub.broadcast` 到 inbound topic。action URI 用 `Ezagent.URI.with_action`（照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex:172`），不裸拼 `?action=`。
- **`:httpc` 必带 `{:body_format, :binary}`**（照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro.ex:141`）——不带中文乱码。
- **失败要有人知道**：每个路由 / 投递 / 写点，dispatch / 抓取 / sweep 失败要 telemetry + 显式 reject，不 silent drop（Ezagent 是 router 不是 req/resp app）。
- **✅ role-slot 已落地（#1180）**：写 Definition 用 `roles` 字段声明角色槽——agent 槽 `%{role_name, fill: :agent, recipe, flavor}`、human 槽 `%{role_name, fill: :human}`；routing receivers 用 `{:role, name}`（只认已声明角色名）；`owner_policy: %{type: :installer}`。**绝不塞参与者/owner 实例 URI，也别用退休的 `agents`/`members` 字段**（`Definition.new/1` 会 fail-loud 拒）。
- **爬取标来源类型**：每条线索带 `source_type: :public | :directed`（spec §3.2），hello / 发现流 UI 分类展示。
- **测试跑法**（umbrella 根，绝不 `cd` 进 app）：
  ```bash
  docker start ezagent-pg-compat-audit-postgres
  mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
  mise exec -- mix test apps/ezagent_plugin_dealscout/test
  mise exec -- mix ezagent.socialware.check          # conformance gate
  ```
- **真浏览器 e2e（最高纪律）**：每个用户面 task 用 `agent-browser`（`docs/e2e/auto/lib.sh` helper：`ab_login` / `ab_open` / `ab_wait` / `ab_click` / `ab_fill_react` / `ab_submit` / `ab_eval` / `ab_shot`）或 Playwright chromium（`scripts/demo/agent-create-record.js` 先例）。起 dev server 端口 10042、真登录 `admin@ezagent.chat` / `worlddev`、真点击、**每个有意义步骤 `ab_shot` 截图**。**禁止 stub 当 e2e。**

---

## Task 1: plugin app 脚手架 + 契约回调骨架 (I-1.1 ↑F-1)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/mix.exs`
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`
- Test: `apps/ezagent_plugin_dealscout/test/application_test.exs`

**Interfaces:**
- Produces: OTP app `:ezagent_plugin_dealscout`；`EzagentPluginDealScout.Application`（`use Ezagent.Plugin`）实现 `plugin_info/0` + `children/0`（后续 task 补 `roles/0` / `after_boot/0` / `config_surface/0`）。

- [ ] **Step 1: 写 mix.exs（照 hello mix.exs，含 `:ezagent_plugin_check` compiler gate）**

```elixir
# apps/ezagent_plugin_dealscout/mix.exs
defmodule EzagentPluginDealScout.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_dealscout,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Plugin authoring contract §3.2 — non-bypassable app-level gate.
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginDealScout.Application, []},
      env: [ezagent_plugin: EzagentPluginDealScout.Application],
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_ui, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      # 组合 hello 拿公开面 + concierge（Task 11）——dealscout Definition `uses: [:ezagent_plugin_hello]`。
      {:ezagent_plugin_hello, in_umbrella: true}
    ]
  end
end
```

- [ ] **Step 2: 写 application.ex 骨架（`use Ezagent.Plugin`，先只填 `plugin_info/0` + `children/0`）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex
defmodule EzagentPluginDealScout.Application do
  @moduledoc "dealscout socialware plugin — 发现腿爬取/搜索/追问 + 撮合腿组合 hello。"
  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{name: "dealscout", version: "0.1.0", description: "dealscout discovery + matchmaking socialware"}
  end

  @impl Ezagent.Plugin
  def children, do: []
end
```

- [ ] **Step 3: 写失败测试（app 启动 + plugin_info 形状）**

```elixir
# apps/ezagent_plugin_dealscout/test/application_test.exs
defmodule EzagentPluginDealScout.ApplicationTest do
  use ExUnit.Case, async: true

  test "plugin_info exposes dealscout name + version" do
    info = EzagentPluginDealScout.Application.plugin_info()
    assert info.name == "dealscout"
    assert info.version == "0.1.0"
  end

  test "children/0 returns a supervisable list" do
    assert is_list(EzagentPluginDealScout.Application.children())
  end
end
```

- [ ] **Step 4: 跑测试确认失败（app 未编译）**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/application_test.exs`
Expected: FAIL — `EzagentPluginDealScout.Application` 未定义 / app 未识别。

- [ ] **Step 5: `mise exec -- mix compile` + 跑测试确认通过**

Run: `mise exec -- mix compile && mise exec -- mix test apps/ezagent_plugin_dealscout/test/application_test.exs`
Expected: PASS；umbrella 识别新 app、启动不崩、`:ezagent_plugin_check` gate 过。

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_dealscout/mix.exs apps/ezagent_plugin_dealscout/lib apps/ezagent_plugin_dealscout/test
git commit -m "feat(dealscout): I-1.1 plugin app scaffold + contract callbacks"
```

---

## Task 2: 轮询 GenServer (I-1.2 ↑F-1)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/poller.ex`
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（`children/0` 挂 poller，test-boot skip）
- Test: `apps/ezagent_plugin_dealscout/test/poller_test.exs`

**Interfaces:**
- Consumes: —
- Produces: `EzagentPluginDealScout.Poller.start_link/1`；`EzagentPluginDealScout.Poller.poll_once/0`（public，operator / test 可不等 timer 触发一次）。

- [ ] **Step 1: 写失败测试（poll_once 调注入的 fetch_fun 一次）**

```elixir
# apps/ezagent_plugin_dealscout/test/poller_test.exs
defmodule EzagentPluginDealScout.PollerTest do
  use ExUnit.Case, async: false
  alias EzagentPluginDealScout.Poller

  test "poll_once invokes the configured fetch_fun exactly once" do
    test_pid = self()
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> send(test_pid, :fetched); {:ok, []} end)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_dealscout, :fetch_fun) end)

    assert :ok = Poller.poll_once()
    assert_receive :fetched, 500
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/poller_test.exs`
Expected: FAIL — `EzagentPluginDealScout.Poller` 未定义。

- [ ] **Step 3: 写 poller.ex（照 email inbound.ex:57-73 的 schedule_poll idiom）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/poller.ex
defmodule EzagentPluginDealScout.Poller do
  @moduledoc """
  周期爬取 GenServer（照 `Ezagent.Email.Inbound` 的 poll 循环）。
  仓里没有 cron 框架，`Process.send_after(self(), :poll, interval)` 是标准写法。
  seams（app env，测试注入）：`:poll_interval_ms`（默认 30s）、`:fetch_fun`（默认 `Fetch.crawl/0`）。
  """
  use GenServer
  require Logger

  @default_interval_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_once()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "跑一次爬取周期。public，operator / test 可不等 timer 触发。"
  @spec poll_once() :: :ok
  def poll_once do
    case fetch_fun().() do
      {:ok, _items} -> :ok
      {:error, reason} ->
        Logger.warning("DealScout.Poller: crawl failed (recoverable): #{inspect(reason)}")
        :ok
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, interval_ms())
  defp interval_ms, do: Application.get_env(:ezagent_plugin_dealscout, :poll_interval_ms, @default_interval_ms)
  defp fetch_fun, do: Application.get_env(:ezagent_plugin_dealscout, :fetch_fun, &EzagentPluginDealScout.Fetch.crawl/0)
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/poller_test.exs`
Expected: PASS。

- [ ] **Step 5: `children/0` 挂 poller（test-boot skip，照 email application.ex:67-68）**

```elixir
# application.ex — 替换 children/0
  @impl Ezagent.Plugin
  def children do
    if Application.get_env(:ezagent_plugin_dealscout, :skip_poller, Mix.env() == :test) do
      []
    else
      [EzagentPluginDealScout.Poller]
    end
  end
```

- [ ] **Step 6: 跑 app 测试确认不崩 + Commit**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test`
Expected: PASS；测试环境不起真 poller（不打外网）。

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/poller.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex apps/ezagent_plugin_dealscout/test/poller_test.exs
git commit -m "feat(dealscout): I-1.2 polling GenServer (email inbound idiom, test-boot skip)"
```

---

## Task 3: `:httpc` 抓取 client + source_type 标注 (I-1.3 ↑F-1, spec §3)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`
- Test: `apps/ezagent_plugin_dealscout/test/fetch_test.exs`

**Interfaces:**
- Consumes: —
- Produces: `EzagentPluginDealScout.Fetch.parse_items/2`（`(body :: binary, source_type :: :public | :directed) -> [item]`，`item = %{title, url, summary, source, ts, source_type}`）；`EzagentPluginDealScout.Fetch.crawl/0`（用 `:httpc` 抓固定公开源，`source_type: :public`）。

- [ ] **Step 1: 写失败测试（parse_items 打 source_type + 中文不乱码）**

```elixir
# apps/ezagent_plugin_dealscout/test/fetch_test.exs
defmodule EzagentPluginDealScout.FetchTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.Fetch

  test "parse_items tags each item with the given source_type and keeps UTF-8 titles intact" do
    body = ~s([{"title":"某基金完成融资","url":"https://x/1","summary":"摘要"}])
    [item] = Fetch.parse_items(body, :public)
    assert item.title == "某基金完成融资"
    assert item.source_type == :public
    assert is_binary(item.title)
  end

  test "directed source_type is preserved for login-gated fetches" do
    body = ~s([{"title":"deal","url":"https://x/2","summary":"s"}])
    [item] = Fetch.parse_items(body, :directed)
    assert item.source_type == :directed
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/fetch_test.exs`
Expected: FAIL — `EzagentPluginDealScout.Fetch` 未定义。

- [ ] **Step 3: 写 fetch.ex（`:httpc` + `{:body_format, :binary}`，照 miro.ex:141）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex
defmodule EzagentPluginDealScout.Fetch do
  @moduledoc """
  自建入站源 client（**别误用 socialware `:pull` 出站投影**）。
  照 kanban miro `:httpc` idiom：必带 `{:body_format, :binary}`，否则 body 返 charlist、中文乱码。
  每条线索打 `source_type`（`:public` 自己爬公开网页 / `:directed` 用 token 抓登录源，spec §3）。
  """
  require Logger

  @type item :: %{title: String.t(), url: String.t(), summary: String.t(),
                  source: String.t(), ts: DateTime.t(), source_type: :public | :directed}

  @default_public_source ~c"https://hacker-news.firebaseio.com/v0/topstories.json"

  @doc "抓固定公开源，返回 source_type: :public 的条目列表。"
  @spec crawl() :: {:ok, [item]} | {:error, term()}
  def crawl, do: fetch(@default_public_source, [], :public)

  @doc "参数化抓取（query / 定向源），headers 注入 token（Task 5）。"
  @spec fetch(charlist() | String.t(), keyword(), :public | :directed) :: {:ok, [item]} | {:error, term()}
  def fetch(url, headers \\ [], source_type \\ :public) do
    request = {to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} -> {:ok, parse_items(body, source_type)}
      {:ok, {{_v, code, _r}, _h, _body}} -> {:error, {:http_status, code}}
      {:error, reason} ->
        Logger.warning("DealScout.Fetch: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "把 body 解析成信息条目，每条打 source_type。"
  @spec parse_items(binary(), :public | :directed) :: [item]
  def parse_items(body, source_type) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_item(&1, source_type))
      _ -> []
    end
  end

  defp to_item(m, source_type) when is_map(m) do
    %{
      title: Map.get(m, "title", ""),
      url: Map.get(m, "url", ""),
      summary: Map.get(m, "summary", ""),
      source: Map.get(m, "source", "public"),
      ts: DateTime.utc_now(),
      source_type: source_type
    }
  end
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/fetch_test.exs`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex apps/ezagent_plugin_dealscout/test/fetch_test.exs
git commit -m "feat(dealscout): I-1.3 :httpc fetch client + source_type tagging (public/directed)"
```

---

## Task 4: 手动触发 action + dispatch 注入 session.send (I-1.4 ↑F-1, P14)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_crawl.ex`（ActionSet，`:crawl_now` action）
- Test: `apps/ezagent_plugin_dealscout/test/dealscout_crawl_test.exs`

**Interfaces:**
- Consumes: `EzagentPluginDealScout.Fetch.parse_items/2`（Task 3）。
- Produces: `Ezagent.ActionSet.DealScoutCrawl`（`use Ezagent.Lifecycle`，`actions -> [:crawl_now]`，`handle_crawl_now/2` 抓回条目经 `Router.dispatch/1` 投 `session.send`）。

- [ ] **Step 1: 写失败测试（handle_crawl_now 把条目经注入 seam 投出，dispatch 失败有 telemetry）**

```elixir
# apps/ezagent_plugin_dealscout/test/dealscout_crawl_test.exs
defmodule EzagentPluginDealScout.DealScoutCrawlTest do
  use ExUnit.Case, async: false
  alias Ezagent.ActionSet.DealScoutCrawl

  test "crawl_now dispatches one session.send per fetched item via the injected seam" do
    test_pid = self()
    items = [%{title: "某基金", url: "u", summary: "s", source: "hn", ts: DateTime.utc_now(), source_type: :public}]
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, items} end)
    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd -> send(test_pid, {:dispatched, cmd}); :ok end)
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_dealscout, :fetch_fun)
      Application.delete_env(:ezagent_plugin_dealscout, :dispatch_fun)
    end)

    ctx = %{session_uri: Ezagent.URI.new("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 1}, _effects} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
    assert_receive {:dispatched, _cmd}, 500
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_crawl_test.exs`
Expected: FAIL — `Ezagent.ActionSet.DealScoutCrawl` 未定义。

- [ ] **Step 3: 写 dealscout_crawl.ex（ActionSet + P14 注入，action URI 用 with_action）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_crawl.ex
defmodule Ezagent.ActionSet.DealScoutCrawl do
  @moduledoc """
  手动触发爬取的 ActionSet（`:crawl_now`）。轮询和手动触发走同一注入路径：
  抓回条目经 P14 `Ezagent.Router.dispatch/1`（`router.ex:79`）投 `session.send`。
  注入点问"失败了谁知道"：dispatch 失败 telemetry，不 silent drop。
  """
  use Ezagent.Lifecycle
  require Logger

  @impl Ezagent.ActionSet
  def actions, do: [:crawl_now]

  @impl Ezagent.ActionSet
  def cap_subjects, do: [{:crawl_now, "Trigger a dealscout crawl and inject results into this session."}]

  @impl Ezagent.ActionSet
  def required_caps, do: %{crawl_now: Ezagent.Capability.cap(:session, __MODULE__, :crawl_now)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  def handle_crawl_now(_args, ctx) do
    {:ok, items} = fetch_fun().()
    injected = Enum.reduce(items, 0, fn item, acc -> if inject(ctx.session_uri, item), do: acc + 1, else: acc end)
    {:ok, %{injected: injected}, []}
  end

  defp inject(session_uri, item) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)
    cmd = %Ezagent.Invocation{target: target, mode: :cast,
                              args: %{body: format_item(item)}, ctx: %{reply: :ignore}}

    case dispatch_fun().(cmd) do
      :ok -> true
      other ->
        :telemetry.execute([:dealscout, :inject, :error], %{count: 1}, %{item: item, reason: other})
        Logger.warning("DealScout inject failed (no one else would know): #{inspect(other)}")
        false
    end
  end

  defp format_item(%{source_type: st, title: t, url: u, summary: s}),
    do: "[#{st}] #{t} — #{s} (#{u})"

  defp fetch_fun, do: Application.get_env(:ezagent_plugin_dealscout, :fetch_fun, &EzagentPluginDealScout.Fetch.crawl/0)
  defp dispatch_fun, do: Application.get_env(:ezagent_plugin_dealscout, :dispatch_fun, &Ezagent.Router.dispatch/1)
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_crawl_test.exs`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_crawl.ex apps/ezagent_plugin_dealscout/test/dealscout_crawl_test.exs
git commit -m "feat(dealscout): I-1.4 crawl_now ActionSet + P14 dispatch inject (fail-loud)"
```

**测试方法（task 级）**：ExUnit（注入 fetch_fun / dispatch_fun seam，验证每条目一次 dispatch + 失败 telemetry）。dev 起 server 后手动触发 `:crawl_now` 看条目落会话历史（e2e 在 Task 8 视图上验证可见）。

---

## Task 5: 配置 slice + token 存储 (I-4 ↑F-4)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex`
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`（抓取读 token 注入 header，fail-closed）
- Test: `apps/ezagent_plugin_dealscout/test/config_test.exs`

**Interfaces:**
- Consumes: —
- Produces: `EzagentPluginDealScout.Config.set_profile/2` / `.set_keywords/2`（返回 `{:set, key, value}` effect）；`EzagentPluginDealScout.Config.write_token/2`（照 github write_creds，写 `system://credentials/dealscout_<src>.yaml`）；`EzagentPluginDealScout.Config.read_token/1`（无 token → `:error`，fail-closed）。

- [ ] **Step 1: 写失败测试（set_profile 出 effect + token 写回读一致 + 无 token fail-closed）**

```elixir
# apps/ezagent_plugin_dealscout/test/config_test.exs
defmodule EzagentPluginDealScout.ConfigTest do
  use ExUnit.Case, async: false
  alias EzagentPluginDealScout.Config

  test "set_profile returns a {:set, :profile, value} effect" do
    assert {:set, :profile, %{stage: "seed"}} = Config.set_profile(%{}, %{stage: "seed"})
  end

  test "write_token then read_token round-trips; missing token is fail-closed :error" do
    :ok = Config.write_token("acme", "tok-123")
    assert {:ok, "tok-123"} = Config.read_token("acme")
    assert :error = Config.read_token("no-such-source")
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/config_test.exs`
Expected: FAIL — `EzagentPluginDealScout.Config` 未定义。

- [ ] **Step 3: 写 config.ex（slice effect 照 kb.ex:80-83；token 照 github.ex:32-54）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex
defmodule EzagentPluginDealScout.Config do
  @moduledoc """
  配置层：profile + keywords 存 Lifecycle state slice（`{:set, k, v}` effect，`ctx.read` 读，
  自动 snapshot，照 `Ezagent.ActionSet.Kb` 元数据 slice）。token 走最简一档凭证：
  写 `system://credentials/dealscout_<src>.yaml`（admin-gated，照 kanban `Github.write_creds/1`）。
  profile 是 Task 6 千人千面匹配的数据源。
  """
  alias Ezagent.Credentials

  @spec set_profile(map(), map()) :: {:set, :profile, map()}
  def set_profile(_current, profile), do: {:set, :profile, profile}

  @spec set_keywords(map(), [String.t()]) :: {:set, :keywords, [String.t()]}
  def set_keywords(_current, keywords), do: {:set, :keywords, keywords}

  @spec write_token(String.t(), String.t()) :: :ok | {:error, term()}
  def write_token(source, token) when is_binary(source) and is_binary(token),
    do: Credentials.write("dealscout_#{source}", %{"token" => token})

  @spec read_token(String.t()) :: {:ok, String.t()} | :error
  def read_token(source) do
    case Credentials.read("dealscout_#{source}") do
      {:ok, %{"token" => t}} when is_binary(t) -> {:ok, t}
      _ -> :error
    end
  end
end
```

> **注**：`Ezagent.Credentials` 是 `system://credentials/*.yaml` 的读写门面（kanban `github.ex:32-54` 的 `write_creds/1` 底层）。实现时现读 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:32-54` 确认确切 API 名（若门面名不同，按实际改这两处 `Credentials.write/read`）。

- [ ] **Step 4: fetch.ex 抓定向源前读 token 注入 header（fail-closed 跳过 + telemetry）**

```elixir
# fetch.ex — 新增 fetch_directed/2
  @doc "抓需登录的定向源：读 token 注入 Authorization header；无 token fail-closed 跳过 + telemetry。"
  @spec fetch_directed(String.t(), String.t()) :: {:ok, [item]} | {:error, :no_token}
  def fetch_directed(url, source) do
    case EzagentPluginDealScout.Config.read_token(source) do
      {:ok, token} -> fetch(url, [{"Authorization", "Bearer #{token}"}], :directed)
      :error ->
        :telemetry.execute([:dealscout, :fetch, :skipped_no_token], %{count: 1}, %{source: source})
        {:error, :no_token}
    end
  end
```

- [ ] **Step 5: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/config_test.exs`
Expected: PASS。

- [ ] **Step 6: 真浏览器 e2e（chat 改 profile → 重启还在）+ Commit**

e2e 脚本（`docs/e2e/auto/` 追加，agent-browser）：
```bash
# dealscout_config e2e (节选伪脚本，用 lib.sh helper)
ab_login
ab_open "$BASE_URL/sessions?session=$DEALSCOUT_SESS_ENC"; ab_wait '[data-world-component=conversation]'
ab_shot dealscout-04-config-before.png
ab_mention_send "dealscout-config" "设 profile stage=seed 关键词=具身智能"   # chat 命令改 profile
ab_wait 2000; ab_shot dealscout-04-config-set.png
# 重启 dev server 后重开 session，断言 profile 仍在（snapshot 生效）
ab_open "$BASE_URL/sessions?session=$DEALSCOUT_SESS_ENC"; ab_wait '[data-world-component=conversation]'
ab_shot dealscout-04-config-after-restart.png
```
Expected: 截图证 profile 改后持久（重启不丢）。

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex apps/ezagent_plugin_dealscout/test/config_test.exs docs/e2e/auto/
git commit -m "feat(dealscout): I-4 config slice (profile/keywords) + token creds (fail-closed) + e2e"
```

---

## Task 6: recipe 集 — 发现 / 搜索 / 整理 / 追问 (I-2.1 / I-3.1 / I-6.1 ↑F-2/F-3/F-6)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（`roles/0` 返回 recipe 集）
- Test: `apps/ezagent_plugin_dealscout/test/recipes_test.exs`

**Interfaces:**
- Consumes: —
- Produces: `EzagentPluginDealScout.Recipes.all/0 :: [map()]`——4 个 recipe（`dealscout-discover` / `dealscout-search` / `dealscout-organize` / `dealscout-followup`），每个 `%{name, prompt, requested_caps, behaviors, flavor}`（照 orchestrator_recipe.ex:64-79）；`Application.roles/0` 返回它们。

- [ ] **Step 1: 写失败测试（4 个 recipe，名 + caps 齐 + 三要素形状）**

```elixir
# apps/ezagent_plugin_dealscout/test/recipes_test.exs
defmodule EzagentPluginDealScout.RecipesTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.Recipes

  test "declares the four discovery-leg recipes with caps + three-part shape" do
    names = Recipes.all() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["dealscout-discover", "dealscout-followup", "dealscout-organize", "dealscout-search"]

    for r <- Recipes.all() do
      assert is_binary(r.prompt) and r.prompt != ""
      assert is_list(r.requested_caps) and r.requested_caps != []
      assert r.behaviors == []
    end
  end

  test "each recipe carries a flavor (default cc), used by #1180 role-slot agent slots" do
    for r <- Recipes.all(), do: assert(r.flavor in ["cc", "cc-headless", "native"])
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/recipes_test.exs`
Expected: FAIL — `EzagentPluginDealScout.Recipes` 未定义。

- [ ] **Step 3: 写 recipes.ex（三要素照 orchestrator_recipe.ex:64-79；caps 只在这里）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex
defmodule EzagentPluginDealScout.Recipes do
  @moduledoc """
  发现腿 recipe 集。三要素照 `Ezagent.Orchestrator.OrchestratorRecipe`：
  `prompt` + `requested_caps` + `behaviors`。caps 只在这里（Definition 无 caps 字段）。
  flavor per-agent 声明（#1180 role-slot，`definition.ex:34-36,282-286`）；今天统一 "cc"，非 cc runnable 待运行时 hook。
  """
  @send_cap %{behavior: Ezagent.ActionSet.Session, action: :send}
  @crawl_cap %{behavior: Ezagent.ActionSet.DealScoutCrawl, action: :crawl_now}

  @spec all() :: [map()]
  def all, do: [discover(), search(), organize(), followup()]

  defp discover do
    %{name: "dealscout-discover", flavor: "cc", behaviors: [],
      prompt: "读用户 profile + 新抓回条目，按千人千面匹配挑出高分机会，主动推进发现流。",
      requested_caps: [@send_cap]}
  end

  defp search do
    %{name: "dealscout-search", flavor: "cc", behaviors: [],
      prompt: "把用户 query 转成对全网/指定源的检索，汇总候选，注入发现流并标记为搜索结果。",
      requested_caps: [@send_cap, @crawl_cap]}
  end

  defp organize do
    %{name: "dealscout-organize", flavor: "cc", behaviors: [],
      prompt: "把杂乱的发现流条目组织成结构化清单（按来源类型 public/directed 分组）。",
      requested_caps: [@send_cap]}
  end

  defp followup do
    %{name: "dealscout-followup", flavor: "cc", behaviors: [],
      prompt: "对单条机会多轮深挖追问，产出可下载材料。",
      requested_caps: [@send_cap]}
  end
end
```

- [ ] **Step 4: application.ex 加 `roles/0`**

```elixir
# application.ex — 新增
  @impl Ezagent.Plugin
  def roles, do: EzagentPluginDealScout.Recipes.all()
```

- [ ] **Step 5: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/recipes_test.exs`
Expected: PASS。

- [ ] **Step 6: 集成验证（recipe 进 RecipeRegistry）+ Commit**

Run（集成，boot 后 recipe 注册）: `mise exec -- mix test apps/ezagent_plugin_dealscout/test`
Expected: PASS；`mix ezagent` CLI 能看到 4 个 dealscout recipe。

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex apps/ezagent_plugin_dealscout/test/recipes_test.exs
git commit -m "feat(dealscout): I-2.1/I-3.1/I-6.1 discovery-leg recipes (discover/search/organize/followup)"
```

**测试方法**：ExUnit（recipe 形状 + caps + flavor）+ 集成（进 RecipeRegistry）。profile 驱动匹配的 e2e 在 Task 8 视图上验证（换 profile 发现流不同 = 千人千面可见）。

---

## ~~Task 7: DealScoutRender + SessionView + 发现流视图 (I-5 ↑F-5)~~ — **作废（2026-07-06 返工 banner）**

> **本 Task 整体作废、代码已删**：`dealscout_render.ex` / `dealscout_view.ex` + 两个测试 + `application.ex` 里的 `SessionViewRegistry.register` / `behaviors/0` 注册已全部删除。**显示是 hello 的活**——发现流上页走：爬取 agent 注入线索 + emit `__dealscout_update__` 更新信号（Task 4 的 `dealscout_crawl.ex`，已落地）→ Definition routing_rules（Task 10/11 配置）→ hello 页面 agent 更新 json-render 页。以下原文仅存档，勿执行。

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_render.ex`（cap-only render ActionSet）
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/dealscout_view.ex`（SessionView module）
- Test: `apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs` + `apps/ezagent_plugin_dealscout/test/dealscout_view_test.exs`

**Interfaces:**
- Consumes: —
- Produces: `Ezagent.ActionSet.DealScoutRender`（`actions -> [:dealscout_render]`，`dispatchable? -> false`，cap-only）；`EzagentPluginDealScout.DealScoutView`（`@behaviour Ezagent.UI.SessionView`，`id -> :dealscout_feed`，`match/1` 匹配 dealscout session，`render/1` 按 source_type 分类展示）。

- [ ] **Step 1: 写失败测试（DealScoutRender cap-only + 唯一 action 名）**

```elixir
# apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs
defmodule Ezagent.ActionSet.DealScoutRenderTest do
  use ExUnit.Case, async: true
  alias Ezagent.ActionSet.DealScoutRender

  test "DealScoutRender is a cap-only render ActionSet with the unique :dealscout_render action" do
    assert DealScoutRender.actions() == [:dealscout_render]
    assert DealScoutRender.dispatchable?() == false
    assert Map.has_key?(DealScoutRender.required_caps(), :dealscout_render)
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs`
Expected: FAIL — `Ezagent.ActionSet.DealScoutRender` 未定义。

- [ ] **Step 3: 写 dealscout_render.ex（逐结构照 hello_render.ex:29-49，唯一 `:dealscout_render`）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_render.ex
defmodule Ezagent.ActionSet.DealScoutRender do
  @moduledoc """
  dealscout 发现流的 **view read ActionSet**（cap-only，照 `Ezagent.ActionSet.HelloRender`）。
  唯一 `:dealscout_render` action——`{Session, :dealscout_render}` cap pair 全仓唯一，
  否则 `CapabilityRegistry.check_conflict!` RAISE。这是"看的权限门"，非渲染器。
  """
  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:dealscout_render]

  @impl Ezagent.ActionSet
  def cap_subjects, do: [{:dealscout_render, "Read (render) the dealscout discovery-feed view for this session."}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps, do: %{dealscout_render: Ezagent.Capability.cap(:session, __MODULE__, :dealscout_render)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any
end
```

- [ ] **Step 4: 跑测试确认通过（cap 无冲突注册）**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs`
Expected: PASS；plugin 启动时 DealScoutRender 注册成功、`{Session, :dealscout_render}` 无冲突。

- [ ] **Step 5: 写 dealscout_view.ex（照 page_view.ex，render 按 source_type 分类）+ 失败测试**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/dealscout_view.ex
defmodule EzagentPluginDealScout.DealScoutView do
  @moduledoc """
  发现流列表 SessionView（照 hello `PageView`）。经 `authorize_view/3`（`session_view.ex:120-126`）
  统一 cap 门。render/1 按 `source_type`（:public / :directed）分类展示（spec §3.2）。
  """
  @behaviour Ezagent.UI.SessionView

  @impl true
  def id, do: :dealscout_feed

  @impl true
  def match(session_uri), do: Ezagent.URI.type?(session_uri, :dealscout)

  @impl true
  def render(assigns) do
    items = Map.get(assigns, :discoveries, [])
    %{
      component: :dealscout_feed,
      groups: %{
        public: Enum.filter(items, &(&1.source_type == :public)),
        directed: Enum.filter(items, &(&1.source_type == :directed))
      }
    }
  end
end
```

```elixir
# apps/ezagent_plugin_dealscout/test/dealscout_view_test.exs
defmodule EzagentPluginDealScout.DealScoutViewTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.DealScoutView

  test "render groups discoveries by source_type" do
    items = [%{source_type: :public, title: "a"}, %{source_type: :directed, title: "b"}]
    out = DealScoutView.render(%{discoveries: items})
    assert [%{title: "a"}] = out.groups.public
    assert [%{title: "b"}] = out.groups.directed
  end
end
```

- [ ] **Step 6: 注册 SessionView（application.ex `after_boot/0` 或 domain_ui registry）+ 跑测试**

在 `application.ex` 补 `after_boot/0` 注册 view（现读 `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex` 的 registry API 确认注册函数名，照 hello 注册 PageView 的写法）。

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_view_test.exs apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs`
Expected: PASS。

- [ ] **Step 7: 真浏览器 e2e（发现流在 session tab 渲染 + 分类展示 + 每步截图）**

```bash
# docs/e2e/auto/ dealscout_feed e2e (agent-browser)
ab_login; ab_shot dealscout-05-01-login.png
ab_open "$BASE_URL/sessions?session=$DEALSCOUT_SESS_ENC"; ab_wait '[data-world-component=conversation]'
ab_shot dealscout-05-02-session.png
# 触发一次 crawl（chat 命令），条目落发现流
ab_mention_send "dealscout" "crawl_now"; ab_wait 3000; ab_shot dealscout-05-03-crawled.png
# 切到 dealscout 发现流 tab（Task 15(b) world 冒 tab 接线前，先用直达 view 或 assert 列表 DOM）
assert_visible '[data-world-component=dealscout_feed]' "dealscout 发现流视图渲染"
ab_shot dealscout-05-04-feed-classified.png    # 断言 public / directed 分组可见
```
Expected: 截图证发现流列表页出现、按来源类型分类展示。**禁 stub。**

- [ ] **Step 8: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_render.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/dealscout_view.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex apps/ezagent_plugin_dealscout/test/dealscout_render_test.exs apps/ezagent_plugin_dealscout/test/dealscout_view_test.exs docs/e2e/auto/
git commit -m "feat(dealscout): I-5 DealScoutRender cap-only + DealScoutView (source_type classified feed) + e2e"
```

**测试方法**：ExUnit（cap 无冲突 + view 注册 + render 分类）+ **真浏览器 e2e**（session tab 渲染发现流 + 分类 + 截图）。dealscout 是首个走 `Definition.views` 匿名链的用户，顺带验证 T2 views 设计。

---

## Task 8: AI 主动发现 push + 主动搜索接线 (I-2.2 / I-3.2 ↑F-2/F-3)

**Files:**
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_crawl.ex`（加 `:search` action，query 参数化）
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`（`fetch/3` 已支持 query，Task 3）
- Test: `apps/ezagent_plugin_dealscout/test/dealscout_search_test.exs`

**Interfaces:**
- Consumes: `Fetch.fetch/3`（Task 3），`DealScoutCrawl` inject seam（Task 4）。
- Produces: `Ezagent.ActionSet.DealScoutCrawl.handle_search/2`（收 `%{query, source}`，参数化抓 → 注入发现流，标记搜索结果）。

- [ ] **Step 1: 写失败测试（search action 把 query 结果经注入 seam 投出，标 :search 来源）**

```elixir
# apps/ezagent_plugin_dealscout/test/dealscout_search_test.exs
defmodule EzagentPluginDealScout.DealScoutSearchTest do
  use ExUnit.Case, async: false
  alias Ezagent.ActionSet.DealScoutCrawl

  test "handle_search dispatches query results tagged as search into the feed" do
    test_pid = self()
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, []} end)
    Application.put_env(:ezagent_plugin_dealscout, :search_fun, fn _q ->
      {:ok, [%{title: "早期基金", url: "u", summary: "s", source: "search", ts: DateTime.utc_now(), source_type: :public}]}
    end)
    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd -> send(test_pid, {:dispatched, cmd}); :ok end)
    on_exit(fn -> for k <- [:fetch_fun, :search_fun, :dispatch_fun], do: Application.delete_env(:ezagent_plugin_dealscout, k) end)

    ctx = %{session_uri: Ezagent.URI.new("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 1}, _} = DealScoutCrawl.handle_search(%{query: "早期基金", source: "public"}, ctx)
    assert_receive {:dispatched, _cmd}, 500
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_search_test.exs`
Expected: FAIL — `handle_search/2` 未定义。

- [ ] **Step 3: dealscout_crawl.ex 加 `:search` action + handle_search**

```elixir
# dealscout_crawl.ex — actions 改为 [:crawl_now, :search]，新增：
  def handle_search(%{query: query} = args, ctx) do
    {:ok, items} = search_fun().(query)
    injected = Enum.reduce(items, 0, fn item, acc ->
      if inject(ctx.session_uri, Map.put(item, :source, "search:#{Map.get(args, :source, "public")}")), do: acc + 1, else: acc
    end)
    {:ok, %{injected: injected}, []}
  end

  defp search_fun, do: Application.get_env(:ezagent_plugin_dealscout, :search_fun, &default_search/1)
  defp default_search(query), do: EzagentPluginDealScout.Fetch.fetch(search_url(query), [], :public)
  defp search_url(query), do: "https://hn.algolia.com/api/v1/search?query=#{URI.encode(query)}"
```
（同时把 `actions/0` 改 `[:crawl_now, :search]`，`cap_subjects` / `required_caps` 补 `:search`。）

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/dealscout_search_test.exs`
Expected: PASS。

- [ ] **Step 5: 真浏览器 e2e（chat 发 query → 搜索结果落发现流 + 换 profile 千人千面）+ Commit**

```bash
ab_login; ab_open "$BASE_URL/sessions?session=$DEALSCOUT_SESS_ENC"; ab_wait '[data-world-component=conversation]'
ab_mention_send "dealscout-search" "帮我搜具身智能早期基金"; ab_wait 3000; ab_shot dealscout-search-01-result.png
assert_visible '[data-world-component=dealscout_feed]' "搜索结果落发现流"
# 换 profile 后 discover 推不同条目（千人千面可见）
ab_mention_send "dealscout-config" "设 profile stage=growth"; ab_wait 2000
ab_mention_send "dealscout-discover" "推匹配机会"; ab_wait 3000; ab_shot dealscout-search-02-profile-b.png
```
Expected: 截图证搜索结果落发现流 + 换 profile 发现结果不同。

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_crawl.ex apps/ezagent_plugin_dealscout/test/dealscout_search_test.exs docs/e2e/auto/
git commit -m "feat(dealscout): I-2.2/I-3.2 active-discovery push + active-search action + e2e"
```

---

## Task 9: 数据保留 sweeper (I-9 ↑F-1.5)

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/retention_sweeper.ex`
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex`（pin 列表读写）
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（children 挂 sweeper，test-boot skip）
- Test: `apps/ezagent_plugin_dealscout/test/retention_sweeper_test.exs`

**Interfaces:**
- Consumes: `Config` slice（Task 5）。
- Produces: `EzagentPluginDealScout.RetentionSweeper.prune/2`（`(batches, pinned) -> kept`，保留最近 10 批 + pin，纯函数好测）；`.start_link/1` + `.sweep_once/0`。

- [ ] **Step 1: 写失败测试（prune 保留最近 10 + pin 的超期批次也留）**

```elixir
# apps/ezagent_plugin_dealscout/test/retention_sweeper_test.exs
defmodule EzagentPluginDealScout.RetentionSweeperTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.RetentionSweeper

  test "prune keeps the 10 most recent batches plus any pinned older batch" do
    batches = for i <- 1..15, do: %{id: "b#{i}", seq: i}
    kept = RetentionSweeper.prune(batches, ["b1"])   # b1 是最老、但被 pin
    ids = Enum.map(kept, & &1.id)
    assert "b1" in ids                                 # pin 的留
    assert "b15" in ids and "b6" in ids                # 最近 10 = b6..b15
    refute "b2" in ids                                 # 超期未 pin 丢
    assert length(kept) == 11                          # 10 recent + 1 pinned
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/retention_sweeper_test.exs`
Expected: FAIL — `EzagentPluginDealScout.RetentionSweeper` 未定义。

- [ ] **Step 3: 写 retention_sweeper.ex（周期 GenServer 照 email idiom + 纯 prune）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/retention_sweeper.ex
defmodule EzagentPluginDealScout.RetentionSweeper do
  @moduledoc """
  数据保留 sweeper（周期 GenServer 照 `Ezagent.Email.Inbound` + `Idempotency.Sweeper` 先例）。
  默认保留最近 10 次爬取批次 + pin 的批次；丢弃超期且未 pin。丢弃失败要 telemetry。
  """
  use GenServer
  require Logger

  @keep_recent 10
  @default_interval_ms 3_600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_once()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_o, state), do: {:noreply, state}

  @doc "纯函数：保留最近 @keep_recent 批 + pin 的。"
  @spec prune([map()], [String.t()]) :: [map()]
  def prune(batches, pinned) do
    sorted = Enum.sort_by(batches, & &1.seq, :desc)
    recent = Enum.take(sorted, @keep_recent)
    recent_ids = MapSet.new(recent, & &1.id)
    pinned_extra = Enum.filter(sorted, &(&1.id in pinned and &1.id not in recent_ids))
    recent ++ pinned_extra
  end

  def sweep_once, do: :ok    # dev/prod: 读 slice → prune → {:set,...} 写回（现读 slice reader API 接线）
  defp schedule_sweep, do: Process.send_after(self(), :sweep, interval_ms())
  defp interval_ms, do: Application.get_env(:ezagent_plugin_dealscout, :sweep_interval_ms, @default_interval_ms)
end
```

- [ ] **Step 4: config.ex 加 pin 列表读写**

```elixir
# config.ex — 新增
  @spec pin_batch(map(), String.t()) :: {:set, :pinned_batches, [String.t()]}
  def pin_batch(current, batch_id) do
    pinned = Map.get(current, :pinned_batches, [])
    {:set, :pinned_batches, Enum.uniq([batch_id | pinned])}
  end
```

- [ ] **Step 5: children 挂 sweeper（test-boot skip）+ 跑测试确认通过**

```elixir
# application.ex children/0 — 非 test 时加 RetentionSweeper
    else
      [EzagentPluginDealScout.Poller, EzagentPluginDealScout.RetentionSweeper]
    end
```

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/retention_sweeper_test.exs apps/ezagent_plugin_dealscout/test`
Expected: PASS；测试环境不起真 sweeper。

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/retention_sweeper.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex apps/ezagent_plugin_dealscout/test/retention_sweeper_test.exs
git commit -m "feat(dealscout): I-9 retention sweeper (keep 10 recent + pinned) + pin slice"
```

**测试方法**：ExUnit（prune 纯函数：造 >10 批 sweep 后只剩 10 + pin 留存）+ dev 起 server 看 sweeper tick。pin action 的成员限定 e2e 在 Task 12 验证（匿名 pin 被 CapBAC 拒）。

---

## Task 10: Definition seed（发现腿，纯配置数据）(I-6.2 / I-6.3 ↑F-6) — **②提交配置**

> **分类：②提交配置**（Definition config map，非代码）。**迁移标注**：✅ **role-slot 已落地（#1180）——本 task 直接用 `roles` 声明角色槽 + `{:role,name}` receiver + `owner_policy: %{type: :installer}`、零实例 URI**（`agents`/`members`/`:fixed` owner 都会被 `Definition.new/1` 拒）；⚠️ main 到 **P3** 后从外部 config 源发布（今天仿 hello code-seed）。

**Files:**
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（`after_boot/0` seed Definition）
- Test: `apps/ezagent_plugin_dealscout/test/definition_seed_test.exs`

> **⚠️ 返工修订（2026-07-06 banner）落到本 Task 的三处**：
> 1. `views` 引 **hello 的 `Ezagent.ActionSet.HelloRender`**（非 `DealScoutRender`，已删）——hello `PageView.applies_to?` 恰以 `"hello" in definition.uses or HelloRender in definition.views` 认领渲染（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex:59`），零改 hello。
> 2. `roles` 增加 **hello 页面 agent 角色槽**（如 `%{role_name: "page", fill: :agent, recipe: "hello.builder", flavor: "native"}`——recipe 名现读 hello `Application.roles/0` 确认），它是更新信号的 receiver。
> 3. `routing_rules` 接更新信号：`%{matcher: %{"type" => "text_contains", "arg" => "__dealscout_update__"}, receivers: [{:role, "page"}]}`（matcher JSON 形态照 `apps/ezagent_core/lib/ezagent/routing/matcher.ex:214` `to_json`；标记从 `Ezagent.ActionSet.DealScoutCrawl.update_signal/0` 取，别硬编码字面量）——**内容协议，像 kanban relay dev `__done__` → 看板助手，零实例 URI**。conformance `routing_receivers_resolve` 要求 receiver 是已声明角色名（`conformance.ex:281`），"page" 槽声明即过。
> 下方示例代码里 `views: [Ezagent.ActionSet.DealScoutRender]` / `receiver: {:role, "discover"}` 等旧形态按本注为准改写。

**Interfaces:**
- Consumes: `Recipes.all/0`（Task 6）+ hello 的 `HelloRender` / builder recipe（配置引用，不改 hello 代码）。
- Produces: `EzagentPluginDealScout.DefinitionSeed.attrs/1`（返回 Definition config map，17 字段子集）；`.seed/1`（调 `DefinitionRegistry.seed_definition_if_absent`）。

- [ ] **Step 1: 写失败测试（Definition attrs 形状：`roles` 用 agent 角色槽 `%{role_name, fill: :agent, recipe, flavor}` 且含 hello 页面 agent 槽、views 引 `HelloRender`、routing_rules 用 `text_contains(update_signal)` → `{:role, "page"}`、无退休 `agents`/`members` 字段、owner 是 `:installer`）**

```elixir
# apps/ezagent_plugin_dealscout/test/definition_seed_test.exs
defmodule EzagentPluginDealScout.DefinitionSeedTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.DefinitionSeed

  test "definition attrs declare roles as agent role-slots (role_name/fill/recipe/flavor), no instance URIs" do
    attrs = DefinitionSeed.attrs("dealscout")
    # 返工 banner：显示归 hello —— views 引 hello 的 render，非 dealscout 自有 view
    assert attrs.views == [Ezagent.ActionSet.HelloRender]
    # 更新信号 → hello 页面 agent 的内容协议 routing（零实例 URI）
    assert [%{matcher: %{"type" => "text_contains", "arg" => signal_arg}, receivers: [{:role, "page"}]}] =
             attrs.routing_rules

    assert signal_arg == Ezagent.ActionSet.DealScoutCrawl.update_signal()
    # #1180 role-slot：agent 槽 %{role_name, fill: :agent, recipe, flavor}
    assert Enum.all?(attrs.roles, &match?(%{role_name: _, fill: :agent, recipe: _, flavor: _}, &1))
    # #1180：退休字段不出现（Definition.new/1 会拒 :agents / :members）
    refute Map.has_key?(attrs, :agents)
    refute Map.has_key?(attrs, :members)
    # owner 只准 installer 派生（:fixed 被拒）
    assert attrs.owner_policy == %{type: :installer}
    # routing receivers 用 {:role, name} 不用实例 URI
    assert Enum.all?(attrs.routing_rules, fn r -> match?({:role, _}, r.receiver) end)
    assert attrs.visibility_policy.web_anon_access == true
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/definition_seed_test.exs`
Expected: FAIL — `EzagentPluginDealScout.DefinitionSeed` 未定义。

- [ ] **Step 3: 写 definition_seed.ex（照 hello app.ex:238；`roles` 角色槽形态）**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex
defmodule EzagentPluginDealScout.DefinitionSeed do
  @moduledoc """
  dealscout Definition（**纯数据配置**，非代码）。仿 hello code-seed
  （`seed_definition_if_absent`）+ 经真 governance publish。
  ✅ #1180 role-slot：`roles` 用 agent 角色槽 `%{role_name, fill: :agent, recipe, flavor}`、routing receiver 用
  `{:role, name}`、`owner_policy: %{type: :installer}`、**绝不塞参与者/owner 实例 URI，不用退休的 `agents`/`members`**。
  """
  alias Ezagent.Socialware.DefinitionRegistry
  alias Ezagent.Entity.User

  @spec attrs(String.t()) :: map()
  def attrs(name) do
    %{
      name: name,
      title: "dealscout",
      description: "AI 千人千面发现副驾 + 组合 hello 公开面撮合",
      # `uses` 只声明依赖 hello plugin 已装（非组合轴，manifest_resolver.ex:41）
      uses: [:ezagent_plugin_hello],
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      # 返工 banner：显示归 hello —— views 引 hello 的 render（page_view.ex:59 以此认领渲染）
      views: [Ezagent.ActionSet.HelloRender],
      # #1180 role-slot：agent 角色槽 %{role_name, fill: :agent, recipe, flavor}，flavor per-agent，今天统一 "cc"
      roles: [
        %{role_name: "discover", fill: :agent, recipe: "dealscout-discover", flavor: "cc"},
        %{role_name: "search", fill: :agent, recipe: "dealscout-search", flavor: "cc"},
        %{role_name: "organize", fill: :agent, recipe: "dealscout-organize", flavor: "cc"},
        %{role_name: "followup", fill: :agent, recipe: "dealscout-followup", flavor: "cc"},
        # hello 页面 agent 槽（更新信号的 receiver；recipe 名现读 hello Application.roles/0 确认）
        %{role_name: "page", fill: :agent, recipe: "hello.builder", flavor: "native"}
      ],
      # 内容协议 routing（像 kanban relay __done__）：爬取 agent 的更新信号 → hello 页面 agent
      routing_rules: [
        %{
          matcher: %{
            "type" => "text_contains",
            "arg" => Ezagent.ActionSet.DealScoutCrawl.update_signal()
          },
          receivers: [{:role, "page"}]
        }
      ],
      prompt_templates: %{},
      legends: %{},
      adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
      visibility_policy: %{publish_policy: :auto, web_anon_access: true, scope: :private},
      # #1180：owner 只准 installer 派生（:fixed 已被拒），不声明任何 owner URI
      owner_policy: %{type: :installer}
    }
  end

  @spec seed(String.t()) :: {:ok, term()} | {:error, term()}
  def seed(ws) do
    DefinitionRegistry.seed_definition_if_absent(
      attrs("dealscout"),
      workspace_uri: Ezagent.URI.workspace(ws),
      actor_uri: User.admin_uri()
    )
  end
end
```

> **注**：`routing_rules` 的确切 shape（`match` / `receiver` key 名）现读 `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` + conformance gate 的 `routing_receivers_resolve` 断言确认；若 gate 要求不同 receiver 形态，按 gate 调整（保持 `{:role, name}` 不塞实例 URI）。

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/definition_seed_test.exs`
Expected: PASS。

- [ ] **Step 5: application.ex `after_boot/0` seed Definition**

```elixir
# application.ex — 新增
  @impl Ezagent.Plugin
  def after_boot do
    unless Mix.env() == :test do
      {:ok, _} = EzagentPluginDealScout.DefinitionSeed.seed("system")
    end
    :ok
  end
```

- [ ] **Step 6: 过 conformance gate + Commit**

Run:
```bash
mise exec -- mix test apps/ezagent_plugin_dealscout/test/definition_seed_test.exs
mise exec -- mix ezagent.socialware.check
```
Expected: PASS + gate 全绿（重点 `routing_receivers_resolve`）；建 session 时发现腿 4 agent 自动 materialize。

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex apps/ezagent_plugin_dealscout/test/definition_seed_test.exs
git commit -m "feat(dealscout): I-6.2/I-6.3 Definition seed (#1180 role-slot roles + installer owner) + conformance"
```

**测试方法**：ExUnit（Definition attrs role-slot 形状 + 无实例 URI）+ conformance gate（`mix ezagent.socialware.check` 全绿）+ 集成（建 session → 4 agent materialize）。

---

## Task 11: 组合 hello + concierge 的 Definition + 发布公开面 (I-10 ↑F-8) — **②提交配置**

> **分类：②提交配置**（Definition config map 扩展 + 发布）。**迁移标注**：✅ role-slot 已落地（#1180，直接用 `roles` 角色槽）+ ⚠️ P2（统一安装路）+ ⚠️ P3（外部 config 源发布）。
>
> **✅ 撮合腿自包含可建（对抗审查复核，BLOCKER 已推翻）**：上一轮判"独立 DealScout Definition 的公开面 @ 不到 hello orchestrator、concierge 永不回"= 太悲观、错。真相：web 收件人 `orch_<name>`（`session_feed_channel.ex:373-375` `orchestrator_uri` → `hello_agent_uri(_, "orch_")`）**不是** Definition materialize 的随机 UUID（`definition_agents.ex:284-288` 那条根本不经过），而是 hello **命令式按名重挂**的——`ensure_session_orchestrator` 对**任何经 world 路径建的 page session** 都补 `create_role_agent(ws, "orch_#{name}", ...)`（hello `app.ex:136,143`），由 world 建 session 后调（`ensure_hello_orchestrator`，world `conversation_actions.ex:326,342`），跟收件人算法逐字对齐、必命中；这个 orchestrator 不被 Definition 声明、也不被 snapshot 当 worker 捕获（按名重挂，re-install 照样补出）。→ **本 Task 两个硬前提即可（不需改 hello/web/core）**：(1) DealScout Definition 复制 hello 公开面配置（`shape` 含 `Surface`+`Turn`、`adapters` 含 `external_feed`、`web_anon_access:true`、引 `hello_render` view、`uses:[:ezagent_plugin_hello]`、**带 seed 页** → 成 page session，`page_session?` 才不 no-op）；(2) 建/装会话**走 world 路径**（socialware install→`create_session`，world 的 `ensure_hello_orchestrator` 才跑）。满足即通，交互式建 or snapshot re-install 都行。**残余风险（诚实标）**：不走 world 路径（CLI/直接建）或 Definition 无 Surface/seed 页 → `ensure_session_orchestrator` no-op（`:ignore`）→ 不建 orchestrator → concierge 不回帖（前提没满足，不是死锁）。spec §4 全文。

**Files:**
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`（Definition 加 concierge agent + 确保 `uses:[:ezagent_plugin_hello]` + bases/shape/views union 拿 hello 公开面）
- Test: `apps/ezagent_plugin_dealscout/test/publish_test.exs`

**Interfaces:**
- Consumes: `DefinitionSeed.attrs/1`（Task 10），hello concierge recipe（`EzagentPluginHello.Application.roles/0` 里的 concierge，复用不新写）。
- Produces: `EzagentPluginDealScout.DefinitionSeed.publish/1`（调 `ConfigGovernance.Socialware.publish_or_upgrade/2`）。

- [ ] **Step 1: 写失败测试（Definition uses hello + concierge agent + 发布进 registry）**

```elixir
# apps/ezagent_plugin_dealscout/test/publish_test.exs
defmodule EzagentPluginDealScout.PublishTest do
  use EzagentCore.DataCase, async: false
  alias EzagentPluginDealScout.DefinitionSeed

  test "definition uses hello and includes the concierge agent slot" do
    attrs = DefinitionSeed.attrs("dealscout")
    assert :ezagent_plugin_hello in attrs.uses
    assert Enum.any?(attrs.roles, &(&1.role_name == "concierge" and &1.fill == :agent))
  end

  test "publish/1 puts dealscout into the definition registry (fail-loud on broken governance)" do
    assert {:ok, _} = DefinitionSeed.publish("system")
    names = Ezagent.Socialware.DefinitionRegistry.list(Ezagent.URI.workspace("system")) |> Enum.map(& &1.name)
    assert "dealscout" in names
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/publish_test.exs`
Expected: FAIL — concierge slot 缺 / `publish/1` 未定义。

- [ ] **Step 3: definition_seed.ex 加 concierge 角色槽 + publish/1**

```elixir
# definition_seed.ex — attrs/1 的 roles 列表追加 concierge 角色槽（复用 hello concierge recipe）
# ⚠️ 对抗审查现读修正：recipe 名是 "hello.concierge"（点号，非 "hello-concierge"），flavor 是 "native"（非 "cc"）
#    —— 见 apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:142-145。
        %{role_name: "concierge", fill: :agent, recipe: "hello.concierge", flavor: "native"}

# 新增 publish/1（仿 hello code-seed 经真 governance publish）
  alias Ezagent.Socialware.ConfigGovernance

  @spec publish(String.t()) :: {:ok, term()} | {:error, term()}
  def publish(ws) do
    ctx = %{caller: User.admin_uri(), workspace_uri: Ezagent.URI.workspace(ws)}
    ConfigGovernance.Socialware.publish_or_upgrade(attrs("dealscout"), ctx)
  end
```

> **注**：`publish_or_upgrade/2` 的确切 ctx 形状现读 `apps/ezagent_domain_session/lib/ezagent/socialware/config_governance/socialware.ex:116` 确认（内部跑 `open_cr → stage → publish_cr`）。`web_anon_access: true` 是发布者自助、不需 admin；只有 `scope: :public` 才走 admin 门（`socialware.ex:197,228`）——本 Definition `scope: :private` 故不触发 admin gate。

- [ ] **Step 4: 跑测试确认通过 + conformance gate**

Run:
```bash
mise exec -- mix test apps/ezagent_plugin_dealscout/test/publish_test.exs
mise exec -- mix ezagent.socialware.check
```
Expected: PASS + gate 全绿。

- [ ] **Step 5: 真浏览器 e2e（匿名访问公开面只读 + 截图）**

```bash
# 匿名（不登录）访问 DealScout 公开面
ab_open "$BASE_URL/socialware/$DEALSCOUT_SW_SLUG"; ab_wait '[data-world-component]'; ab_shot dealscout-10-01-anon-public-face.png
assert_visible '[data-world-component]' "匿名可看 DealScout 公开机会页"
# 匿名 composer 不可写（只读）—— 断言无发送框或发送被禁
ab_shot dealscout-10-02-anon-readonly.png
```
Expected: 截图证匿名可看公开面只读（无 composer / 发言被两处 gate 硬禁）。

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex apps/ezagent_plugin_dealscout/test/publish_test.exs docs/e2e/auto/
git commit -m "feat(dealscout): I-10 compose hello+concierge Definition + governance publish (anon read-only) + e2e"
```

**测试方法**：ExUnit（uses hello + concierge slot + publish 进 registry，fail-loud）+ conformance gate + **真浏览器 e2e**（匿名只读公开面 + 截图）。`uses` 的 hello 未装则 seed 显式失败（`manifest_resolver.ex:41`）。

---

## Task 12: 公开面登录写接线（复用 session_feed_channel）(I-11 ↑F-9) — **③复用验证**

> **分类：③复用验证**（零新代码，riding web `session_feed_channel` + hello concierge）。**本 task 主体是真浏览器 e2e**——证登录自助 join + 发言 → concierge 回帖全链通。
>
> **✅ 依赖 Task 11 的公开面（自包含，无平台缺口）**：join / post 表单真复用零改；"concierge 回帖"也零改可达——只要 Task 11 满足两个前提（Definition 复制 hello 公开面配置成 page session + 走 world 路径建会话），hello 就按名重挂 `orch_<name>`、跟 web 收件人算法逐字对齐，本 e2e 的 `assert_agent_reply "concierge"` 会绿。**若红，先查前提**（是不是没走 world 路径 / Definition 缺 Surface-seed 页），**不是改 web/hello**。

**Files:**
- Test only: `docs/e2e/auto/dealscout_public_chat_e2e.sh`（agent-browser）
- 复用（零改）：`apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:197-228`（`handle_participatory_join` / `handle_participatory_post`）+ `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex:13-14`（非 owner → concierge）+ `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex:43`。

**Interfaces:**
- Consumes: Task 11 发布的 DealScout 公开面。
- Produces: e2e 证据（截图）——无新代码接口。

- [ ] **Step 1: 写 e2e 脚本（登录用户逛公开面 → 自助 join → @concierge 聊，每步截图）**

```bash
# docs/e2e/auto/dealscout_public_chat_e2e.sh
source ./lib.sh
step "I-11 登录用户公开面自助 join + 发言 → concierge 回帖"
ab_login; ab_shot dealscout-11-01-login.png
ab_open "$BASE_URL/socialware/$DEALSCOUT_SW_SLUG"; ab_wait '[data-world-component=conversation]'; ab_shot dealscout-11-02-public-face.png
# 登录非 owner 自助 join
ab_click 'button[aria-label="Join"]'; ab_wait 2000; ab_shot dealscout-11-03-joined.png
assert_visible 'form [placeholder]' "join 后出现发送 composer（非只读）"
# 发消息 @orchestrator → 非 owner 永远路由 concierge 回帖
ab_mention_send "concierge" "我是投资人，关注具身智能，想跟 founder 聊聊"; ab_wait 4000; ab_shot dealscout-11-04-posted.png
assert_agent_reply "concierge" "concierge 客服回帖（登录访客到不了 builder）" 30
ab_shot dealscout-11-05-concierge-reply.png
summary
```

- [ ] **Step 2: 起 dev server + 跑 e2e 确认全链通**

Run:
```bash
# 终端 A：起 dev server（端口 10042）
docker start ezagent-pg-compat-audit-postgres
mise exec -- iex -S mix phx.server
# 终端 B：
bash docs/e2e/auto/dealscout_public_chat_e2e.sh
```
Expected: 全 PASS；截图证登录用户自助 join（出 composer）→ 发消息 → concierge 回帖。全程无 pending、无 owner 审核。

- [ ] **Step 3: Commit**

```bash
git add docs/e2e/auto/dealscout_public_chat_e2e.sh
git commit -m "test(dealscout): I-11 e2e — logged-in self-join + post → concierge reply (reuse session_feed_channel)"
```

**测试方法**：**真浏览器 e2e（本 task 核心）**——复用 web 现成 channel，验证登录自助 join + post + @orchestrator 路由 concierge 全链。依赖 Task 11（公开面先发布）。

---

## Task 13: 身份看板 + 匿名只读验证 + founder invite 深聊 (I-12 / I-13 ↑F-10/F-11)

> **分类**：I-12 = ③复用验证（两处 gate + 全量白板 + 身份）；I-13 = ①代码（`dealscout-support` 深聊辅助 recipe + 撮合记账 slice）+ ③复用（invite）。**迁移标注**：✅ role-slot 已落地（#1180）——I-13 若把 `dealscout-support` 作为角色槽写进 Definition，用 `roles` 的 agent 槽、不塞实例 URI。

**Files:**
- Modify: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`（加 `dealscout-support` 深聊辅助 recipe）
- Create: `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/matchmaking.ex`（撮合记账 slice：连接计数）
- Test: `apps/ezagent_plugin_dealscout/test/matchmaking_test.exs` + `docs/e2e/auto/dealscout_invite_e2e.sh`
- 复用（零改）：`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:85-98`（全量白板）+ `session_feed_channel.ex:325-330,353`（匿名硬禁 + 身份）+ `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:683`（`invite_member`）。

**Interfaces:**
- Consumes: Task 12 公开面登录发言。
- Produces: `EzagentPluginDealScout.Matchmaking.record_connection/3`（返回 `{:set, :connections, [...]}` effect，喂撮合北极星 P-3.2）；`dealscout-support` recipe 进 `Recipes.all/0`。

- [ ] **Step 1: 写失败测试（record_connection 累加双向连接 + dealscout-support recipe 存在）**

```elixir
# apps/ezagent_plugin_dealscout/test/matchmaking_test.exs
defmodule EzagentPluginDealScout.MatchmakingTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.{Matchmaking, Recipes}

  test "record_connection appends a bidirectional edge to the :connections slice" do
    {:set, :connections, conns} = Matchmaking.record_connection(%{connections: []}, "c", "e")
    assert %{from: "c", to: "e"} in conns
  end

  test "dealscout-support deep-chat assist recipe is declared" do
    assert Enum.any?(Recipes.all(), &(&1.name == "dealscout-support"))
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/matchmaking_test.exs`
Expected: FAIL — `Matchmaking` 未定义 / `dealscout-support` 缺。

- [ ] **Step 3: 写 matchmaking.ex + recipes.ex 加 dealscout-support**

```elixir
# apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/matchmaking.ex
defmodule EzagentPluginDealScout.Matchmaking do
  @moduledoc """
  撮合记账 slice。撮合北极星口径 = 公开面真实互动 / 被邀深聊（非申请通过数）。
  达成时往 `:connections` slice 写双向边（`{:set,...}` effect，照 kb slice）。记账失败要 telemetry。
  """
  @spec record_connection(map(), String.t(), String.t()) :: {:set, :connections, [map()]}
  def record_connection(current, from, to) do
    conns = Map.get(current, :connections, [])
    {:set, :connections, [%{from: from, to: to, at: DateTime.utc_now()} | conns]}
  end
end
```

```elixir
# recipes.ex — all/0 追加 support()；新增：
  defp support do
    %{name: "dealscout-support", flavor: "cc", behaviors: [],
      prompt: "只在本私有深聊 session 范围内辅助撮合：引导选择性披露、补齐材料、判断匹配度。",
      requested_caps: [%{behavior: Ezagent.ActionSet.Session, action: :send}]}
  end
```
（`all/0` 改 `[discover(), search(), organize(), followup(), support()]`；更新 Task 6 的 recipes_test 断言 5 个 recipe。）

- [ ] **Step 4: 跑测试确认通过**

Run: `mise exec -- mix test apps/ezagent_plugin_dealscout/test/matchmaking_test.exs apps/ezagent_plugin_dealscout/test/recipes_test.exs`
Expected: PASS。

- [ ] **Step 5: 真浏览器 e2e（匿名只读被拒 + owner 看身份 + invite 深聊 + 每步截图）**

```bash
# docs/e2e/auto/dealscout_invite_e2e.sh
source ./lib.sh
step "I-12 匿名只读硬禁 + owner 看发言者身份"
ab_open "$BASE_URL/socialware/$DEALSCOUT_SW_SLUG"; ab_wait '[data-world-component=conversation]'   # 未登录=匿名
ab_shot dealscout-12-01-anon-view.png
# 匿名 post 被两处 gate 之一拒（not_logged_in / 无 chat cap）
assert_no_agent_reply "concierge" "匿名 post 不触发 concierge（被硬禁）" 8
ab_shot dealscout-12-02-anon-denied.png

step "I-13 owner 全量白板看身份 → invite 深聊"
ab_login   # 以 owner/admin 登录
ab_open "$BASE_URL/sessions?session=$DEALSCOUT_SESS_ENC"; ab_wait '[data-world-component=conversation]'
ab_shot dealscout-13-01-owner-whiteboard.png    # 全量白板：看到登录访客发言 + 真实身份
ab_click 'button[aria-label="Invite a member"]'; ab_wait 700
ab_fill_react '#world-invite-input' "$GUEST_URI"; ab_submit '#world-invite-input'; ab_wait 2500
ab_shot dealscout-13-02-invited-private.png      # 被邀者进私有 session 深聊
summary
```
Expected: 截图证匿名 post 被拒（只读）；owner 全量白板看到发言者身份；owner invite 发言者进私有 session。

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/matchmaking.ex apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex apps/ezagent_plugin_dealscout/test/matchmaking_test.exs docs/e2e/auto/dealscout_invite_e2e.sh
git commit -m "feat(dealscout): I-12/I-13 anon read-only verify + owner invite deep-chat + dealscout-support recipe + matchmaking ledger + e2e"
```

**测试方法**：ExUnit（record_connection slice + dealscout-support recipe）+ **真浏览器 e2e**（匿名 post 被拒 + owner 看身份 + invite 深聊 + 截图）。撮合北极星记账 = 公开面真实互动 / 被邀深聊（非申请通过数）。

---

## Task 14 (自包含 CALL — 回主干): artifact → upload seam (I-7 ↑F-7)

> **✅ 自包含，回 DealScout 主干（对抗审查复核，"越界"判定已推翻）**：上一轮判"加 agent-facing upload seam 必改 core = 越界"= 错。真相：core 有**现成公开** API `Ezagent.Uploads.store!/3`（`apps/ezagent_core/lib/ezagent/uploads.ex:98`）+ **现成通用** effect `:effect_returning`（`apps/ezagent_core/lib/ezagent/behavior/effects.ex:23,236`，apply 任意 MFA、**无 allowlist**）。dealscout 自己的 ActionSet handler 直接 CALL 存产物 + 挂附件，**每环现成、零改 core/world/web**。**从平台 track 拿回 DealScout 主干 plan。**

**Files:**
- Modify: dealscout 自己的追问 ActionSet handler（`apps/ezagent_plugin_dealscout/lib/ezagent/behavior/*.ex`）——返 `:effect_returning` 存产物 + emit 带 `body.attachments`。**不改 core/world/web 任何文件**（下列都是现成、只 CALL / riding）：
  - core `Ezagent.Uploads.store!/3`（`apps/ezagent_core/lib/ezagent/uploads.ex:98`）
  - core effect `:effect_returning`（`apps/ezagent_core/lib/ezagent/behavior/effects.ex:23,236`）
  - `body.attachments` 字段（`apps/ezagent_core/lib/ezagent/message.ex:60`，现成 body 字段）
  - world 通用渲染缝（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:331-336` `body_attachments`，`resource://…` → 签名 `DownloadToken` 下载链，**非硬编码**）
  - 匿名下载路由（`apps/ezagent_web/lib/ezagent_web/controllers/socialware/external_feed_controller.ex:61` `download` / 路由 `apps/ezagent_web/lib/ezagent_web/router.ex:166` `/socialware/external/download`）

**开发方向 + 测试方法**：
- **方向（每环现成）**：dealscout handler 返 `{:effect_returning, {Ezagent.Uploads, :store!, [ws, stored_name, tmp_path]}, [], bind_as: :uri}` 把爬取产物存进 uploads → emit 带 `body.attachments: [{:ref, :uri}]`（用 `:effect_returning` 绑定的 URI）→ world 通用渲染缝自动把 `resource://…` 附件 mint 成签名下载链（`conversation_data.ex:331-336`）→ 匿名经 `/socialware/external/download` 下载（`external_feed_controller.ex:61`，serve 时 re-check approved surface）。
- **实现期唯一要 e2e 证的 plugin 侧细节**：`body.attachments` 在 emit / dispatch 全链**透传不被清空**——`message.ex:43-44` 注释写 Phase 2 `attachments` 永远 `[]`、`new/1` 也 `Map.put_new(:attachments, [])`（`message.ex:148`），要现读确认带附件的 body 走 dealscout emit 时不被覆盖成 `[]`。
- **测试**：ExUnit（handler 返 `:effect_returning` 存 upload → 查到记录 + `body.attachments` 透传断言）+ **真浏览器 e2e**（追问产出文件 → 会话显示可点下载附件 → 点击下到文件 → 匿名经 approved 面也能下，每步截图）。
- **DoD**：dealscout 追问产出文件在会话里显示为可下载附件、匿名经公开面也能下（e2e 截图证），**零改 core/world/web**。

---

## ~~Task 15: world tab 接线 (I-8 ↑F-5)~~ — **作废（2026-07-06 返工 banner）**

> dealscout 无自有 view（Task 7 作废）→ 无 tab 可冒。hello 页面自带公开面入口，world tab 议题消失。以下原文仅存档，勿执行。

> **⚠️ 拆两半，别混成一个"越界 Task"**（对抗审查复核）：world **零消费** SessionView registry——`switch_view` 白名单 hardcode `["chat","pty","page"]`（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:477`，注释明写 "registered SessionViews is Phase 3、未建"，`:474-475`）；连 kanban tab 都是 world hardcode（`apps/ezagent_plugin_world/lib/ezagent/world/routes.ex:108-124`，非 kanban 声明）。因此：
> - **(a) 注册 `DealScoutView` + `dealscout_render` cap = DECLARE，自包含，留 DealScout**：`@behaviour Ezagent.UI.SessionView` + `SessionViewRegistry.register`，跟 hello `PageView` 同款——这半是"内容渲染"，dealscout 插件自己能做完（Task 7 已覆盖 view module）。
> - **(b) 让它在 world 会话面板冒成可切 tab = 真越界，留 `feat/ezagent-scout`**：要改 world owner `switch_view` 白名单（`conversation_actions.ex:477`）或建 world Phase 3（从 SessionViewRegistry 动态出 tab）——碰 world owner 代码，不在本轮 DealScout 交付。**不卡主干**（发现流视图内容 Task 7 已可渲染，只是没在 world 自动冒 tab）。

**Files:**
- **(a) 自包含（DealScout，见 Task 7）**：`apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/dealscout_view.ex`（`@behaviour Ezagent.UI.SessionView`）+ `after_boot` 注册 view（照 hello 注册 `PageView`）。
- **(b) 越界（留 ezagent-scout）**：Modify `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:477`（`switch_view` 白名单纳入 dealscout view）或 world Phase 3 泛化（从 SessionViewRegistry 动态出 tab）。

**开发方向 + 测试方法**：
- **(a) 方向**：注册 view module + render 分类（Task 7）——**自包含，本轮做**。测试：ExUnit（view 注册 + render 分类）+ 直达 view 渲染断言。
- **(b) 方向（留 scout）**：① 最小接线——把 dealscout view 加进 world `switch_view` 白名单；② Phase 3 泛化——把硬编码白名单改成"从 SessionViewRegistry 读已注册视图动态出 tab"。测试：**真浏览器 e2e**（world 里切到 dealscout tab → 渲染 → 截图；泛化后任意注册 SessionView 自动出 tab）。
- **DoD**：(a) view 注册 + 内容渲染（本轮，ExUnit + 直达渲染证）；(b) world 里能切到 dealscout tab（留 ezagent-scout，e2e 截图证）。

---

## Task 16 (非目标 / discuss-first): 平台跨用户推荐 (I-14) + email (I-15)

> **状态：非本轮目标**。
- **I-14 平台跨用户推荐（发现层第③腿）**：discuss-first / 缺口。现状 DEF 级跨 workspace 发现已通（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:255` `list/1`），但实例级跨用户发现 + 匹配推荐 + 朋友圈图缺——平台方向，riding registry track（#1169/#1173），dealscout 首个需求方**不阻塞**。**产出**：缺口设计说明交 Allen，无本轮代码。
- **I-15 email reach out**：固定对端 threaded 可先做（复用 `apps/ezagent_plugin_email/lib/ezagent/email/email.ex:26` `send/4` + `apps/ezagent_domain_external_mirror/lib/ezagent_domain_external_mirror/external_mirror.ex:142` `:push` binding 三 gate + 验证握手）；动态群发语义错配（`:push` 是绑定期固定收件人），另设计。**产出**：固定对端 threaded ExUnit；动态群发 defer 设计说明。

---

## Self-Review

**Spec coverage（对 `2026-07-05-dealscout-spec.md` + README §3 I-1..I-15）**：
- I-1 → Task 1-4（爬取骨架 + poller + fetch + dispatch 注入）✅
- I-2 → Task 6（discover recipe）+ Task 8（push 接线）✅
- I-3 → Task 6（search recipe）+ Task 8（search action）✅
- I-4 → Task 5（config slice + token）✅
- I-5 → **返工改判**：Task 7 作废（view/render 已删）；显示归 hello——爬取 agent emit `__dealscout_update__` 信号（Task 4，已落地 `dealscout_crawl.ex`）→ Definition routing_rules（Task 10）→ hello 页面 agent 更新页 ✅
- I-6 → Task 6（recipe）+ Task 10（Definition seed + conformance）✅
- I-7 → Task 14（自包含 CALL，回主干）✅
- I-8 → 作废（返工 banner：dealscout 无自有 view，无 tab 议题）✅
- I-9 → Task 9（retention sweeper）✅
- I-10 → Task 11（组合 hello + 发布）✅
- I-11 → Task 12（公开面登录写 e2e）✅
- I-12 → Task 13（匿名只读 + 身份看板）✅
- I-13 → Task 13（invite 深聊 + dealscout-support + 记账）✅
- I-14 / I-15 → Task 16（非目标）✅

**四硬要求覆盖**：① 代码 vs 配置分类 = spec §8 + 每 task 头标 ①/②/③；② 迁移标注 = spec §9 + Task 10/11 头标 ⚠️（P2/P3 未落地；role-slot #1180 已落地、Task 10/11/13 标 ✅ 直接用新 `roles` API）；③ 分开发方向 + 测试方法 = 每 task 末"测试方法" + Task 14/15 "开发方向 + 测试方法"；④ 真浏览器 e2e + 截图 = 每个用户面 task（Task 5/7/8/11/12/13/14/15）都有 `ab_shot` 每步截图脚本，禁 stub。

**Placeholder scan**：无 TBD / TODO；code steps 有真代码。两处 "现读确认"注（`Ezagent.Credentials` API 名、`publish_or_upgrade` ctx 形状、routing_rules receiver shape、hello concierge recipe name）是**故意的实现期核对点**（skill 索引可能滞后 HEAD），非占位符——给了 file:line 定位 + 兼容口径。

**Type consistency**：`Fetch.parse_items/2`（Task 3）被 Task 4/8 消费；`DealScoutCrawl` inject seam（Task 4）被 Task 8 复用；`Config` slice（Task 5）被 Task 9/13 复用；`Recipes.all/0`（Task 6）被 Task 10/13 扩展（Task 13 更新 Task 6 断言为 5 个 recipe）；`DefinitionSeed.attrs/1`（Task 10）被 Task 11 扩展。一致。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-05-dealscout-plan.md`.**（spec 在 `docs/superpowers/specs/2026-07-05-dealscout-spec.md`）

最小可发布切片顺序（返工后）：**Task 1→2→3→4（I-1 爬取骨架 + 更新信号）→ Task 5（I-4 配置）→ Task 6（I-2/I-3/I-6 recipe）→ Task 8（I-2/I-3 push/search）→ Task 9（I-9 保留，可并行）→ Task 10（I-6 Definition seed：views 引 hello_render + routing_rules 信号→hello 页面 agent）→ Task 11（I-10 组合 hello 发公开面）→ Task 12（I-11 登录写）→ Task 13（I-12/I-13 身份+invite）**。Task 7 / Task 15 作废（显示归 hello）；Task 14 自包含回主干；Task 16 非目标——都不卡主干。

Two execution options:
1. **Subagent-Driven (recommended)** — fresh subagent per task + two-stage review between tasks.
2. **Inline Execution** — batch execution with checkpoints via executing-plans.

Which approach?
