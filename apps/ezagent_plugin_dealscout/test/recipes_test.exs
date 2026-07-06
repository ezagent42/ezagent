defmodule EzagentPluginDealScout.RecipesTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.Recipes

  test "declares the four discovery-leg recipes with caps + three-part shape" do
    names = Recipes.all() |> Enum.map(& &1.name) |> Enum.sort()

    assert names == [
             "dealscout-discover",
             "dealscout-followup",
             "dealscout-organize",
             "dealscout-search"
           ]

    for r <- Recipes.all() do
      assert is_binary(r.prompt) and r.prompt != ""
      assert is_list(r.requested_caps) and r.requested_caps != []
      assert r.behaviors == []
    end
  end

  test "the crawl-driving agents (discover / search) hold the :crawl_now cap" do
    crawl_cap = %{behavior: Ezagent.ActionSet.DealScoutCrawl, action: :crawl_now}
    by_name = Map.new(Recipes.all(), &{&1.name, &1})

    assert crawl_cap in by_name["dealscout-discover"].requested_caps
    assert crawl_cap in by_name["dealscout-search"].requested_caps
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
