defmodule EzagentPluginCrawler.RecipesTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCrawler.Recipes

  # LLM-driven 发现腿 3 个（有 prompt/caps、无 code behaviors）。discover 单列
  # ——2026-07-10 段3 D1 后它是 script-carrying recipe（py 车道，np 先例）。
  @llm_discovery_names [
    "dealscout-followup",
    "dealscout-organize",
    "dealscout-search"
  ]

  test "declares the discovery legs + 入库操作员 + generic crawler-page publish leg" do
    names = Recipes.all() |> Enum.map(& &1.name) |> Enum.sort()

    # dealscout-assistant（2026-07-10 零人工中继 case-2）：cc-headless 入库
    # 操作员，职责在 persona（kanban-assistant 模具），信号路由的 receiver。
    assert names ==
             Enum.sort(
               @llm_discovery_names ++
                 ["dealscout-discover", "dealscout-assistant", "crawler-page"]
             )
  end

  test "LLM discovery-leg recipes carry prompt + caps and NO code behaviors" do
    for r <- Recipes.all(), r.name in @llm_discovery_names do
      assert is_binary(r.prompt) and r.prompt != ""
      assert is_list(r.requested_caps) and r.requested_caps != []
      assert r.behaviors == []
    end
  end

  test "discover is a script-carrying recipe (py 车道，np 先例)：script 注入信号、零 caps、无 prompt" do
    discover = Enum.find(Recipes.all(), &(&1.name == "dealscout-discover"))
    assert discover

    # RF-5b role-script 通道：script 是 priv/python/discover.py，装配时把
    # 占位符替换成 emit 侧代码常量（manifest 权威字面量的镜像——manifest 侧
    # 一致性由 dealscout_manifest_test 锁）。
    assert is_binary(discover.script) and discover.script != ""
    assert discover.script =~ Ezagent.ActionSet.Crawler.update_signal()
    refute discover.script =~ Recipes.update_signal_placeholder()

    # py 车道真实契约 = receive → 文本回复（Domain.Python V1 无 Python→BEAM
    # 请求），script 不 dispatch 任何 action；回复腿自带 inline session.send
    # self-cap（#154）——所以零 requested_caps（np 先例：空 recipe 铸 0 cap，
    # fail-closed），也无 prompt（py create 路只读 script）。
    refute Map.has_key?(discover, :requested_caps)
    refute Map.has_key?(discover, :prompt)

    # fail-honest 契约：抓取失败/零命中的降级回复不带更新信号（不谎报入库）。
    assert discover.script =~ "未发更新信号"
  end

  test "the search agent (crawl-driving) holds the :crawl_now + :publish_page caps" do
    crawl_cap = %{behavior: Ezagent.ActionSet.Crawler, action: :crawl_now}
    # v2 caller-dispatch：crawl 完成后以触发者身份直接 dispatch :publish_page
    # 到 page 成员 —— 触发爬取的 recipe 必须持这个 cap（CapBAC-honest）。
    publish_cap = %{behavior: Ezagent.ActionSet.CrawlerPage, action: :publish_page}
    by_name = Map.new(Recipes.all(), &{&1.name, &1})

    assert crawl_cap in by_name["dealscout-search"].requested_caps
    assert publish_cap in by_name["dealscout-search"].requested_caps
  end

  test "the crawler-page recipe is code-driven (照 hello.builder 形状：CrawlerPage ActionSet + 自己的 :publish_page cap，无 prompt)" do
    # 段4 D2：通用页面发布腿（取代曾借 hello Generator 的临时 ALT）——名字
    # 不带业务词，任何组合 crawler 能力的 socialware 的 page 槽都可引用。
    page = Enum.find(Recipes.all(), &(&1.name == "crawler-page"))
    assert page

    assert page.behaviors == [Ezagent.ActionSet.CrawlerPage]

    assert page.requested_caps == [
             %{behavior: Ezagent.ActionSet.CrawlerPage, action: :publish_page}
           ]

    refute Map.has_key?(page, :prompt)
  end

  test "every recipe is a flavor-agnostic, boot-seedable Ezagent.Agent.Recipe" do
    # `roles/0` recipes are seeded through `Ezagent.Agent.Recipe.new/1` at boot
    # (RecipeRegistry.seed_role_if_absent → validate_recipe → Recipe.new). A recipe
    # that carries a `flavor` field would fail-loud there ({:flavor_field_in_role, _}),
    # so each recipe MUST round-trip cleanly. Flavor is per-agent and lives on the
    # Definition role-slot (a later Stage), NOT on the flavor-agnostic recipe.
    for r <- Recipes.all() do
      refute Map.has_key?(r, :flavor)
      assert {:ok, %Ezagent.Agent.Recipe{}} = Ezagent.Agent.Recipe.new(r)
    end
  end
end
