defmodule Ezagent.Agent.DefaultRecipesTest do
  @moduledoc """
  `Ezagent.Agent.DefaultRecipes` — the single role-as-data source for the
  cc-headless default agents `pm-coordinator` + `dev-together` (Phase 3 ③
  refactor 2026-06-30). Absorbs the old `EzagentPluginKanban.PmCoordinatorRoleTest`
  and `EzagentPluginDevTogether.DevTogetherRoleTest` (both plugin tests deleted
  with the move out of `roles/0`).

  Pins the discriminating recipe fields (passive / skills / behaviors /
  requested_caps shape), the STRING behavior names (the agent domain has ZERO
  compile dep on the kanban / github plugins), the seed → flush → lookup
  read-through round-trip, and the `config[:project_cwd]` opt-in / byte-identical
  unset regression.
  """

  # DataCase (not bare ExUnit.Case): seed → lookup is a DB write/read (ConfigStore
  # persists in the Repo); the Ecto SQL Sandbox owns the connection.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.{DefaultRecipes, Recipe, RecipeRegistry}

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  describe "all/0 — the generic seeder's input" do
    test "lists both default cc-headless recipes" do
      names = Enum.map(DefaultRecipes.all(), & &1.name)
      assert "pm-coordinator" in names
      assert "dev-together" in names
      assert length(DefaultRecipes.all()) == 2
    end
  end

  describe "pm-coordinator recipe" do
    test "Recipe.new/1 accepts it with the discriminating fields" do
      assert {:ok, %Recipe{} = role} = Recipe.new(DefaultRecipes.pm_coordinator_recipe())

      assert role.name == "pm-coordinator"
      # pm is the cc-headless 大脑 that RECEIVES chat (a chat principal).
      assert role.passive == false
      # pm acts via the CLI/dispatch surface, not mounted per-instance behaviors.
      assert role.behaviors == []
      assert role.skills == ["pm-coordinator"]

      # 7 kanban + 3 github = 10 cap templates, each %{behavior:, action:} with
      # NO `kind` materialization axis.
      assert length(role.requested_caps) == 10

      assert Enum.all?(role.requested_caps, fn cap ->
               is_map(cap) and Map.has_key?(cap, :behavior) and Map.has_key?(cap, :action) and
                 not Map.has_key?(cap, :kind)
             end)
    end

    test "kanban caps name the behavior by STRING (zero compile dep on the kanban plugin)" do
      {:ok, role} = Recipe.new(DefaultRecipes.pm_coordinator_recipe())

      kanban_actions =
        role.requested_caps
        |> Enum.filter(&(&1.behavior == "Ezagent.Behavior.Kanban"))
        |> Enum.map(& &1.action)
        |> MapSet.new()

      assert kanban_actions ==
               MapSet.new([
                 :get_tree,
                 :add_node,
                 :set_stage,
                 :claim_node,
                 :set_status,
                 :attach_artifact,
                 :register_pr
               ])
    end

    test "github caps name the behavior by STRING" do
      {:ok, role} = Recipe.new(DefaultRecipes.pm_coordinator_recipe())

      github_actions =
        role.requested_caps
        |> Enum.filter(&(&1.behavior == "Ezagent.Behavior.Github"))
        |> Enum.map(& &1.action)
        |> MapSet.new()

      assert github_actions == MapSet.new([:create_issue, :post_comment, :get_pull])
    end

    test "role-as-data — seed_role_if_absent → flush → read-through lookup round-trip" do
      seed_all_recipes()
      :ok = RecipeRegistry.flush_cache()

      assert {:ok,
              %Recipe{
                name: "pm-coordinator",
                passive: false,
                behaviors: [],
                skills: ["pm-coordinator"]
              }} =
               RecipeRegistry.lookup("pm-coordinator")
    end
  end

  describe "dev-together recipe" do
    test "Recipe.new/1 accepts it with the discriminating fields" do
      assert {:ok, %Recipe{} = role} = Recipe.new(DefaultRecipes.dev_together_recipe())

      assert role.name == "dev-together"
      assert role.passive == false
      assert role.behaviors == []
      assert role.skills == ["dev-together"]

      # 5 kanban + 4 github = 9 cap templates.
      assert length(role.requested_caps) == 9

      assert Enum.all?(role.requested_caps, fn cap ->
               is_map(cap) and Map.has_key?(cap, :behavior) and Map.has_key?(cap, :action) and
                 not Map.has_key?(cap, :kind)
             end)
    end

    test "both kanban + github caps named by STRING" do
      {:ok, role} = Recipe.new(DefaultRecipes.dev_together_recipe())

      kanban_actions =
        role.requested_caps
        |> Enum.filter(&(&1.behavior == "Ezagent.Behavior.Kanban"))
        |> Enum.map(& &1.action)
        |> MapSet.new()

      assert kanban_actions ==
               MapSet.new([:get_tree, :claim_node, :set_status, :attach_artifact, :register_pr])

      github_actions =
        role.requested_caps
        |> Enum.filter(&(&1.behavior == "Ezagent.Behavior.Github"))
        |> Enum.map(& &1.action)
        |> MapSet.new()

      assert github_actions ==
               MapSet.new([:create_issue, :post_comment, :get_pull, :create_commit_status])
    end

    test "role-as-data — seed_role_if_absent → flush → read-through lookup round-trip" do
      seed_all_recipes()
      :ok = RecipeRegistry.flush_cache()

      assert {:ok,
              %Recipe{
                name: "dev-together",
                passive: false,
                behaviors: [],
                skills: ["dev-together"]
              }} =
               RecipeRegistry.lookup("dev-together")
    end
  end

  describe "config[:project_cwd] CLI-reachability seam — CONDITIONAL (byte-identical unset)" do
    # The pre-seam seeded body shape: NO `:config` key. The unset recipe body MUST
    # be byte-identical so `seed_role_if_absent/1` does not reject it as a divergent
    # body (`{:role_seed_collision, "dev-together"}`) on a DB seeded before the seam.
    @pre_seam_keys MapSet.new([:name, :passive, :behaviors, :skills, :requested_caps])

    setup do
      prior = Application.get_env(:ezagent_domain_agent, :dev_together_cwd)
      on_exit(fn -> restore_cwd(prior) end)
      :ok
    end

    defp restore_cwd(nil), do: Application.delete_env(:ezagent_domain_agent, :dev_together_cwd)
    defp restore_cwd(v), do: Application.put_env(:ezagent_domain_agent, :dev_together_cwd, v)

    test "operator opt-in: :dev_together_cwd set → recipe carries config[:project_cwd]" do
      cwd = "/srv/ezagent-umbrella-#{System.unique_integer([:positive])}"
      Application.put_env(:ezagent_domain_agent, :dev_together_cwd, cwd)

      assert DefaultRecipes.dev_together_recipe().config[:project_cwd] == cwd

      assert {:ok, %Recipe{config: %{project_cwd: ^cwd}}} =
               Recipe.new(DefaultRecipes.dev_together_recipe())

      # the template-seed cwd reflects the opt-in too.
      assert DefaultRecipes.dev_project_cwd() == cwd
    end

    test "regression: absent :dev_together_cwd → NO :config key (byte-identical to pre-seam body)" do
      Application.delete_env(:ezagent_domain_agent, :dev_together_cwd)

      recipe = DefaultRecipes.dev_together_recipe()

      refute Map.has_key?(recipe, :config),
             "unset :dev_together_cwd must OMIT the :config key so a re-seed does not collide"

      assert MapSet.new(Map.keys(recipe)) == @pre_seam_keys
      assert (Map.get(recipe, :config) || %{})[:project_cwd] == nil
      assert {:ok, %Recipe{}} = Recipe.new(recipe)

      # the template-seed cwd falls back to the UNCHANGED sandbox default.
      assert DefaultRecipes.dev_project_cwd() ==
               Path.join([System.user_home() || System.tmp_dir!(), ".ezagent", "dev-together"])
    end

    test "empty-string :dev_together_cwd is treated as unset (no :config key)" do
      Application.put_env(:ezagent_domain_agent, :dev_together_cwd, "")

      refute Map.has_key?(DefaultRecipes.dev_together_recipe(), :config)
    end

    test "pm recipe carries NO :config key (pm goes through explicit materialize, not by-role lookup)" do
      refute Map.has_key?(DefaultRecipes.pm_coordinator_recipe(), :config)
    end
  end

  defp seed_all_recipes do
    Enum.each(DefaultRecipes.all(), fn recipe ->
      case RecipeRegistry.seed_role_if_absent(recipe) do
        {:ok, _} -> :ok
        {:error, {:role_seed_collision, _}} -> :ok
      end
    end)
  end
end
