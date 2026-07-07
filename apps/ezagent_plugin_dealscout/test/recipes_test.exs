defmodule EzagentPluginDealScout.RecipesTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.Recipes

  # 发现腿 4 个（LLM-driven，有 prompt/caps、无 code behaviors）。
  @discovery_names [
    "dealscout-discover",
    "dealscout-followup",
    "dealscout-organize",
    "dealscout-search"
  ]

  test "declares the four discovery-leg recipes plus the temporary page-alt (A① 落地后删)" do
    names = Recipes.all() |> Enum.map(& &1.name) |> Enum.sort()

    assert names == Enum.sort(@discovery_names ++ ["dealscout-page-alt"])
  end

  test "discovery-leg recipes carry prompt + caps and NO code behaviors" do
    for r <- Recipes.all(), r.name in @discovery_names do
      assert is_binary(r.prompt) and r.prompt != ""
      assert is_list(r.requested_caps) and r.requested_caps != []
      assert r.behaviors == []
    end
  end

  test "the crawl-driving agents (discover / search) hold the :crawl_now + :refresh_page caps" do
    crawl_cap = %{behavior: Ezagent.ActionSet.DealScoutCrawl, action: :crawl_now}
    # v2 caller-dispatch：crawl 完成后以触发者身份直接 dispatch :refresh_page
    # 到 page 成员 —— 触发爬取的 recipe 必须持这个 cap（CapBAC-honest）。
    refresh_cap = %{behavior: Ezagent.ActionSet.DealScoutPageRefreshAlt, action: :refresh_page}
    by_name = Map.new(Recipes.all(), &{&1.name, &1})

    assert crawl_cap in by_name["dealscout-discover"].requested_caps
    assert crawl_cap in by_name["dealscout-search"].requested_caps
    assert refresh_cap in by_name["dealscout-discover"].requested_caps
    assert refresh_cap in by_name["dealscout-search"].requested_caps
  end

  test "the page-alt recipe is code-driven (照 hello.builder 形状：ALT ActionSet + 自己的 :refresh_page cap，无 prompt)" do
    # 【显式临时 ALT】A①（#1201 ③，hello 暴露 dispatchable rebuild action）
    # 落地后本 recipe 随 DealScoutPageRefreshAlt 一起整体删除，Demo page 槽
    # 回切 hello.builder。
    alt = Enum.find(Recipes.all(), &(&1.name == "dealscout-page-alt"))
    assert alt

    assert alt.behaviors == [Ezagent.ActionSet.DealScoutPageRefreshAlt]

    assert alt.requested_caps == [
             %{behavior: Ezagent.ActionSet.DealScoutPageRefreshAlt, action: :refresh_page}
           ]

    refute Map.has_key?(alt, :prompt)
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
