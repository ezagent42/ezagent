defmodule Ezagent.Orchestrator.OrchestratorRoleTest do
  @moduledoc """
  Task #54 PR-2 — the orchestrator is the first **Role** (design §3).

  The orchestrator role recipe is a code-seeded built-in (Option B, Allen
  2026-06-15): a flavor-agnostic recipe fed through the REAL `Ezagent.Role`
  core primitive (NOT a registry), so the cc seam consults `role × flavor`
  rather than a hardcoded cc skill/prompt. These tests pin that the recipe is a
  well-formed Role and that it carries the orchestrator skill + persona.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Orchestrator.CcOrchestratorSeed
  alias Ezagent.Orchestrator.OrchestratorRole
  alias Ezagent.Role

  describe "recipe/0 — a well-formed flavor-agnostic Role" do
    test "Role.new/1 accepts the recipe (no flavor field, valid shape)" do
      assert {:ok, %Role{}} = Role.new(OrchestratorRole.recipe())
    end

    test "carries the ezagent-session-orchestrator skill" do
      {:ok, role} = Role.new(OrchestratorRole.recipe())
      assert "ezagent-session-orchestrator" in role.skills
    end

    test "carries the orchestrator persona as its prompt" do
      {:ok, role} = Role.new(OrchestratorRole.recipe())
      assert role.prompt == OrchestratorRole.persona()
      assert is_binary(role.prompt) and role.prompt != ""
    end

    test "names no flavor (would re-entangle role with flavor)" do
      recipe = OrchestratorRole.recipe()

      for flavor_field <- ~w(flavor kind bridge_adapter template_class)a do
        refute Map.has_key?(recipe, flavor_field)
        refute Map.has_key?(recipe, Atom.to_string(flavor_field))
      end
    end
  end

  describe "persona/0 — the orchestrator system prompt (single source)" do
    test "is a non-empty string teaching the orchestrator role" do
      persona = OrchestratorRole.persona()
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
      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, OrchestratorRole.persona())
      assert File.read!(path) == OrchestratorRole.persona()
    end

    test "REWRITES a stale CLAUDE.md whose content differs from the persona", %{path: path} do
      # An upgraded install: the sandbox already has an OLD persona on disk.
      File.write!(path, "# stale orchestrator persona from a previous version\n")

      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, OrchestratorRole.persona())
      assert File.read!(path) == OrchestratorRole.persona()
    end

    test "leaves an up-to-date CLAUDE.md untouched (idempotent, no needless write)", %{path: path} do
      persona = OrchestratorRole.persona()
      File.write!(path, persona)
      mtime = File.stat!(path).mtime

      assert :ok = CcOrchestratorSeed.refresh_managed_persona!(path, persona)
      assert File.stat!(path).mtime == mtime
      assert File.read!(path) == persona
    end
  end
end
