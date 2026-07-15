defmodule EzagentPluginCrawler.DealscoutPageE2eTest do
  @moduledoc """
  段4 端到端最小证明（ExUnit 级，真 dispatch）——发布 → 装配 → 线索入
  slice/会话 → view render → committed 公开页，全链零操作员干预：

    1. **发布**：shipped manifest（唯一名 seam）经 `ManifestResolver.resolve`
       装配核验后 `DefinitionRegistry.seed_definition_if_absent` 发布。
    2. **装配**：session 宿主带 Definition 行为集（Crawler/CrawlerRender/
       Turn/Surface）真实 spawn；install 记录走生产 API
       `Installation.install_template_installs`（LeadsView.applies_to? 与
       匿名读门 `PublicView.web_anon_access?` 读的就是这些行）；page 槽
       （crawler-page × native）经 install 车道同一入口
       `DefinitionAgents.materialize_definition_agents` 物化 + faceted join。
    3. **线索入 slice/会话**：`crawler.crawl_now` **真 Invocation.dispatch**
       （fixture 驱动 fetch seam——HN 形状的真实字段；dispatch/授权/effect
       全真，无 stub 假数据直塞 render）。
    4. **view render**：`LeadsView.external_render/1` 输出含真爬取字段。
    5. **committed 公开页**：crawl 的直呼腿 → page 成员 `:publish_page` →
       supervised Task 驱动 turn.open/compose/settle → `ExternalFeed.snapshot`
       以**非成员** reader 读到 approved+committed 的真数据页（匿名读门的
       同一 `read_authorized` 兜底：web_anon_access true 的公开会话）。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation, ManifestResolver}
  alias Ezagent.Socialware.ShippedManifest
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents
  alias EzagentPluginCrawler.LeadsView

  @manifest_relpath "dealscout/manifest.yaml"
  @workspace_uri URI.new!("workspace://system")
  @admin_uri URI.new!("entity://system/user/admin")

  setup do
    for app <- [
          :ezagent_domain_session,
          :ezagent_domain_socialware,
          :ezagent_plugin_crawler,
          :ezagent_plugin_native
        ] do
      {:ok, _} = Elixir.Application.ensure_all_started(app)
    end

    # `RoleSeedHook` skips in :test — seed the crawler recipes（含 crawler-page）.
    Enum.each(EzagentPluginCrawler.Recipes.all(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    :ok =
      case DefinitionRegistry.seed_builtin_definitions() do
        :ok -> :ok
        {:error, {:socialware_definition_seed_collision, _}} -> :ok
      end

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_crawler, :fetch_fun)
    end)

    :ok
  end

  # HN 形状的真实字段 fixture（title/url/summary/points 语义与
  # `Fetch.parse_items` 的真解析产物同构）——驱动的是真 dispatch 链，
  # 不是把数据直接塞进 render。
  defp fixture_leads do
    [
      %{
        title: "Show HN: Postgres wire-compatible proxy",
        url: "https://news.ycombinator.com/item?id=1001",
        summary: "front_page · 214 points",
        source: "hn",
        ts: ~U[2026-07-10 00:00:00Z],
        source_type: :public
      },
      %{
        title: "Launch: OSS crawler toolkit v2",
        url: "https://news.ycombinator.com/item?id=1002",
        summary: "front_page · 88 points",
        source: "hn",
        ts: ~U[2026-07-10 00:01:00Z],
        source_type: :public
      }
    ]
  end

  @tag timeout: 120_000
  test "发布→装配→crawl_now 真 dispatch→线索入 slice→view render→committed 公开页（非成员可读）" do
    n = System.unique_integer([:positive])
    name = "dealscout-page-e2e-#{n}"

    # 1) 发布：shipped manifest（唯一名）→ resolve（装配核验）→ registry 发布。
    attrs = ShippedManifest.load!(@manifest_relpath, name: name)
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(attrs)
    assert definition.views == [Ezagent.ActionSet.CrawlerRender]

    assert {:ok, _} =
             DefinitionRegistry.seed_definition_if_absent(
               Definition.body(definition),
               workspace_uri: @workspace_uri,
               actor_uri: @admin_uri
             )

    # 2) 装配：session 宿主带 Definition 行为集（真实 spawn）+ install 记录 +
    #    page 槽物化（install 车道同一入口）。
    session_uri = Ezagent.URI.session("system", "generic", "dealscout-page-e2e-#{n}")

    behaviors = Enum.uniq(Session.behaviors() ++ Definition.behaviors(definition))
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: behaviors})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{"installs" => [name]},
               @admin_uri
             )

    # install 行落地 → view 的 applies_to? 与匿名读门都从这里读。
    assert LeadsView.applies_to?(session_uri)
    assert Ezagent.Socialware.PublicView.web_anon_access?(session_uri)

    page_slot = Enum.find(definition.roles, &(&1.fill == :agent and &1.role_name == "page"))
    assert page_slot.recipe == "crawler-page"
    assert page_slot.flavor == "native"

    assert {:ok, %{skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @admin_uri,
               [page_slot]
             )

    # 3) crawl_now 真 dispatch（fixture 驱动 fetch seam；dispatch/授权/effect
    #    全真）。admin genesis 授权（操作员/成员触发的同一授权轴）。
    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources ->
      {:ok, fixture_leads()}
    end)

    assert {:ok, %{injected: 2}} =
             Ezagent.Invocation.dispatch(%Ezagent.Invocation{
               target: Ezagent.URI.with_action(session_uri, :crawler, :crawl_now),
               mode: :call,
               args: %{},
               ctx: %{
                 caller: @admin_uri,
                 caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                 reply: {:caller_inbox, self()}
               }
             })

    # 线索入 slice（结构化真数据，crawl 的 {:set, :items, ...} effect 落盘）。
    assert {:ok, slice} =
             Ezagent.Kind.get_slice(session_uri, Ezagent.ActionSet.Crawler.state_slice())

    items = Map.get(slice, :items) || Map.get(slice, "items")

    assert Enum.map(items, & &1["title"]) |> Enum.sort() == [
             "Launch: OSS crawler toolkit v2",
             "Show HN: Postgres wire-compatible proxy"
           ]

    # 线索入会话（消息史里逐条注入 + 更新信号）。
    chat = Ezagent.MessageStore.chat_visible_recent(session_uri, 50)
    texts = Enum.map(chat, fn m -> Map.get(m.body, "text") || Map.get(m.body, :text) end)
    assert Enum.any?(texts, &(&1 =~ "Show HN: Postgres wire-compatible proxy"))
    assert Enum.any?(texts, &(&1 =~ Ezagent.ActionSet.Crawler.update_signal()))

    # 4) view render 输出含真爬取字段（external json-render target；shadcn
    #    词表——外部 SPA 现行 renderer 认的根型，段5 e2e 修正）。
    view_tree = LeadsView.external_render(session_uri)
    assert %{"type" => "Stack"} = view_tree
    assert inspect(view_tree) =~ "Show HN: Postgres wire-compatible proxy"
    assert inspect(view_tree) =~ "news.ycombinator.com/item?id=1001"

    # 5) committed 公开页：直呼腿 → page 成员 publish_page → supervised Task
    #    驱动 turn 落 approved+committed 版本树。以**非成员** reader 读
    #    `ExternalFeed.snapshot`（web_anon_access 公开会话的匿名读门兜底）。
    stranger = Ezagent.URI.new!("entity://system/user/e2e-stranger-#{n}")

    page_tree =
      eventually(fn ->
        case Ezagent.Socialware.ExternalFeed.snapshot(session_uri, stranger) do
          {:ok, %{page: %{} = page}} -> page
          _ -> nil
        end
      end)

    assert page_tree, "committed public page did not appear (turn pipeline未落 committed 版本)"
    assert inspect(page_tree) =~ "Show HN: Postgres wire-compatible proxy"
    assert inspect(page_tree) =~ "Launch: OSS crawler toolkit v2"

    # 公开页与 view 是同一投影源（单一真相：CrawlerRender.render_tree）。
    assert page_tree == view_tree
  end

  # --- helpers -------------------------------------------------------------

  defp eventually(fun, deadline_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(200)
          poll(fun, deadline)
        end

      result ->
        result
    end
  end

  defp terminate(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end
end
