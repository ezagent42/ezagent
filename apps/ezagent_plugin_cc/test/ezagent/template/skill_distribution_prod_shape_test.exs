defmodule Ezagent.PluginCc.Template.SkillDistributionProdShapeTest do
  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.OrchestratorBootstrap, as: Bootstrap

  @skill_ref "ezagent-session-orchestrator"

  setup do
    old_orchestrator = Application.get_env(:ezagent_plugin_cc, :orchestrator_skill_source)
    old_role_sources = Application.get_env(:ezagent_plugin_cc, :role_skill_sources)
    old_registry_sources = Application.get_env(:ezagent_core, :skill_registry_source_dirs)

    Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
    Application.delete_env(:ezagent_plugin_cc, :role_skill_sources)

    on_exit(fn ->
      restore_env(:ezagent_plugin_cc, :orchestrator_skill_source, old_orchestrator)
      restore_env(:ezagent_plugin_cc, :role_skill_sources, old_role_sources)
      restore_env(:ezagent_core, :skill_registry_source_dirs, old_registry_sources)
    end)

    :ok
  end

  test "every derived recipe skill resolves from the bundled SkillRegistry origin" do
    assert {:module, Ezagent.SkillRegistry} = Code.ensure_loaded(Ezagent.SkillRegistry)

    refs = Ezagent.SkillRegistry.derived_recipe_skill_refs()
    assert refs == [@skill_ref]
    assert Ezagent.SkillRegistry.seed_bundle_refs() == refs

    for ref <- refs do
      assert {:ok, source_dir} = Bootstrap.resolve_skill_source(ref)
      assert File.regular?(Path.join(source_dir, "SKILL.md"))
      assert String.contains?(source_dir, Path.join(["priv", "skills_seed", ref]))
    end
  end

  test "non-dev resolution fails when the registry is empty instead of walking the repo tree" do
    assert {:module, Ezagent.SkillRegistry} = Code.ensure_loaded(Ezagent.SkillRegistry)
    Application.put_env(:ezagent_core, :skill_registry_source_dirs, [])

    assert {:error, {:skill_source_not_found, @skill_ref}} =
             Bootstrap.resolve_skill_source(@skill_ref)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
