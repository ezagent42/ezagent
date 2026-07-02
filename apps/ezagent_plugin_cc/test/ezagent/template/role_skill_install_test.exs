defmodule Ezagent.PluginCc.Template.RoleSkillInstallTest do
  @moduledoc """
  Phase 3 ③ T7d — pins gap#1's skill-install half end-to-end for a NON-orchestrator
  role (`pm-coordinator`): `OrchestratorBootstrap.bootstrap/2`, keyed off the
  template's `"role"` field, looks the recipe up BY NAME in `RecipeRegistry`,
  composes its `skills`, and copies each into `config_dir/skills/<ref>`.

  Before T2/T4 a non-orchestrator role never reached this path; this asserts the
  generalized loader genuinely installs the pm-coordinator skill (the T7b surface
  flagged "pm config_dir has no kanban tool path" — the skill teaches the CLI).
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

    # Stage a fixture skill source so the install does not depend on the repo's
    # `.claude/skills/pm-coordinator` shipping in this build. The generic
    # `:role_skill_sources` map points the ref at the fixture.
    fixture_root =
      Path.join(System.tmp_dir!(), "role-skill-#{System.unique_integer([:positive])}")

    skill_src = Path.join(fixture_root, @skill_ref)
    File.mkdir_p!(skill_src)
    File.write!(Path.join(skill_src, "SKILL.md"), "fixture pm-coordinator skill\n")
    Application.put_env(:ezagent_plugin_cc, :role_skill_sources, %{@skill_ref => skill_src})

    config_dir =
      Path.join(System.tmp_dir!(), "role-skill-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_cc, :role_skill_sources)
      _ = File.rm_rf(fixture_root)
      _ = File.rm_rf(config_dir)
    end)

    {:ok, config_dir: config_dir}
  end

  test "bootstrap installs the pm-coordinator skill into config_dir/skills/<ref>", %{
    config_dir: config_dir
  } do
    assert :ok = Bootstrap.bootstrap(%{"role" => @role}, config_dir)

    assert File.regular?(Path.join([config_dir, "skills", @skill_ref, "SKILL.md"]))
  end

  test "resolve_role composes the seeded recipe's skills for the role name" do
    assert {:ok, %{skills: skills}} = Bootstrap.resolve_role(@role)
    assert @skill_ref in skills
  end

  test "a nil config_dir is a no-op (no crash)" do
    assert :ok = Bootstrap.bootstrap(%{"role" => @role}, nil)
  end
end
