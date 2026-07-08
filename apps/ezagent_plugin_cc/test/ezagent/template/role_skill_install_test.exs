defmodule Ezagent.PluginCc.Template.RoleSkillInstallTest do
  @moduledoc """
  Phase 3 ③ T7d / skill-distribution P3 — pins the NON-orchestrator role
  bootstrap boundary (`pm-coordinator`): `OrchestratorBootstrap.bootstrap/2`, keyed off the
  template's `"role"` field, looks the recipe up BY NAME in `RecipeRegistry`,
  composes its `skills`, and leaves skill bytes for HomeRuntime materialization.

  Before T2/T4 a non-orchestrator role never reached this path; P3 keeps the
  generalized role lookup but removes the separate post-spawn copy.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.PluginCc.Template.OrchestratorBootstrap, as: Bootstrap

  @role "pm-coordinator"
  @skill_ref "pm-coordinator"

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok = RecipeRegistry.flush_cache()

    # Seed the role recipe (skills: [pm-coordinator]) so bootstrap resolves it.
    case RecipeRegistry.seed_role_if_absent(%{
           name: @role,
           behaviors: [],
           requested_caps: [],
           skills: [@skill_ref]
         }) do
      {:ok, _} -> :ok
      {:error, {:role_seed_collision, _}} -> :ok
    end

    config_dir =
      Path.join(System.tmp_dir!(), "role-skill-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    on_exit(fn ->
      _ = File.rm_rf(config_dir)
    end)

    {:ok, config_dir: config_dir}
  end

  test "bootstrap does not post-copy the pm-coordinator skill into config_dir/skills/<ref>", %{
    config_dir: config_dir
  } do
    assert :ok = Bootstrap.bootstrap(%{"role" => @role}, config_dir)

    refute File.exists?(Path.join([config_dir, "skills", @skill_ref, "SKILL.md"]))
  end

  test "resolve_role composes the seeded recipe's skills for the role name" do
    assert {:ok, %{skills: skills}} = Bootstrap.resolve_role(@role)
    assert @skill_ref in skills
  end

  test "a nil config_dir is a no-op (no crash)" do
    assert :ok = Bootstrap.bootstrap(%{"role" => @role}, nil)
  end
end
