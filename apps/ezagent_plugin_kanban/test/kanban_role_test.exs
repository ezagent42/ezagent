defmodule EzagentPluginKanban.KanbanRoleTest do
  @moduledoc """
  K1 acceptance — the `kanban-manager` role recipe + `roles/0` registration
  (RF-4), the kanban-as-role gate.

  The single combined gate (`Recipe.new(recipe)` succeeds with the discriminating
  fields) catches the three plan-folded review corrections at once:

    * BLOCKER-1 — `behaviors: [Ezagent.ActionSet.Kanban]` ONLY (NOT `Connectors`,
      which is not a Behavior); all 20 actions resolve through `Behavior.Kanban`.
    * HIGH-1   — `requested_caps` are cap-template MAPS `%{behavior:, action:}`,
      not bare atoms (`Recipe.new/1` `canon_cap` rejects non-maps).
    * BLOCKER-2 — `passive: true` flows through `Recipe.new/1` onto `%Recipe{}`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Recipe
  alias Ezagent.{Agent.RecipeRegistry, ActionSet.Kanban}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @recipe_name "kanban-manager"

  setup do
    # role-as-data: the read-through registry lives in domain_agent (ETS cache +
    # ConfigStore resolution); ensure it is up. DataCase checks out the DB sandbox
    # the seed/lookup use.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  test "kanban-manager recipe is in roles/0" do
    assert KanbanApp.kanban_manager_recipe() in KanbanApp.roles(),
           "roles/0 must publish the kanban-manager recipe (RF-4 boot registration)"
  end

  test "role-as-data — roles/0 → seed_role_if_absent → read-through lookup round-trip" do
    # role-as-data (SPEC §4): boot SEEDS each roles/0 recipe as a ConfigObject;
    # `lookup` resolves read-through over ConfigStore. This drives that path
    # directly: seed the recipe, flush the ETS cache (proving the next lookup
    # resolves from ConfigStore, not a surviving cache write), then look it up.
    # seed_role_if_absent is idempotent for an identical recipe ({:ok, :seeded |
    # :exists}), so this is safe whether or not boot already seeded it.
    Enum.each(KanbanApp.roles(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    assert {:ok, %Recipe{name: @recipe_name, behaviors: [Kanban], passive: true}} =
             RecipeRegistry.lookup(@recipe_name)
  end

  test "Recipe.new/1 accepts the recipe with the discriminating fields (K1 combined gate)" do
    recipe = KanbanApp.kanban_manager_recipe()

    assert {:ok, %Recipe{} = role} = Recipe.new(recipe)

    # BLOCKER-1: behaviors is EXACTLY [Behavior.Kanban] — Connectors is not a
    # Behavior and must NOT appear; the 20 actions all resolve through Kanban.
    assert role.behaviors == [Kanban]

    # BLOCKER-2: passive flows through onto the struct.
    assert role.passive == true

    assert role.name == @recipe_name

    # HIGH-1: requested_caps are atom-keyed cap-template MAPS — one per action,
    # carrying ONLY {behavior, action} (no `kind` materialization axis). The
    # count + shape pin the recipe; `==` on the whole struct would be brittle.
    actions = Kanban.actions()
    assert length(actions) == 20, "kanban declares exactly 20 actions (gh connector removed)"
    assert length(role.requested_caps) == 20

    assert Enum.all?(role.requested_caps, fn cap ->
             is_map(cap) and cap.behavior == Kanban and cap.action in actions and
               not Map.has_key?(cap, :kind)
           end),
           "every requested_cap must be %{behavior: Behavior.Kanban, action: <action>}"

    # The cap set covers EVERY declared action (no missing / extra).
    assert MapSet.new(role.requested_caps, & &1.action) == MapSet.new(actions)

    # Taxonomy §4.1 de-bake: the 9-stage product-dev chain + CI/import defaults
    # are BUSINESS semantics carried as recipe `config` DATA (layer 2), NOT
    # hardcoded in Behavior.Kanban (layer 1). The Behavior reads them back via
    # RecipeRegistry at runtime; this asserts the data is present + well-shaped.
    assert role.config == %{
             stages: [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr],
             ci_stage: :pr,
             import_default_stage: :feature
           }
  end

  test "a recipe with bare-atom caps is REJECTED (HIGH-1 guard)" do
    bad = %{
      name: @recipe_name,
      passive: true,
      behaviors: [Kanban],
      requested_caps: [:add_node]
    }

    assert {:error, {:invalid_role_field, :requested_caps, :add_node}} = Recipe.new(bad)
  end

  # 提纯(Task 1):`kanban-assistant` / `dev-together` 两个"脑"配方已从 plugin
  # `roles/0` 搬到 sw seed 数据(`priv/socialware_seed/kanban/recipes.yaml`),由
  # `ManifestSeed.scan_dir!` 在发布 manifest 前注册。plugin 现在只声明 board 工具
  # (`kanban-manager`),不再声明脑。
  describe "kanban-team 提纯:plugin roles/0 只留 board 工具" do
    test "roles/0 只声明 kanban-manager(两个脑已搬进 sw seed recipes.yaml)" do
      names = Enum.map(KanbanApp.roles(), & &1.name)
      assert names == ["kanban-manager"]
      refute "kanban-assistant" in names
      refute "dev-together" in names
    end
  end
end
