defmodule Ezagent.Orchestrator.OrchestratorRecipeTest do
  @moduledoc """
  Task #54 PR-2 — the orchestrator is the first **Role** (design §3).

  The orchestrator role recipe is a code-seeded built-in (Option B, Allen
  2026-06-15): a flavor-agnostic recipe fed through the REAL `Ezagent.Agent.Recipe`
  core primitive (NOT a registry), so the cc seam consults `role × flavor`
  rather than a hardcoded cc skill/prompt. These tests pin that the recipe is a
  well-formed Role and that it carries the orchestrator skill + persona.
  """
  # role-as-data: the read-through lookup test seeds into ConfigStore (DB), so the
  # suite needs the DataCase sandbox. The pure recipe/persona tests ignore it.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Orchestrator.CcOrchestratorSeed
  alias Ezagent.Orchestrator.McpServer
  alias Ezagent.Orchestrator.OrchestratorRecipe
  alias Ezagent.Orchestrator.Tools
  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeRegistry

  describe "recipe/0 — a well-formed flavor-agnostic Role" do
    test "Recipe.new/1 accepts the recipe (no flavor field, valid shape)" do
      assert {:ok, %Recipe{}} = Recipe.new(OrchestratorRecipe.recipe())
    end

    test "carries the registry name (\"orchestrator\") so roles/0 can key it" do
      assert OrchestratorRecipe.name() == "orchestrator"
      {:ok, role} = Recipe.new(OrchestratorRecipe.recipe())
      assert role.name == "orchestrator"
    end

    test "carries the ezagent-session-orchestrator skill" do
      {:ok, role} = Recipe.new(OrchestratorRecipe.recipe())
      assert "ezagent-session-orchestrator" in role.skills
    end

    test "carries the orchestrator persona as its prompt" do
      {:ok, role} = Recipe.new(OrchestratorRecipe.recipe())
      assert role.prompt == OrchestratorRecipe.persona()
      assert is_binary(role.prompt) and role.prompt != ""
    end

    test "declares the orchestrator tool contribution as the single catalog source" do
      {:ok, role} = Recipe.new(OrchestratorRecipe.recipe())

      contribution_names = OrchestratorRecipe.tool_names()

      assert contribution_names == [
               "add_managed_member",
               "add_participant",
               "update_member_template",
               "remove_member",
               "define_rule_set_rule",
               "define_prompt_template",
               "define_legend",
               "update_template",
               "save_template_as",
               "migrate_session",
               "list_templates"
             ]

      assert get_in(role.contributions, [:tools]) == OrchestratorRecipe.tool_contributions()
      assert Enum.map(Tools.tool_names(), &Atom.to_string/1) == contribution_names
      assert McpServer.tool_names() == contribution_names ++ ["kb_ingest", "kb_query"]
    end

    test "names no flavor (would re-entangle role with flavor)" do
      recipe = OrchestratorRecipe.recipe()

      for flavor_field <- ~w(flavor kind bridge_adapter template_class)a do
        refute Map.has_key?(recipe, flavor_field)
        refute Map.has_key?(recipe, Atom.to_string(flavor_field))
      end
    end
  end

  describe "roles/0 + RecipeRegistry — seeded as a first-class named role (RF-9 / role-as-data §4)" do
    test "the cc plugin's roles/0 declares the orchestrator recipe" do
      assert OrchestratorRecipe.recipe() in EzagentPluginCc.Application.roles()
    end

    test "RecipeRegistry.lookup(\"orchestrator\") returns the recipe end-to-end (read-through)" do
      # role-as-data: boot SEEDS each roles/0 recipe into ConfigStore; lookup
      # resolves read-through. Boot's DB seed is :test-skipped, so seed the recipe
      # explicitly here in the DataCase sandbox, then flush the cache to prove the
      # lookup resolves from ConfigStore (not a surviving ETS write).
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(OrchestratorRecipe.recipe())
      :ok = RecipeRegistry.flush_cache()

      assert {:ok, %Recipe{name: "orchestrator"} = role} =
               RecipeRegistry.lookup(OrchestratorRecipe.name())

      # The looked-up recipe IS the orchestrator role (skill + persona).
      assert "ezagent-session-orchestrator" in role.skills
      assert role.prompt == OrchestratorRecipe.persona()

      # And it equals what `Recipe.new/1` would build from `recipe/0` — proving the
      # registry stores the validated recipe, not a re-derived variant.
      {:ok, expected} = Recipe.new(OrchestratorRecipe.recipe())
      assert role == expected
    end
  end

  describe "persona/0 — the orchestrator system prompt (single source)" do
    test "is a non-empty string teaching the orchestrator role" do
      persona = OrchestratorRecipe.persona()
      assert is_binary(persona)
      assert persona =~ "orchestrator"
    end
  end

  describe "CcOrchestratorSeed.refresh_managed_persona!/2 — no stale persona on upgrade" do
    setup do
      path = Path.join(System.tmp_dir!(), "orch-persona-#{System.unique_integer([:positive])}.md")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "writes the persona when CLAUDE.md is absent", %{path: path} do
      refute File.exists?(path)
      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, OrchestratorRecipe.persona())
      assert File.read!(path) == OrchestratorRecipe.persona()
    end

    test "REWRITES a stale CLAUDE.md whose content differs from the persona", %{path: path} do
      # An upgraded install: the sandbox already has an OLD persona on disk.
      File.write!(path, "# stale orchestrator persona from a previous version\n")

      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, OrchestratorRecipe.persona())
      assert File.read!(path) == OrchestratorRecipe.persona()
    end

    test "leaves an up-to-date CLAUDE.md untouched (idempotent, no needless write)", %{path: path} do
      persona = OrchestratorRecipe.persona()
      File.write!(path, persona)
      mtime = File.stat!(path).mtime

      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, persona)
      assert File.stat!(path).mtime == mtime
      assert File.read!(path) == persona
    end
  end
end
